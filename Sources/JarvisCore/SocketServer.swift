import Foundation

/// Shared POSIX helpers for AF_UNIX stream sockets.
enum UnixSocket {
    /// sockaddr_un.sun_path is 104 bytes on macOS, including the NUL terminator.
    static let maxPathBytes = 103

    static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func setTimeout(_ fd: Int32, seconds: TimeInterval) {
        let whole = floor(seconds)
        var tv = timeval(tv_sec: Int(whole), tv_usec: Int32((seconds - whole) * 1_000_000))
        if tv.tv_sec == 0 && tv.tv_usec == 0 { tv.tv_usec = 1000 }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func withAddress<R>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R? {
        guard path.utf8.count <= maxPathBytes else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in path.utf8.enumerated() { raw[i] = b }
            raw[path.utf8.count] = 0
        }
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func connect(_ fd: Int32, path: String) -> Bool {
        withAddress(path) { addr, len in
            while true {
                if Darwin.connect(fd, addr, len) == 0 { return true }
                if errno != EINTR { return false }
            }
        } ?? false
    }
}

public struct SocketServerError: Error, Equatable {
    public let message: String
}

public final class SocketServer: @unchecked Sendable {
    private static let maxRequestBytes = 64 * 1024

    private let path: String
    private let handler: @Sendable (JarvisRequest) async -> JarvisResponse
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var acceptDone: DispatchSemaphore?

    public init(path: String, handler: @escaping @Sendable (JarvisRequest) async -> JarvisResponse) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }
        guard path.utf8.count <= UnixSocket.maxPathBytes else {
            throw SocketServerError(message: "socket path too long")
        }
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // createDirectory applies the mode only to directories it creates; enforce it on existing ones.
        var dst = stat()
        guard lstat(dir, &dst) == 0, dst.st_mode & S_IFMT == S_IFDIR, dst.st_uid == getuid() else {
            throw SocketServerError(message: "socket directory is not an owned directory")
        }
        guard chmod(dir, 0o700) == 0 else {
            throw SocketServerError(message: "chmod of socket directory failed: \(errno)")
        }

        // Remove a stale socket or regular file; never a directory.
        var st = stat()
        if lstat(path, &st) == 0 {
            let type = st.st_mode & S_IFMT
            if type == S_IFSOCK || type == S_IFREG {
                unlink(path)
            } else {
                throw SocketServerError(message: "path exists and is not a socket")
            }
        }

        guard let fd = UnixSocket.makeSocket() else {
            throw SocketServerError(message: "socket() failed: \(errno)")
        }
        let bound = UnixSocket.withAddress(path) { addr, len in Darwin.bind(fd, addr, len) }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw SocketServerError(message: "bind() failed: \(e)")
        }
        guard chmod(path, 0o600) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketServerError(message: "chmod() failed: \(e)")
        }
        // Non-blocking: a connection that vanishes between poll and accept cannot block the loop.
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketServerError(message: "fcntl() failed: \(e)")
        }
        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SocketServerError(message: "listen() failed: \(e)")
        }

        listenFD = fd
        running = true
        let done = DispatchSemaphore(value: 0)
        acceptDone = done
        let thread = Thread { [self] in
            acceptLoop(fd: fd)
            done.signal()
        }
        thread.name = "jarvis.socket.accept"
        thread.start()
    }

    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let fd = listenFD
        let done = acceptDone
        listenFD = -1
        acceptDone = nil
        lock.unlock()

        // The accept loop polls with a short timeout and exits once `running` is false.
        done?.wait()
        close(fd)
        unlink(path)
    }

    /// Test support: the listening socket, -1 when stopped.
    var listeningDescriptor: Int32 { lock.lock(); defer { lock.unlock() }; return listenFD }

    /// Seconds to wait before polling again after `accept` or `poll` failed with `e`. Nothing pending or
    /// an interrupted call retries at once; running out of descriptors (`EMFILE`, `ENFILE`) or anything
    /// unexpected waits, so the loop cannot spin on an error that persists.
    static func retryDelay(afterError e: Int32) -> Double {
        switch e {
        case EAGAIN, EWOULDBLOCK, EINTR, ECONNABORTED: return 0
        default: return 0.05
        }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func acceptLoop(fd: Int32) {
        while isRunning {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 100)
            if r == 0 { continue }
            if r < 0 {
                Self.backOff(errno)
                continue
            }
            let client = accept(fd, nil, nil)
            if client < 0 {
                Self.backOff(errno)
                continue
            }
            // An accepted socket inherits O_NONBLOCK on macOS; requests are read with blocking timeouts.
            let clientFlags = fcntl(client, F_GETFL)
            if clientFlags < 0 || fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) != 0 {
                close(client)
                continue
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            UnixSocket.setTimeout(client, seconds: 5)
            DispatchQueue.global().async { [self] in
                guard let request = readRequest(client) else { close(client); return }
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    if let data = try? WireCodec.encodeLine(response) {
                        Self.writeAll(client, data)
                    }
                    close(client)
                }
            }
        }
    }

    private static func backOff(_ e: Int32) {
        let delay = retryDelay(afterError: e)
        if delay > 0 { usleep(useconds_t(delay * 1_000_000)) }
    }

    /// Reads one line (max 64 KB). Returns nil on oversize, EOF-before-data, timeout or bad JSON.
    private func readRequest(_ fd: Int32) -> JarvisRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                return try? WireCodec.decodeLine(Data(buffer[buffer.startIndex..<idx]), as: JarvisRequest.self)
            }
            if buffer.count > Self.maxRequestBytes { return nil }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return }
        }
    }
}

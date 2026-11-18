import Foundation
import Testing
@testable import JarvisCore

@Suite(.serialized) struct SocketTests {
    private func tempDir() -> String {
        "/tmp/jv-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

    private func req(_ id: String = "r1") -> JarvisRequest {
        JarvisRequest(id: id, sessionId: "s", project: "p", kind: .permission,
                      speech: "x", detail: "d", risky: false, deadlineS: 5)
    }

    @Test func roundTripThroughServer() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/jarvis.sock"
        let server = SocketServer(path: path) { r in
            JarvisResponse(id: r.id, status: .answered, transcript: nil, intent: .allow)
        }
        try server.start(); defer { server.stop() }
        let resp = SocketClient.send(req("abc"), path: path, timeout: 2)
        #expect(resp == JarvisResponse(id: "abc", status: .answered, transcript: nil, intent: .allow))
    }

    @Test func socketFileIsOwnerOnly() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/jarvis.sock"
        let server = SocketServer(path: path) { JarvisResponse(id: $0.id, status: .timeout, transcript: nil, intent: .none) }
        try server.start(); defer { server.stop() }
        var st = stat()
        #expect(stat(path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(stat(dir, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    @Test func existingDirectoryIsTightenedTo0700() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        chmod(dir, 0o755)
        let path = dir + "/jarvis.sock"
        let server = SocketServer(path: path) { JarvisResponse(id: $0.id, status: .timeout, transcript: nil, intent: .none) }
        try server.start(); defer { server.stop() }
        var st = stat()
        #expect(stat(dir, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    @Test func clientReturnsNilWhenNoServer() {
        let start = Date()
        #expect(SocketClient.send(req(), path: tempDir() + "/jarvis.sock", timeout: 2) == nil)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func clientReturnsNilOnStaleSocketFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/jarvis.sock"
        FileManager.default.createFile(atPath: path, contents: Data())
        let start = Date()
        #expect(SocketClient.send(req(), path: path, timeout: 2) == nil)
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func clientTimesOut() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/jarvis.sock"
        let server = SocketServer(path: path) { r in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return JarvisResponse(id: r.id, status: .answered, transcript: nil, intent: .allow)
        }
        try server.start(); defer { server.stop() }
        let start = Date()
        #expect(SocketClient.send(req(), path: path, timeout: 0.5) == nil)
        #expect(Date().timeIntervalSince(start) < 1.5)
    }

    @Test func serverRestartsOverStaleSocket() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/jarvis.sock"
        let handler: @Sendable (JarvisRequest) async -> JarvisResponse = {
            JarvisResponse(id: $0.id, status: .answered, transcript: nil, intent: .allow)
        }
        let first = SocketServer(path: path, handler: handler)
        try first.start(); first.stop()
        // Leave a stale socket file behind, as after a crash.
        let fd = UnixSocket.makeSocket()!
        _ = UnixSocket.withAddress(path) { a, l in Darwin.bind(fd, a, l) }
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        let second = SocketServer(path: path, handler: handler)
        try second.start(); defer { second.stop() }
        #expect(SocketClient.send(req("z"), path: path, timeout: 2)?.id == "z")
        second.stop()
        try second.start()
        #expect(SocketClient.send(req("y"), path: path, timeout: 2)?.id == "y")
    }

    @Test func tooLongPathFails() {
        let long = "/tmp/" + String(repeating: "a", count: 120) + "/jarvis.sock"
        let server = SocketServer(path: long) { JarvisResponse(id: $0.id, status: .timeout, transcript: nil, intent: .none) }
        #expect(throws: SocketServerError.self) { try server.start() }
        #expect(SocketClient.send(req(), path: long, timeout: 1) == nil)
    }
    // MARK: - v1.4: no accept spin

    @Test func listeningSocketIsNonBlocking() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = SocketServer(path: dir + "/jarvis.sock") { JarvisResponse(id: $0.id, status: .timeout, transcript: nil, intent: .none) }
        try server.start(); defer { server.stop() }
        let fd = server.listeningDescriptor
        #expect(fd >= 0)
        #expect(fcntl(fd, F_GETFL) & O_NONBLOCK != 0)
    }

    @Test func acceptErrorsBackOff() {
        // Nothing to accept right now, or an interrupted call: retry at once.
        for e in [EAGAIN, EWOULDBLOCK, EINTR, ECONNABORTED] {
            #expect(SocketServer.retryDelay(afterError: e) == 0, "\(e)")
        }
        // Out of descriptors or anything unexpected: wait 50 ms, so the loop does not spin.
        for e in [EMFILE, ENFILE, EBADF, ENOMEM, EINVAL] {
            #expect(SocketServer.retryDelay(afterError: e) == 0.05, "\(e)")
        }
    }

    @Test func acceptedClientIsBlockingAndSlowWritersAreServed() throws {
        // macOS accept() inherits O_NONBLOCK from the listening socket; the server must clear it.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/jarvis.sock"
        let server = SocketServer(path: path) { JarvisResponse(id: $0.id, status: .answered, transcript: nil, intent: .allow) }
        try server.start(); defer { server.stop() }
        let fd = try #require(UnixSocket.makeSocket())
        defer { close(fd) }
        UnixSocket.setTimeout(fd, seconds: 2)
        #expect(UnixSocket.connect(fd, path: path))
        let line = try WireCodec.encodeLine(req("slow"))
        let half = line.count / 2
        _ = line.prefix(half).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        usleep(150_000)
        _ = line.dropFirst(half).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        #expect(n > 0)
        let reply = Data(buffer[0..<max(0, n)]).prefix { $0 != 0x0A }
        #expect(try WireCodec.decodeLine(Data(reply), as: JarvisResponse.self).id == "slow")
    }

    @Test func clientWriteIsBoundedByTheDeadline() throws {
        // A peer that never reads: the request blocks in the socket buffer. The send ends near its deadline.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/jarvis.sock"
        let listener = try #require(UnixSocket.makeSocket())
        defer { close(listener); unlink(path) }
        #expect(UnixSocket.withAddress(path) { bind(listener, $0, $1) } == 0)
        #expect(listen(listener, 4) == 0)
        var big = req("big")
        big.detail = String(repeating: "x", count: 2_000_000)
        let start = Date()
        #expect(SocketClient.send(big, path: path, timeout: 0.4) == nil)
        #expect(Date().timeIntervalSince(start) < 0.9)
    }
}

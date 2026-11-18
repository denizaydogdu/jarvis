import Foundation

public enum SocketClient {
    /// Sends one request and reads one response line. Returns nil on any failure (never throws).
    /// Total wall time is bounded by `timeout` plus a small margin.
    public static func send(_ r: JarvisRequest, path: String, timeout: TimeInterval) -> JarvisResponse? {
        guard let payload = try? WireCodec.encodeLine(r) else { return nil }
        guard let fd = UnixSocket.makeSocket() else { return nil }
        defer { close(fd) }

        let deadline = Date().addingTimeInterval(max(timeout, 0.01))
        UnixSocket.setTimeout(fd, seconds: max(timeout, 0.01))
        guard UnixSocket.connect(fd, path: path) else { return nil }

        // Write all bytes, bounded by the deadline: each write may block only for the time still left.
        var offset = 0
        while offset < payload.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            UnixSocket.setTimeout(fd, seconds: remaining)
            let n = payload.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            return nil
        }

        // Read until newline, EOF or deadline.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            UnixSocket.setTimeout(fd, seconds: remaining)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                if buffer.count > 1_048_576 { return nil }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil // timeout (EAGAIN) or error
            }
        }
        let line = buffer.prefix { $0 != 0x0A }
        guard !line.isEmpty else { return nil }
        return try? WireCodec.decodeLine(Data(line), as: JarvisResponse.self)
    }
}

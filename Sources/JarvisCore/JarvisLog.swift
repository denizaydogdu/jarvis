import Foundation

/// Append-only log. Each line is an ISO-8601 timestamp, a tab, then the text. Errors are ignored.
public struct JarvisLog: Sendable {
    public let path: String

    public init(path: String) { self.path = path }

    /// Line breaks and tabs that would split a log line or its tab-separated fields.
    private static let breaking: Set<Unicode.Scalar> = ["\n", "\r", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]

    /// Free text (a transcript, a label, a project name) made safe for one log field: `\n`, `\r`, `\t` and
    /// the other line separators each become a space.
    public static func field(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map { breaking.contains($0) ? " " : $0 }))
    }

    public func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data((stamp + "\t" + line + "\n").utf8)
        // The hook may run before the app ever created ~/.jarvis.
        mkdir((path as NSString).deletingLastPathComponent, 0o700)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, raw.count)
        }
    }
}

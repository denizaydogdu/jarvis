import Foundation

public struct ProcessInfoRow: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var tty: String
    public var command: String

    public init(pid: Int32, ppid: Int32, tty: String, command: String) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
        self.command = command
    }
}

public enum ProcessTree {
    /// Walks up from `startPid` to the first `claude` process; interactive means it has a tty.
    public static func isInteractive(startPid: Int32, rows: [ProcessInfoRow]) -> Bool {
        guard let row = claudeRow(startPid: startPid, rows: rows) else { return false }
        return row.tty != "??"
    }

    /// The device path of the `claude` ancestor's controlling terminal, e.g. "/dev/ttys003";
    /// "" when there is no such ancestor or it has no terminal.
    public static func sessionTty(startPid: Int32, rows: [ProcessInfoRow]) -> String {
        guard let tty = claudeRow(startPid: startPid, rows: rows)?.tty,
              !tty.isEmpty, tty != "??", !tty.contains("/") else { return "" }
        return "/dev/" + tty
    }

    /// The first ancestor (or `startPid` itself) whose command is `claude…`.
    private static func claudeRow(startPid: Int32, rows: [ProcessInfoRow]) -> ProcessInfoRow? {
        var byPid: [Int32: ProcessInfoRow] = [:]
        for r in rows { byPid[r.pid] = r }
        var current = startPid
        for _ in 0..<64 {
            guard let row = byPid[current] else { return nil }
            let last = (row.command as NSString).lastPathComponent
            if last.hasPrefix("claude") { return row }
            if row.ppid == current || row.ppid <= 0 { return nil }
            current = row.ppid
        }
        return nil
    }

    /// Parses `/bin/ps -axo pid=,ppid=,tty=,comm=`. Returns [] on any failure.
    public static func currentRows() -> [ProcessInfoRow] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-axo", "pid=,ppid=,tty=,comm="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<3 {
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            guard let pid = Int32(fields[0]), let ppid = Int32(fields[1]) else { return nil }
            let cmd = rest.trimmingCharacters(in: .whitespaces)
            return ProcessInfoRow(pid: pid, ppid: ppid, tty: String(fields[2]), command: cmd)
        }
    }
}

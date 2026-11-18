import Foundation

public enum SettingsMergerError: Error, CustomStringConvertible {
    case notAnObject
    case unexpectedShape(String)
    case unsupportedNumber
    case symlink
    case backupExists(String)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .notAnObject: return "settings file is not a JSON object"
        case .unexpectedShape(let key): return "unexpected shape for \(key) in settings file"
        case .unsupportedNumber: return "settings.json contains numbers that cannot be rewritten exactly (non-integer, over 18 digits or -0); edit it by hand"
        case .symlink: return "settings.json is a symlink; refusing to replace it"
        case .backupExists(let p): return "backup already exists, refusing to overwrite: \(p)"
        case .writeFailed(let p): return "cannot write \(p)"
        }
    }
}

public enum SettingsMerger {
    /// Adds the Jarvis PermissionRequest, Stop and PreToolUse (AskUserQuestion) hook groups; idempotent.
    /// Existing groups, the user's own included, are left untouched.
    public static func merge(_ settings: Data, hookBinary: String) throws -> Data {
        let parsed = try JSONSerialization.jsonObject(with: settings)
        guard var root = parsed as? [String: Any] else { throw SettingsMergerError.notAnObject }
        if containsNonIntegerNumber(settings) { throw SettingsMergerError.unsupportedNumber }

        var hooks: [String: Any]
        if let existing = root["hooks"] {
            guard let h = existing as? [String: Any] else { throw SettingsMergerError.unexpectedShape("hooks") }
            hooks = h
        } else {
            hooks = [:]
        }

        try add(&hooks, event: "PermissionRequest", hookBinary: hookBinary, subcommand: "permission", matcher: "*")
        try add(&hooks, event: "Stop", hookBinary: hookBinary, subcommand: "stop", matcher: nil)
        try add(&hooks, event: "PreToolUse", hookBinary: hookBinary, subcommand: "ask", matcher: "AskUserQuestion")
        root["hooks"] = hooks

        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func add(
        _ hooks: inout [String: Any], event: String, hookBinary: String, subcommand: String, matcher: String?
    ) throws {
        var groups: [Any]
        if let existing = hooks[event] {
            guard let g = existing as? [Any] else { throw SettingsMergerError.unexpectedShape("hooks.\(event)") }
            groups = g
        } else {
            groups = []
        }
        let prefix = hookBinary + " "
        let present = groups.contains { group in
            guard let g = group as? [String: Any], let hs = g["hooks"] as? [Any] else { return false }
            return hs.contains { h in
                guard let cmd = (h as? [String: Any])?["command"] as? String else { return false }
                return cmd.hasPrefix(prefix) || isJarvisHookCommand(cmd)
            }
        }
        if present { return }
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": "\(hookBinary) \(subcommand)", "timeout": 180]]
        ]
        if let matcher { group["matcher"] = matcher }
        groups.append(group)
        hooks[event] = groups
    }

    /// Any installed Jarvis hook, wherever its binary lives: re-running the installer from another path
    /// must not add a second entry.
    static func isJarvisHookCommand(_ cmd: String) -> Bool {
        cmd.range(of: #"/jarvis-hook (permission|stop|ask)$"#, options: .regularExpression) != nil
    }

    /// Integers up to this many digits always fit in Int64 and are written back unchanged.
    static let maxIntegerDigits = 18

    /// True when a number token outside strings would not survive a JSONSerialization round trip byte for
    /// byte: it contains '.', 'e' or 'E', has more than `maxIntegerDigits` digits, or is `-0`.
    static func containsNonIntegerNumber(_ data: Data) -> Bool {
        let b = [UInt8](data)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                while i < b.count, b[i] != UInt8(ascii: "\"") {
                    if b[i] == UInt8(ascii: "\\") { i += 1 }
                    i += 1
                }
            } else if c == UInt8(ascii: "-") || (c >= 0x30 && c <= 0x39) {
                let start = i
                var digits = 0
                while i < b.count, "0123456789+-.eE".utf8.contains(b[i]) {
                    if b[i] == UInt8(ascii: ".") || b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") { return true }
                    if b[i] >= 0x30 && b[i] <= 0x39 { digits += 1 }
                    i += 1
                }
                if digits > maxIntegerDigits { return true }
                if i - start == 2, b[start] == UInt8(ascii: "-"), b[start + 1] == UInt8(ascii: "0") { return true }
                continue
            }
            i += 1
        }
        return false
    }

    /// Creates a new file exclusively (fails if it exists) with exactly `mode` from the start.
    private static func createExclusive(_ path: String, _ data: Data, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else {
            if errno == EEXIST { throw SettingsMergerError.backupExists(path) }
            throw SettingsMergerError.writeFailed(path)
        }
        defer { close(fd) }
        _ = fchmod(fd, mode)  // exact mode regardless of umask
        let ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        if !ok { unlink(path); throw SettingsMergerError.writeFailed(path) }
    }

    /// Backs up, merges and atomically rewrites the file. Returns the backup path.
    public static func install(settingsPath: String, hookBinary: String, now: Date = Date()) throws -> String {
        var st = stat()
        guard lstat(settingsPath, &st) == 0 else { throw SettingsMergerError.writeFailed(settingsPath) }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw SettingsMergerError.symlink }
        let mode = st.st_mode & 0o7777

        let original = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let merged = try merge(original, hookBinary: hookBinary)  // validate before touching disk

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let backup = "\(settingsPath).bak-jarvis-\(fmt.string(from: now))"
        try createExclusive(backup, original, mode: mode)

        let dir = (settingsPath as NSString).deletingLastPathComponent
        let tmp = (dir.isEmpty ? "." : dir) + "/.settings-jarvis-\(UUID().uuidString).tmp"
        do {
            try createExclusive(tmp, merged, mode: mode)
            guard rename(tmp, settingsPath) == 0 else { throw SettingsMergerError.writeFailed(settingsPath) }
        } catch {
            unlink(tmp)
            throw error
        }
        return backup
    }
}

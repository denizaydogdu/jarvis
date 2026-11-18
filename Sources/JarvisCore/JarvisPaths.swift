import Foundation

public struct JarvisPaths: Sendable, Equatable {
    public let dir: String
    public var socket: String { dir + "/jarvis.sock" }
    public var log: String { dir + "/jarvis.log" }

    public init(dir: String) { self.dir = dir }

    public static func standard(home: String) -> JarvisPaths {
        let trimmed = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        return JarvisPaths(dir: trimmed + "/.jarvis")
    }

    /// The Ofis project folder: the first usable line of `~/.jarvis/ofis-dir` (an absolute path; a
    /// leading `~` is the home folder, empty and `#` lines are skipped, trailing slashes are trimmed),
    /// else `~/Dev/ajan-ofisi`. One setting for every place that reads Ofis files — the gate key
    /// (`OfisClient.standardKeyPath`) and the state files (`SessionFilter.loadOfisFileContents`).
    public static func ofisDir(home: String) -> String {
        let trimmed = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        if let text = try? String(contentsOfFile: trimmed + "/.jarvis/ofis-dir", encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                var line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line == "~" { return trimmed }
                if line.hasPrefix("~/") { line = trimmed + String(line.dropFirst()) }
                guard line.hasPrefix("/") else { continue }
                while line.count > 1 && line.hasSuffix("/") { line = String(line.dropLast()) }
                return line
            }
        }
        return trimmed + "/Dev/ajan-ofisi"
    }
}

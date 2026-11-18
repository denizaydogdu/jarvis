import Foundation

public enum SkipReason: String, Sendable {
    case excluded, ofis, nonInteractive, unsupportedTool
}

public struct SessionContext: Sendable {
    public var cwd: String
    public var sessionId: String
    public var env: [String: String]
    public var toolName: String?
    public var transcriptPath: String?

    public init(cwd: String, sessionId: String, env: [String: String], toolName: String?,
                transcriptPath: String? = nil) {
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.sessionId = sessionId
        self.env = env
        self.toolName = toolName
    }
}

/// Decides whether Jarvis must stay out of a session entirely.
public enum SessionFilter {
    public static func skipReason(
        _ ctx: SessionContext,
        excludedPrefixes: [String],
        ofisFileContents: [String],
        isInteractive: Bool,
        home: String
    ) -> SkipReason? {
        if excludedPrefixes.contains(where: { PathRules.isUnder(ctx.cwd, prefix: $0, home: home) }) {
            return .excluded
        }
        if let t = ctx.transcriptPath, !t.isEmpty,
           transcriptIsExcluded(t, excludedPrefixes: excludedPrefixes, home: home) {
            return .excluded
        }
        if ctx.env["OFIS_OTURUMU"] == "1" { return .ofis }
        let needle = "\"\(ctx.sessionId)\""
        if !ctx.sessionId.isEmpty, ofisFileContents.contains(where: { $0.contains(needle) }) {
            return .ofis
        }
        if ctx.toolName == "AskUserQuestion" { return .unsupportedTool }
        if !isInteractive { return .nonInteractive }
        return nil
    }

    /// The project folder name Claude Code uses under `~/.claude/projects/` for `path`, lowercased.
    /// Claude Code replaces every UTF-16 unit that is not an ASCII letter or digit with "-" ("ü" → "-");
    /// so does this, on both sides of a comparison, and only then lowercases (ASCII only). A prefix
    /// match on the result can only match more folders, never fewer.
    public static func encodedProjectName(_ path: String, home: String) -> String {
        encode(PathRules.standardized(path, home: home))
    }

    private static func encode(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for unit in s.utf16 {
            switch unit {
            case 0x30...0x39, 0x61...0x7A: out.append(Unicode.Scalar(UInt8(unit)))
            case 0x41...0x5A: out.append(Unicode.Scalar(UInt8(unit + 0x20)))
            default: out.append("-")
            }
        }
        return String(out)
    }

    /// True when a component of the transcript path is the encoded project folder of an excluded prefix
    /// (or of a folder below it). Over-excludes only.
    static func transcriptIsExcluded(_ transcriptPath: String, excludedPrefixes: [String], home: String) -> Bool {
        // Both Unicode forms of each prefix: Claude Code encodes the cwd as the file system gave it, and a
        // decomposed "ü" is two UTF-16 units ("u-") where the composed one is one ("-").
        let encoded = excludedPrefixes.flatMap { p in
            [p.precomposedStringWithCanonicalMapping, p.decomposedStringWithCanonicalMapping]
                .map { encodedProjectName($0, home: home) }
        }.filter { $0.count > 1 }
        let components = (transcriptPath as NSString).pathComponents.map(encode)
        return components.contains { c in encoded.contains { c.hasPrefix($0) } }
    }

    /// Always contains `~/Dev/bim`; adds non-empty, non-`#` lines of `~/.jarvis/excluded-paths`.
    public static func loadExcludedPrefixes(home: String) -> [String] {
        var result = ["~/Dev/bim"]
        if let text = try? String(contentsOfFile: home + "/.jarvis/excluded-paths", encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                result.append(line)
            }
        }
        return result
    }

    /// Contents of the OFIS state files under `<Ofis folder>/durum` (`JarvisPaths.ofisDir`);
    /// missing files are skipped.
    public static func loadOfisFileContents(home: String) -> [String] {
        ["sessions.json", "ceo.json"].compactMap {
            try? String(contentsOfFile: JarvisPaths.ofisDir(home: home) + "/durum/" + $0, encoding: .utf8)
        }
    }
}

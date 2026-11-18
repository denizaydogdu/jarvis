import Foundation

public enum RiskClassifier {
    static let bashPatterns: [String] = [
        #"\brm\b"#, #"git\s+push"#, #"--force\b"#, #"reset\s+--hard"#,
        #"\b(drop|delete|truncate)\b"#, #"\bkubectl\b"#, #"mvn\s+deploy"#,
        #"chmod\s+-R"#, #"\bsudo\b"#,
    ]
    /// Every pattern must compile (a test checks the count); a dropped one would fail open.
    static let bashRegexes: [NSRegularExpression] = bashPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }
    private static let fileTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    private static let mcpKeywords = [
        "write", "delete", "destructive", "execute", "query", "merge", "push", "create", "update", "move",
    ]

    public static func isRisky(_ call: ToolCall, cwd: String) -> Bool {
        if call.name == "ExitPlanMode" { return true }
        if call.name == "Bash" {
            guard let cmd = call.command else { return false }
            let range = NSRange(cmd.startIndex..., in: cmd)
            return bashRegexes.contains { $0.firstMatch(in: cmd, range: range) != nil }
        }
        if fileTools.contains(call.name) {
            guard let path = call.filePath else { return false }
            return !PathRules.isUnder(path, prefix: cwd, home: NSHomeDirectory())
        }
        if call.name.hasPrefix("mcp__") {
            let lower = call.name.lowercased()
            return mcpKeywords.contains { lower.contains($0) }
        }
        return false
    }
}

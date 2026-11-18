import Testing
@testable import JarvisCore

struct RiskClassifierTests {
    static let cwd = "/Users/u/Dev/p"

    static func bash(_ c: String) -> ToolCall {
        ToolCall(name: "Bash", command: c, filePath: nil, description: nil)
    }
    static func named(_ n: String) -> ToolCall {
        ToolCall(name: n, command: nil, filePath: nil, description: nil)
    }

    @Test(arguments: [
        "rm -rf build", "git push origin main", "git commit && git push",
        "psql -c \"DROP TABLE x\"", "sudo ls", "kubectl get pods", "mvn deploy",
        "chmod -R 777 .", "git reset --hard HEAD~1",
    ])
    func riskyBash(_ cmd: String) {
        #expect(RiskClassifier.isRisky(Self.bash(cmd), cwd: Self.cwd))
    }

    @Test(arguments: ["npm test", "ls -la", "git status", "swift build", "echo format"])
    func safeBash(_ cmd: String) {
        #expect(!RiskClassifier.isRisky(Self.bash(cmd), cwd: Self.cwd))
    }

    // M1: a pattern that failed to compile would silently drop a risk rule (fail-open).
    @Test func everyBashPatternCompiles() {
        #expect(RiskClassifier.bashRegexes.count == RiskClassifier.bashPatterns.count)
    }

    @Test func writeOutsideCwdIsRisky() {
        let c = ToolCall(name: "Write", command: nil, filePath: "/etc/hosts", description: nil)
        #expect(RiskClassifier.isRisky(c, cwd: Self.cwd))
    }

    @Test func editInsideCwdCaseInsensitiveIsSafe() {
        let c = ToolCall(name: "Edit", command: nil, filePath: "/Users/u/dev/p/a.swift", description: nil)
        #expect(!RiskClassifier.isRisky(c, cwd: Self.cwd))
    }

    @Test func fileToolWithoutPathIsSafe() {
        #expect(!RiskClassifier.isRisky(Self.named("Edit"), cwd: Self.cwd))
    }

    @Test(arguments: ["mcp__postgres__query", "mcp__github__merge_pull_request", "ExitPlanMode"])
    func riskyNames(_ n: String) {
        #expect(RiskClassifier.isRisky(Self.named(n), cwd: Self.cwd))
    }

    @Test(arguments: ["Read", "mcp__github__get_issue"])
    func safeNames(_ n: String) {
        #expect(!RiskClassifier.isRisky(Self.named(n), cwd: Self.cwd))
    }

    @Test func fromExtractsFields() {
        let c = ToolCall.from(toolName: "NotebookEdit",
                              toolInput: ["notebook_path": "/a/b.ipynb", "description": "d"])
        #expect(c == ToolCall(name: "NotebookEdit", command: nil, filePath: "/a/b.ipynb", description: "d"))
        let b = ToolCall.from(toolName: "Bash", toolInput: ["command": "ls", "file_path": "/f", "notebook_path": "/n"])
        #expect(b.command == "ls")
        #expect(b.filePath == "/f")
    }
}

import Testing
import Foundation
@testable import JarvisCore

@Suite struct ProcessTreeTests {
    func row(_ pid: Int32, _ ppid: Int32, _ tty: String, _ cmd: String) -> ProcessInfoRow {
        ProcessInfoRow(pid: pid, ppid: ppid, tty: tty, command: cmd)
    }

    @Test func interactiveClaudeAncestor() {
        let rows = [row(10, 9, "ttys003", "/usr/bin/jarvis-hook"), row(9, 8, "ttys003", "/bin/sh"),
                    row(8, 1, "ttys003", "/opt/homebrew/bin/claude")]
        #expect(ProcessTree.isInteractive(startPid: 10, rows: rows))
    }
    @Test func claudeWithoutTtyIsNonInteractive() {
        let rows = [row(10, 8, "??", "hook"), row(8, 1, "??", "claude")]
        #expect(!ProcessTree.isInteractive(startPid: 10, rows: rows))
    }
    @Test func noClaudeInChain() {
        let rows = [row(10, 9, "ttys001", "hook"), row(9, 1, "ttys001", "/bin/zsh")]
        #expect(!ProcessTree.isInteractive(startPid: 10, rows: rows))
    }
    @Test func parentCycleTerminates() {
        let rows = [row(10, 9, "ttys001", "a"), row(9, 10, "ttys001", "b")]
        #expect(!ProcessTree.isInteractive(startPid: 10, rows: rows))
    }
    @Test func sessionTtyIsTheClaudeRowsTty() {
        let rows = [row(10, 9, "??", "/usr/bin/jarvis-hook"), row(9, 8, "ttys001", "/bin/sh"),
                    row(8, 1, "ttys003", "/opt/homebrew/bin/claude")]
        #expect(ProcessTree.sessionTty(startPid: 10, rows: rows) == "/dev/ttys003")
    }
    @Test func sessionTtyEmptyWhenUnknown() {
        #expect(ProcessTree.sessionTty(startPid: 10, rows: [row(10, 8, "??", "hook"), row(8, 1, "??", "claude")]) == "")
        #expect(ProcessTree.sessionTty(startPid: 10, rows: [row(10, 9, "ttys001", "hook"), row(9, 1, "ttys001", "zsh")]) == "")
        #expect(ProcessTree.sessionTty(startPid: 10, rows: [row(10, 8, "ttys001", "hook"), row(8, 1, "", "claude")]) == "")
        #expect(ProcessTree.sessionTty(startPid: 10, rows: []) == "")
    }
    @Test func currentRowsIncludeSelf() {
        let rows = ProcessTree.currentRows()
        #expect(!rows.isEmpty)
        #expect(rows.contains { $0.pid == ProcessInfo.processInfo.processIdentifier })
    }
}

import Testing
@testable import JarvisCore

@Suite struct FocusRuleTests {
    private let tty = "/dev/ttys003"

    @Test func focusedPermissionHandsOff() {
        #expect(FocusRule.decide(kind: .permission, info: false, frontmostIsTerminal: true,
                                 selectedTty: tty, requestTty: tty) == .skipHandoff)
    }

    @Test func focusedStopEndsWithNothing() {
        for info in [false, true] {
            #expect(FocusRule.decide(kind: .stop, info: info, frontmostIsTerminal: true,
                                     selectedTty: tty, requestTty: tty) == .skipNone)
        }
    }

    @Test func terminalNotFrontmostShows() {
        #expect(FocusRule.decide(kind: .permission, info: false, frontmostIsTerminal: false,
                                 selectedTty: tty, requestTty: tty) == .show)
        #expect(FocusRule.decide(kind: .stop, info: true, frontmostIsTerminal: false,
                                 selectedTty: tty, requestTty: tty) == .show)
    }

    @Test func otherTabShows() {
        #expect(FocusRule.decide(kind: .permission, info: false, frontmostIsTerminal: true,
                                 selectedTty: "/dev/ttys004", requestTty: tty) == .show)
        // Exact comparison: a bare name or a prefix is not the same tab.
        #expect(FocusRule.decide(kind: .stop, info: false, frontmostIsTerminal: true,
                                 selectedTty: "ttys003", requestTty: tty) == .show)
        #expect(FocusRule.decide(kind: .stop, info: false, frontmostIsTerminal: true,
                                 selectedTty: "/dev/ttys0031", requestTty: tty) == .show)
    }

    @Test func unknownTtyShows() {
        // Check failed (nil) or nothing known about the session: never treated as focused.
        #expect(FocusRule.decide(kind: .permission, info: false, frontmostIsTerminal: true,
                                 selectedTty: nil, requestTty: tty) == .show)
        #expect(FocusRule.decide(kind: .permission, info: false, frontmostIsTerminal: true,
                                 selectedTty: "", requestTty: "") == .show)
        #expect(FocusRule.decide(kind: .stop, info: false, frontmostIsTerminal: true,
                                 selectedTty: tty, requestTty: "") == .show)
    }
}

import Foundation
import Testing

/// Controller ruling (v1.5): the held "Onaylıyorum" has no accessibility confirm. Any process with
/// Accessibility rights could otherwise AXPress it and send `ekranOnayi: true` or approve a risky
/// command without a human hold. The app target has no test target, so this pins it in its source.
@Suite struct HoldConfirmPolicyTests {
    private static func appSource(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/JarvisApp/" + file), encoding: .utf8)
    }

    @Test func holdButtonHasNoAccessibilityConfirm() throws {
        let buttons = try Self.appSource("AnswerButtons.swift")
        let start = try #require(buttons.range(of: "struct HoldToConfirmButton"))
        let hold = String(buttons[start.lowerBound...])
        #expect(!hold.contains(".accessibilityAction"))
        #expect(!hold.contains("accessibilityConfirm"))
        #expect(hold.contains(#".accessibilityHint(Text("1 saniye basılı tut"))"#))
        // No button of the panel is reachable without a recorded mouse-down.
        for file in ["AnswerButtons.swift", "PanelController.swift", "AppConversation.swift"] {
            let source = try Self.appSource(file)
            #expect(!source.contains("onAccessibilityButton"), "\(file)")
            #expect(!source.contains(".accessibilityAction"), "\(file)")
        }
    }
}

/// What to do with a request whose session may be the Terminal tab the user is already looking at.
public enum FocusDecision: Sendable, Equatable {
    /// Not focused (or unknown): the normal panel/voice flow.
    case show
    /// Focused permission or multiple-choice question: nothing is shown or spoken; the terminal's own
    /// dialog takes it.
    case skipHandoff
    /// Focused stop: nothing is shown or spoken; it ends with nothing to do.
    case skipNone
}

public enum FocusRule {
    public static let terminalBundleId = "com.apple.Terminal"

    /// Focused means Terminal.app is frontmost and its front window's selected tab has exactly the
    /// request's tty. Anything unknown (empty request tty, failed check = nil) is not focused.
    /// `info` does not change the outcome: a focused stop of any kind is skipped.
    public static func decide(kind: RequestKind, info: Bool, frontmostIsTerminal: Bool,
                              selectedTty: String?, requestTty: String) -> FocusDecision {
        guard frontmostIsTerminal, !requestTty.isEmpty, let selectedTty, selectedTty == requestTty else {
            return .show
        }
        switch kind {
        case .permission: return .skipHandoff
        case .stop: return .skipNone
        // Like a permission: the focused session's own dialog asks the question.
        case .choice: return .skipHandoff
        }
    }
}

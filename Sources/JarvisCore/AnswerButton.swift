import Foundation

/// A button the user can press instead of answering by voice.
/// `option(i)` picks option `i` (0-based) of the multiple-choice question on screen; its title is the
/// option's label, which the panel takes from the question.
public enum AnswerButton: Hashable, Sendable {
    case yes, confirm, no, terminal, done, ok
    /// "Konuşamam": turns quiet mode on and ends the ask with no decision (`QuietMode`). Offered on every
    /// ask; never approves, denies or picks anything.
    case notNow
    /// Office asks only: `cancel` ("İptal") leaves the high-risk confirm step without sending. Never
    /// offered for a hook request.
    case cancel
    case option(Int)

    /// The text of option button `index`: `"<n>. <label>"`, or the label alone when `numbered` is false
    /// (office asks, whose labels are already `"A) …"`).
    public static func optionText(_ index: Int, label: String, numbered: Bool) -> String {
        numbered ? "\(index + 1). \(label)" : label
    }

    /// The fixed buttons; option buttons depend on the question and are not listed.
    public static let fixedButtons: [AnswerButton] = [.yes, .confirm, .no, .terminal, .done, .ok, .notNow, .cancel]

    public var title: String {
        switch self {
        case .yes: return "Evet"
        case .confirm: return "Onaylıyorum"
        case .no: return "Hayır"
        case .terminal: return "Terminal"
        case .done: return "Yok, bitti"
        case .ok: return "Tamam"
        case .notNow: return "Konuşamam"
        case .cancel: return "İptal"
        case .option(let i): return "\(i + 1)"
        }
    }

    /// Name for the log: never carries an option's text.
    public var logName: String {
        switch self {
        case .yes: return "yes"
        case .confirm: return "confirm"
        case .no: return "no"
        case .terminal: return "terminal"
        case .done: return "done"
        case .ok: return "ok"
        case .notNow: return "notnow"
        case .cancel: return "cancel"
        case .option(let i): return "option\(i + 1)"
        }
    }

    /// Only the risky-action confirmation must be held; a quick click never confirms it.
    public var requiresHold: Bool { self == .confirm }

    /// The buttons offered for a request, in display order. For a `.choice`, those of its first question.
    public static func buttons(for r: JarvisRequest) -> [AnswerButton] {
        buttons(for: r, question: 0)
    }

    /// The buttons offered while question `question` of a `.choice` is on screen: one per option, then
    /// Konuşamam and Terminal. `question` is ignored for other kinds. Every ask offers Konuşamam, just
    /// before Terminal; an info display asks nothing and offers Tamam only.
    public static func buttons(for r: JarvisRequest, question: Int) -> [AnswerButton] {
        switch r.kind {
        case .permission: return r.risky ? [.confirm, .no, .notNow, .terminal] : [.yes, .no, .notNow, .terminal]
        case .stop:
            if r.asksQuestion { return [.yes, .no, .notNow, .terminal] }
            // Info: nothing is being asked, so the only answer is to dismiss it.
            return r.info ? [.ok] : [.done, .notNow, .terminal]
        case .choice:
            let count = r.choices.indices.contains(question) ? r.choices[question].options.count : 0
            return (0..<count).map { .option($0) } + [.notNow, .terminal]
        }
    }
}

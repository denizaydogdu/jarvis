import Foundation

/// The plain text the panel's copy button puts on the clipboard: everything the card shows, in order,
/// untruncated (the bold question line is cut at four lines on screen, the copy never is).
public enum PanelCopy {
    /// Non-empty parts joined by a blank line: the body, the question (left out when it is the body's own
    /// last asking sentence, as for a stop's full text), the detail, then one line per option.
    public static func text(body: String, question: String, detail: String,
                            options: [ChoiceOption], numberedOptions: Bool) -> String {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !body.isEmpty { parts.append(body) }
        if !question.isEmpty, SpeechText.lastQuestion(in: body) != question { parts.append(question) }
        if !detail.isEmpty { parts.append(detail) }
        let lines = options.enumerated().map { i, o in
            let label = numberedOptions ? "\(i + 1)) \(o.label)" : o.label
            let description = o.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? label : "\(label) — \(description)"
        }
        if !lines.isEmpty { parts.append(lines.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }
}

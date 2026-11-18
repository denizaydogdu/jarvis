import Foundation

/// Splits a request's spoken text into the body and the closing question the panel shows in bold.
public enum SpeechSplit {
    /// A stop that asks a question (`"<project> soruyor: <question>"`) shows `"<project> soruyor:"` as the
    /// body and the whole question as the question line. Everything else uses `split(_:)`.
    public static func split(for r: JarvisRequest) -> (body: String, question: String) {
        let prefix = "\(r.project) soruyor: "
        if r.kind == .stop, r.asksQuestion, r.speech.hasPrefix(prefix) {
            let question = r.speech.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !question.isEmpty { return ("\(r.project) soruyor:", question) }
        }
        return split(r.speech)
    }

    /// What the panel shows. A stop carries its full cleaned text in `detail`: that becomes the scrollable
    /// body, and the bold line is the last question, "Sırada ne var?" or the info line. A stop never has a
    /// monospace detail block. A permission keeps `split(_:)` plus its command/path/tool as `detail`.
    /// A stop without detail (no text, or an older hook binary) falls back to `split(for:)`.
    public static func panel(for r: JarvisRequest) -> (body: String, question: String, detail: String) {
        if r.kind == .choice {
            let c = choicePanel(for: r, question: 0)
            return (c.body, c.question, "")
        }
        guard r.kind == .stop else {
            let s = split(r.speech)
            return (s.body, s.question, r.detail)
        }
        let text = r.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            let s = split(for: r)
            return (s.body, s.question, "")
        }
        if r.asksQuestion { return (text, SpeechText.lastQuestion(in: text) ?? "", "") }
        if r.info { return (text, SpeechText.infoLine, "") }
        return (text, "Sırada ne var?", "")
    }

    /// The question is the text after the last `". "` when that remainder ends with `?` or `.`;
    /// the body is everything before it, ending with its full stop. When no such split exists,
    /// the whole text is the question and the body is empty.
    public static func split(_ speech: String) -> (body: String, question: String) {
        let text = speech.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = text.range(of: ". ", options: .backwards) else { return ("", text) }
        let question = text[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard question.hasSuffix("?") || question.hasSuffix(".") else { return ("", text) }
        let body = text[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines) + "."
        return (body, question)
    }

    /// What the panel shows for question `question` of a `.choice`: the body is "Soru i/n" (only when
    /// there are several) and the header; the bold line is the question. The options, with their
    /// descriptions, are the buttons.
    public static func choicePanel(for r: JarvisRequest, question: Int) -> (body: String, question: String) {
        guard r.choices.indices.contains(question) else { return ("", "") }
        let q = r.choices[question]
        var parts: [String] = []
        if r.choices.count > 1 { parts.append("Soru \(question + 1)/\(r.choices.count)") }
        let header = q.header.trimmingCharacters(in: .whitespacesAndNewlines)
        if !header.isEmpty { parts.append(header) }
        return (parts.joined(separator: " · "), q.question.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

import Foundation

/// One option of a multiple-choice question: its label answers the question; the description is only shown.
public struct ChoiceOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

/// One single-select question of Claude's AskUserQuestion tool.
public struct ChoiceQuestion: Codable, Equatable, Sendable {
    /// Exactly as Claude sent it: the answer is keyed by this text.
    public var question: String
    public var header: String
    public var options: [ChoiceOption]

    public init(question: String, header: String, options: [ChoiceOption]) {
        self.question = question
        self.header = header
        self.options = options
    }

    public static let maxQuestions = 4
    public static let optionRange = 2...4

    /// The questions of an AskUserQuestion `tool_input`, or nil when Jarvis does not support the call:
    /// it must have 1–4 questions, each single-select (`multiSelect` absent or false) with a non-blank
    /// question text and 2–4 options with non-empty labels. Question texts must differ (answers are keyed
    /// by them), and so must the labels of one question. `header` and `description` may be absent.
    public static func parse(toolInput: [String: Any]) -> [ChoiceQuestion]? {
        guard let raw = toolInput["questions"] as? [Any], (1...maxQuestions).contains(raw.count) else { return nil }
        var result: [ChoiceQuestion] = []
        for item in raw {
            guard let q = item as? [String: Any],
                  let text = q["question"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !result.contains(where: { $0.question == text }) else { return nil }
            if let multi = q["multiSelect"] {
                guard let flag = multi as? Bool, isBoolean(multi), !flag else { return nil }
            }
            if let header = q["header"], !(header is String) { return nil }
            guard let rawOptions = q["options"] as? [Any], optionRange.contains(rawOptions.count) else { return nil }
            var options: [ChoiceOption] = []
            for o in rawOptions {
                guard let option = o as? [String: Any],
                      let label = option["label"] as? String, !label.isEmpty,
                      !options.contains(where: { $0.label == label }) else { return nil }
                if let d = option["description"], !(d is String) { return nil }
                options.append(ChoiceOption(label: label, description: option["description"] as? String ?? ""))
            }
            result.append(ChoiceQuestion(question: text, header: q["header"] as? String ?? "", options: options))
        }
        return result
    }

    /// JSONSerialization yields NSNumber for both numbers and booleans; only a real JSON boolean counts.
    private static func isBoolean(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }
}

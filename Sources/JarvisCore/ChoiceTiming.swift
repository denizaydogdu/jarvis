import Foundation

/// How long a spoken multiple-choice ask takes, estimated before anything is spoken.
public enum ChoiceTiming {
    /// Speech rate used for the estimate.
    public static let secondsPerCharacter = 0.12
    /// The listening window after each question.
    public static let listenSecondsPerQuestion = 20.0

    /// Spoken characters of every question (`SpeechText.choice`) at `secondsPerCharacter`, plus
    /// `listenSecondsPerQuestion` per question. 0 for any request that is not a `.choice`.
    public static func estimatedSeconds(for r: JarvisRequest) -> Double {
        guard r.kind == .choice else { return 0 }
        return r.choices.reduce(0) { total, question in
            let characters = SpeechText.choice(project: r.project, question: question).count
            return total + Double(characters) * secondsPerCharacter + listenSecondsPerQuestion
        }
    }

    /// A `.choice` whose spoken ask would not fit in `capSeconds` is asked silently (buttons only), so it
    /// is still answered by a button instead of running out of time halfway.
    public static func asksSilently(_ r: JarvisRequest, capSeconds: Double) -> Bool {
        r.kind == .choice && estimatedSeconds(for: r) > capSeconds
    }
}

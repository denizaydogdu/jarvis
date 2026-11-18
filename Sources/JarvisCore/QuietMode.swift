import Foundation

/// "Şu an konuşamam": while quiet mode is active Jarvis asks nothing. Hook requests are answered at once
/// with no decision (the session's own terminal takes them) and counted as missed; office decisions wait
/// for the end of quiet mode. Pure value: the queue keeps one, in memory only.
public struct QuietMode: Equatable, Sendable {
    /// A hook request answered without asking while quiet: project and kind only, never content.
    public struct Missed: Equatable, Sendable {
        public var project: String
        public var kind: RequestKind

        public init(project: String, kind: RequestKind) {
            self.project = project
            self.kind = kind
        }
    }

    /// The "Konuşamam" button and the spoken "sonra" turn quiet mode on for this long.
    public static let defaultSeconds: TimeInterval = 30 * 60
    /// The resume sentence names at most this many projects.
    static let maxNamedProjects = 3

    public private(set) var isOn = false
    /// The end time; nil while on means "until turned off".
    public private(set) var until: Date?
    /// In arrival order; kept across `turnOn` calls (also after an expired period), until quiet mode is ended.
    public private(set) var missed: [Missed] = []

    public init() {}

    /// Turns quiet mode on, or moves its end; `until: nil` lasts until turned off. The missed list is kept
    /// until quiet mode is ended, even when the previous period had already expired: losing a resume sentence
    /// is worse than two periods merging into one, and the app ends an expired period within
    /// `QuietControl.timerStepSeconds`, so a merge is rare.
    public mutating func turnOn(until: Date?) {
        isOn = true
        self.until = until
    }

    public mutating func record(_ m: Missed) {
        missed.append(m)
    }

    /// On, and its end time (if any) not reached yet.
    public func isActive(now: Date) -> Bool {
        guard isOn else { return false }
        guard let until else { return true }
        return now < until
    }

    /// The end of "Bugün": the next midnight in `calendar`.
    public static func endOfToday(now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    }

    /// The sentence said once when quiet mode ends, or nil when nothing was missed:
    /// "Sen yokken N soru geldi: a, b ve c. Terminalde bekliyorlar." Projects are distinct, in first-seen
    /// order; past three, "a, b, c ve diğerleri".
    public func summaryText() -> String? {
        guard !missed.isEmpty else { return nil }
        var projects: [String] = []
        for m in missed where !projects.contains(m.project) { projects.append(m.project) }
        let names: String
        if projects.count > Self.maxNamedProjects {
            names = projects.prefix(Self.maxNamedProjects).joined(separator: ", ") + " ve diğerleri"
        } else if projects.count == 1 {
            names = projects[0]
        } else {
            names = projects.dropLast().joined(separator: ", ") + " ve " + projects[projects.count - 1]
        }
        return "Sen yokken \(missed.count) soru geldi: \(names). Terminalde bekliyorlar."
    }
}

/// What the queue tells its observer about quiet mode; the app updates its icon and log from it.
public enum QuietEvent: Equatable, Sendable {
    /// Turned on or its end moved (`setQuiet`, or a "Konuşamam" answer).
    case on(QuietMode)
    /// A hook request was answered without asking; the mode carries the updated list.
    case missed(QuietMode.Missed, QuietMode)
}

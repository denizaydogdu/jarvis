import Foundation

/// The app's wording around quiet mode: the menu's status line, the count beside the menu-bar moon, the
/// log label of quiet mode turning on and the resume display. Pure, so it is tested here; the app shows it.
public enum QuietStatus {
    /// Session and project caption of the resume display; it never leaves the app.
    public static let sessionId = "jarvis"
    public static let project = "Jarvis"
    /// Like the office displays: the queue would drop it only after waiting far longer than it ever does.
    public static let deadlineSeconds = 150

    /// "Sessiz: 21:45'e kadar", "Sessiz: gece yarısına kadar" (the end of "Bugün") or
    /// "Sessiz: kapatana kadar"; nil while quiet mode is off.
    public static func menuLine(_ mode: QuietMode, calendar: Calendar = .current) -> String? {
        guard mode.isOn else { return nil }
        guard let until = mode.until else { return "Sessiz: kapatana kadar" }
        return "Sessiz: " + untilText(until, calendar: calendar)
    }

    /// "21:45'e kadar": the dative suffix follows the clock time as read aloud, by its last spoken number
    /// (the minutes, or the hour on the hour). Midnight reads "gece yarısına kadar".
    static func untilText(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        if hour == 0, minute == 0 { return "gece yarısına kadar" }
        let clock = String(format: "%02d:%02d", hour, minute)
        return clock + "'" + dative(minute != 0 ? minute : hour) + " kadar"
    }

    /// The dative suffix (without the apostrophe) of a number 0–59 read aloud in Turkish:
    /// "bir'e", "iki'ye", "altı'ya", "dokuz'a", "on'a", "yirmi'ye", "otuz'a", "kırk'a", "elli'ye".
    static func dative(_ n: Int) -> String {
        // sıfır, bir, iki, üç, dört, beş, altı, yedi, sekiz, dokuz
        let units = ["a", "e", "ye", "e", "e", "e", "ya", "ye", "e", "a"]
        // -, on, yirmi, otuz, kırk, elli
        let tens = ["a", "a", "ye", "a", "a", "ye"]
        let n = abs(n) % 60
        if n == 0 || n % 10 != 0 { return units[n % 10] }
        return tens[n / 10]
    }

    /// The title beside the menu-bar moon: the number of missed requests, empty when none (or when off).
    public static func countTitle(_ mode: QuietMode) -> String {
        mode.isOn && !mode.missed.isEmpty ? String(mode.missed.count) : ""
    }

    /// The word of the `quiet: on <label>` log line: "manual" without an end, "today" for the end of
    /// "Bugün", otherwise the minutes left, rounded.
    public static func logLabel(_ mode: QuietMode, now: Date, calendar: Calendar = .current) -> String {
        guard let until = mode.until else { return "manual" }
        if until == QuietMode.endOfToday(now: now, calendar: calendar) { return "today" }
        return String(max(0, Int((until.timeIntervalSince(now) / 60).rounded())))
    }

    /// Whether the end-time timer set for `timerEnd` ends quiet mode at `now`: only when quiet mode is still
    /// on with that very end (a newer end, or a new quiet mode turned on meanwhile, keeps running) and the
    /// wall clock has reached it (a backward clock step means it has not, and the timer is set again).
    public static func shouldEnd(_ mode: QuietMode, timerEnd: Date, now: Date) -> Bool {
        mode.isOn && mode.until == timerEnd && now >= timerEnd
    }

    /// The resume sentence (`QuietMode.summaryText`) as an info display: spoken and shown, never listened to.
    public static func summaryRequest(_ text: String, id: String) -> JarvisRequest {
        JarvisRequest(id: id, sessionId: sessionId, project: project, kind: .stop, speech: text, detail: text,
                      risky: false, deadlineS: deadlineSeconds, info: true)
    }
}

import Foundation
import Testing
@testable import JarvisCore

@Suite struct QuietStatusTests {
    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return c
    }

    private static func at(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour, minute: minute))!
    }

    private static func mode(until: Date?, missed: [String] = []) -> QuietMode {
        var m = QuietMode()
        m.turnOn(until: until)
        for p in missed { m.record(.init(project: p, kind: .permission)) }
        return m
    }

    @Test func timerEndsQuietOnlyAtItsOwnEndOnceReached() {
        let end = Self.at(21, 45)
        let mode = Self.mode(until: end)
        #expect(QuietStatus.shouldEnd(mode, timerEnd: end, now: end))
        #expect(QuietStatus.shouldEnd(mode, timerEnd: end, now: end.addingTimeInterval(30)))
        // The clock stepped back after the timer fired: not yet; the timer is set again.
        #expect(!QuietStatus.shouldEnd(mode, timerEnd: end, now: end.addingTimeInterval(-60)))
    }

    @Test func timerForAnOldEndDoesNotEndQuiet() {
        let old = Self.at(21, 45)
        let after = old.addingTimeInterval(60)
        // The end moved later, or quiet mode was turned on again without an end.
        #expect(!QuietStatus.shouldEnd(Self.mode(until: Self.at(22, 30)), timerEnd: old, now: after))
        #expect(!QuietStatus.shouldEnd(Self.mode(until: nil), timerEnd: old, now: after))
        // Already ended.
        #expect(!QuietStatus.shouldEnd(QuietMode(), timerEnd: old, now: after))
    }

    @Test func menuLineIsNilWhileOff() {
        #expect(QuietStatus.menuLine(QuietMode(), calendar: Self.calendar) == nil)
    }

    @Test func menuLineWithoutAnEnd() {
        #expect(QuietStatus.menuLine(Self.mode(until: nil), calendar: Self.calendar) == "Sessiz: kapatana kadar")
    }

    @Test func menuLineShowsTheEndTimeWithItsSuffix() {
        let line = { (h: Int, m: Int) in QuietStatus.menuLine(Self.mode(until: Self.at(h, m)), calendar: Self.calendar) }
        #expect(line(21, 45) == "Sessiz: 21:45'e kadar")
        #expect(line(21, 30) == "Sessiz: 21:30'a kadar")
        #expect(line(21, 6) == "Sessiz: 21:06'ya kadar")
        #expect(line(9, 7) == "Sessiz: 09:07'ye kadar")
        #expect(line(22, 9) == "Sessiz: 22:09'a kadar")
        #expect(line(22, 50) == "Sessiz: 22:50'ye kadar")
        // On the hour, the hour is the last number read aloud.
        #expect(line(22, 0) == "Sessiz: 22:00'ye kadar")
        #expect(line(21, 0) == "Sessiz: 21:00'e kadar")
        #expect(line(10, 0) == "Sessiz: 10:00'a kadar")
        #expect(line(20, 0) == "Sessiz: 20:00'ye kadar")
    }

    @Test func menuLineForTheEndOfToday() {
        let end = QuietMode.endOfToday(now: Self.at(21, 15), calendar: Self.calendar)
        #expect(QuietStatus.menuLine(Self.mode(until: end), calendar: Self.calendar) == "Sessiz: gece yarısına kadar")
    }

    @Test func dativeOfEveryClockNumber() {
        let expected: [Int: String] = [0: "a", 1: "e", 2: "ye", 3: "e", 4: "e", 5: "e", 6: "ya", 7: "ye", 8: "e",
                                       9: "a", 10: "a", 20: "ye", 30: "a", 40: "a", 50: "ye", 11: "e", 23: "e",
                                       36: "ya", 59: "a"]
        for (n, suffix) in expected {
            #expect(QuietStatus.dative(n) == suffix, "\(n)")
        }
    }

    @Test func countTitleShowsTheMissedCountOnlyWhenSomethingWasMissed() {
        #expect(QuietStatus.countTitle(QuietMode()) == "")
        #expect(QuietStatus.countTitle(Self.mode(until: nil)) == "")
        #expect(QuietStatus.countTitle(Self.mode(until: nil, missed: ["a", "b", "a"])) == "3")
    }

    @Test func logLabels() {
        let now = Self.at(21, 15)
        #expect(QuietStatus.logLabel(Self.mode(until: nil), now: now, calendar: Self.calendar) == "manual")
        let today = QuietMode.endOfToday(now: now, calendar: Self.calendar)
        #expect(QuietStatus.logLabel(Self.mode(until: today), now: now, calendar: Self.calendar) == "today")
        let half = now.addingTimeInterval(QuietMode.defaultSeconds)
        #expect(QuietStatus.logLabel(Self.mode(until: half), now: now.addingTimeInterval(2), calendar: Self.calendar) == "30")
        #expect(QuietStatus.logLabel(Self.mode(until: now.addingTimeInterval(3600)), now: now, calendar: Self.calendar) == "60")
    }

    @Test func summaryRequestIsAnInfoDisplay() {
        let r = QuietStatus.summaryRequest("Sen yokken 1 soru geldi: a. Terminalde bekliyorlar.", id: "quiet-1")
        #expect(r.isInfoStop)
        #expect(r.speech == r.detail)
        #expect(!OfisCards.isOfficeInfo(r))
        #expect(!OfisCards.isOfficeAsk(r))
        #expect(r.tty.isEmpty)
    }

    /// The resume sentence reaches the conversation once quiet mode has ended, also while muted (the app
    /// asked for it), and it is not counted as missed.
    @Test func summaryIsShownAfterQuietModeEndsEvenWhenMuted() async throws {
        let conv = FakeConversation { _ in (0, {}, .button(.ok)) }
        let q = RequestQueue(conversation: conv)
        await q.setMuted(true)
        await q.setQuiet(until: nil)
        _ = await q.submit(JarvisRequest(id: "a", sessionId: "s", project: "p", kind: .permission, speech: "x",
                                         detail: "d", risky: false, deadlineS: 120))
        let text = try #require(await q.endQuiet().summaryText())
        let r = await q.submit(QuietStatus.summaryRequest(text, id: "quiet-1"), showWhenMuted: true)
        #expect(r.status == .answered)
        await q.drain()
        #expect(conv.asked == ["quiet-1"])
        #expect(conv.silentFlags == [true])
        #expect(await q.quietMode.missed.isEmpty)
    }
}

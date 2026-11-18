import Foundation
import Testing
@testable import JarvisCore

private func karar(note: String = "2026-11-14-blog-ceo-sorusu.md", options: [(String, String)] = [("A", "Birim testler"), ("B", "Uçtan uca")],
                   risk: String = "normal", riskNedeni: String = "", ekranOnayi: Bool = false,
                   iletildi: Bool = false, soru: String = "Hangisini seçelim?") -> OfisKarar {
    OfisKarar(note: note, baslik: "Test yaklaşımı", proje: "blog", tur: "ceo-sorusu", soru: soru,
              secenekler: options.map { OfisSecenek(kod: $0.0, metin: $0.1) }, risk: risk, riskNedeni: riskNedeni,
              ekranOnayiGerekir: ekranOnayi, soruldu: "2026-11-14T10:00", cevapIletildi: iletildi)
}

@Suite struct OfisCardsTests {
    @Test func cardWithOptionsBecomesChoiceAsk() throws {
        let ask = try #require(OfisCards.ask(for: karar()))
        #expect(ask.kind == .choice)
        #expect(ask.note == "2026-11-14-blog-ceo-sorusu.md")
        #expect(ask.options == [OfisAsk.Option(label: "A) Birim testler", answer: "A"),
                                OfisAsk.Option(label: "B) Uçtan uca", answer: "B")])
        #expect(ask.question == ChoiceQuestion(question: "Hangisini seçelim?", header: "Test yaklaşımı", options: [
            ChoiceOption(label: "A) Birim testler", description: ""), ChoiceOption(label: "B) Uçtan uca", description: ""),
        ]))
        #expect(ask.speech == "Ofis soruyor: blog — Test yaklaşımı. Hangisini seçelim? Seçenekler: A, Birim testler; B, Uçtan uca.")
        #expect(ask.answer(forLabel: "B) Uçtan uca") == "B")
        #expect(ask.answer(forLabel: "Uçtan uca") == nil)
        #expect(!ask.highRisk)
        #expect(!ask.needsScreenConfirm)
        #expect(ask.riskLine == nil)
    }

    @Test func oneToFourOptionsAreAsked() {
        for n in 1...4 {
            let opts = (0..<n).map { (String(UnicodeScalar(UInt8(65 + $0))), "Seçenek \($0)") }
            #expect(OfisCards.ask(for: karar(options: opts))?.options.count == n)
        }
    }

    @Test func cardWithoutOptionsBecomesYesNo() throws {
        let ask = try #require(OfisCards.ask(for: karar(options: [], soru: "main dalına zorla gönderelim mi")))
        #expect(ask.kind == .yesNo)
        #expect(ask.options == [OfisAsk.Option(label: "Evet", answer: "Evet"), OfisAsk.Option(label: "Hayır", answer: "Hayır")])
        #expect(ask.question.options.map(\.label) == ["Evet", "Hayır"])
        #expect(ask.speech == "Ofis soruyor: blog — Test yaklaşımı. main dalına zorla gönderelim mi. Seçenekler: Evet; Hayır.")
    }

    @Test func moreThanFourOptionsStayOnThePage() throws {
        let opts = ["A", "B", "C", "D", "E"].map { ($0, "x") }
        let k = karar(options: opts)
        #expect(OfisCards.ask(for: k) == nil)
        #expect(OfisCards.skipReason(for: k) == "more than 4 options")

        let dir = try ofisTempDir()
        let log = JarvisLog(path: dir + "/jarvis.log")
        #expect(OfisCards.ask(for: k, log: log) == nil)
        let text = try String(contentsOfFile: log.path, encoding: .utf8)
        #expect(text.contains("ofis: skipped 2026-11-14-blog-ceo-sorusu.md: more than 4 options"))
        #expect(!text.contains("Hangisini"))  // no question text in the log
    }

    @Test func alreadyAnsweredIsNotAsked() {
        let k = karar(iletildi: true)
        #expect(OfisCards.ask(for: k) == nil)
        #expect(OfisCards.skipReason(for: k) == "answer already on its way")
    }

    @Test func unsupportedCodesAreNotAsked() {
        #expect(OfisCards.ask(for: karar(options: [("A", "x"), ("A", "y")])) == nil)
        #expect(OfisCards.ask(for: karar(options: [("A B", "x")])) == nil)
        #expect(OfisCards.ask(for: karar(options: [("", "x")])) == nil)
        #expect(OfisCards.skipReason(for: karar(options: [("", "x")])) == "unsupported option code")
        #expect(OfisCards.ask(for: karar(note: "")) == nil)
        #expect(OfisCards.skipReason(for: karar()) == nil)
    }

    @Test func riskFlagsAreCarried() throws {
        let high = try #require(OfisCards.ask(for: karar(options: [], risk: "yuksek",
                                                         riskNedeni: "zorla gönderme ya da geçmişi yeniden yazma",
                                                         ekranOnayi: true)))
        #expect(high.highRisk)
        #expect(high.needsScreenConfirm)
        #expect(high.riskLine == "Yüksek risk: zorla gönderme ya da geçmişi yeniden yazma")

        // The gate's own flag alone also demands the on-screen confirmation.
        let flagged = try #require(OfisCards.ask(for: karar(ekranOnayi: true)))
        #expect(!flagged.highRisk)
        #expect(flagged.needsScreenConfirm)
        #expect(flagged.riskLine == nil)

        let noReason = try #require(OfisCards.ask(for: karar(risk: "yuksek")))
        #expect(noReason.needsScreenConfirm)
        #expect(noReason.riskLine == "Yüksek risk")
    }
}

@Suite struct OfisSeenTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func newNoteIsAskedOnce() {
        var seen = OfisSeen()
        #expect(seen.shouldAsk("a.md", now: t0))
        seen.markAsked("a.md", at: t0)
        #expect(!seen.shouldAsk("a.md", now: t0))
        #expect(!seen.shouldAsk("a.md", now: t0 + 86_400))
        #expect(seen.shouldAsk("b.md", now: t0))
    }

    @Test func sonraSnoozesThirtyMinutes() {
        var seen = OfisSeen()
        seen.markAsked("a.md", at: t0)
        seen.snooze("a.md", now: t0)
        #expect(OfisSeen.cancelSnooze == 30 * 60)
        #expect(!seen.shouldAsk("a.md", now: t0 + 29 * 60))
        #expect(seen.shouldAsk("a.md", now: t0 + 30 * 60))
        // A shorter snooze (silence) is also supported.
        seen.markAsked("a.md", at: t0 + 30 * 60)
        seen.snooze("a.md", for: 10 * 60, now: t0 + 30 * 60)
        #expect(!seen.shouldAsk("a.md", now: t0 + 39 * 60))
        #expect(seen.shouldAsk("a.md", now: t0 + 40 * 60))
    }

    @Test func pruneForgetsNotesNoLongerPending() {
        var seen = OfisSeen()
        seen.markAsked("a.md", at: t0)
        seen.snooze("b.md", now: t0)
        seen.markAsked("c.md", at: t0)
        seen.prune(keeping: ["c.md"])
        #expect(seen.asked.keys.sorted() == ["c.md"])
        #expect(seen.snoozed.isEmpty)
    }

    @Test func concurrentSavesNeverCollide() throws {
        let path = try ofisTempDir() + "/ofis-seen.json"
        let failures = OfisPortBox(0)
        let start = t0
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            var seen = OfisSeen()
            seen.markAsked("n\(i).md", at: start)
            do { try seen.save(to: path) } catch { failures.port += 1 }
        }
        #expect(failures.port == 0)
        #expect(OfisSeen.load(from: path).asked.count == 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: (path as NSString).deletingLastPathComponent)
        #expect(leftovers == ["ofis-seen.json"])
        // Deterministic part: every save gets its own temp file in the same directory.
        let a = OfisSeen.tempPath(for: path), b = OfisSeen.tempPath(for: path)
        #expect(a != b)
        #expect(a.hasPrefix(path + ".tmp-") && b.hasPrefix(path + ".tmp-"))
    }

    @Test func persistsNamesAndTimesOnlyWithMode0600() throws {
        let path = try ofisTempDir() + "/sub/ofis-seen.json"
        var seen = OfisSeen()
        seen.markAsked("a.md", at: t0)
        seen.snooze("b.md", now: t0)
        try seen.save(to: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let loaded = OfisSeen.load(from: path)
        #expect(loaded == seen)

        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        #expect(Set(obj.keys) == ["asked", "snoozed"])
        #expect((obj["asked"] as? [String: String])?.keys.sorted() == ["a.md"])
        #expect((obj["snoozed"] as? [String: String])?.keys.sorted() == ["b.md"])

        // Rewriting a file with a looser mode tightens it again.
        chmod(path, 0o644)
        try seen.save(to: path)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func corruptOrMissingFileStartsEmpty() throws {
        let dir = try ofisTempDir()
        #expect(OfisSeen.load(from: dir + "/none.json") == OfisSeen())
        let path = dir + "/ofis-seen.json"
        for garbage in ["{not json", "[]", #"{"asked": 5}"#, #"{"asked": {"a.md": "yesterday"}}"#] {
            try garbage.write(toFile: path, atomically: true, encoding: .utf8)
            #expect(OfisSeen.load(from: path) == OfisSeen())
        }
    }

    @Test func standardPath() {
        #expect(OfisSeen.path(in: JarvisPaths(dir: "/Users/x/.jarvis")) == "/Users/x/.jarvis/ofis-seen.json")
    }
}

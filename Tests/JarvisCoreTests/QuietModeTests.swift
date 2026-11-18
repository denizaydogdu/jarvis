import Foundation
import Testing
@testable import JarvisCore

private func quietReq(_ id: String, kind: RequestKind = .permission, project: String = "p", risky: Bool = false,
                      asksQuestion: Bool = false, info: Bool = false) -> JarvisRequest {
    let choices = kind == .choice
        ? [ChoiceQuestion(question: "Q?", header: "", options: [ChoiceOption(label: "x", description: ""),
                                                                ChoiceOption(label: "y", description: "")])]
        : []
    return JarvisRequest(id: id, sessionId: "s", project: project, kind: kind, speech: "x", detail: "d",
                         risky: risky, deadlineS: 120, asksQuestion: asksQuestion, info: info, choices: choices)
}

private func officeKarar() -> OfisKarar {
    OfisKarar(note: "n1.md", baslik: "Test", proje: "blog", tur: "ceo-sorusu", soru: "Hangisi?",
              secenekler: [OfisSecenek(kod: "A", metin: "Birim"), OfisSecenek(kod: "B", metin: "Uçtan uca")],
              risk: "normal", riskNedeni: "", ekranOnayiGerekir: false, soruldu: "2026-11-14T10:00", cevapIletildi: false)
}

private func officeAsk(_ id: String) -> JarvisRequest {
    OfisCards.request(for: OfisCards.ask(for: officeKarar())!, id: id)
}

/// No approval, denial, instruction or pick: the hook prints nothing for it.
private func expectNoDecision(_ r: JarvisResponse, id: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(r.id == id, sourceLocation: sourceLocation)
    #expect(r.status == .handoff, sourceLocation: sourceLocation)
    #expect(r.intent == Intent.none, sourceLocation: sourceLocation)
    #expect(r.transcript == nil, sourceLocation: sourceLocation)
    #expect(r.answers == nil, sourceLocation: sourceLocation)
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [QuietEvent] = []
    func add(_ e: QuietEvent) { lock.withLock { list.append(e) } }
    var events: [QuietEvent] { lock.withLock { list } }
}

// MARK: - QuietMode value

@Suite struct QuietModeValueTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func offByDefault() {
        let q = QuietMode()
        #expect(!q.isOn)
        #expect(!q.isActive(now: t0))
        #expect(q.until == nil)
        #expect(q.missed.isEmpty)
    }

    @Test func timedQuietEndsAtItsTime() {
        var q = QuietMode()
        q.turnOn(until: t0.addingTimeInterval(60))
        #expect(q.isOn)
        #expect(q.isActive(now: t0))
        #expect(q.isActive(now: t0.addingTimeInterval(59)))
        #expect(!q.isActive(now: t0.addingTimeInterval(60)))
        #expect(!q.isActive(now: t0.addingTimeInterval(3600)))
    }

    @Test func manualQuietLastsUntilTurnedOff() {
        var q = QuietMode()
        q.turnOn(until: nil)
        #expect(q.isActive(now: t0.addingTimeInterval(365 * 86_400)))
    }

    @Test func defaultIsThirtyMinutes() {
        #expect(QuietMode.defaultSeconds == 30 * 60)
    }

    @Test func turningOnAgainKeepsTheMissedList() {
        var q = QuietMode()
        q.turnOn(until: t0.addingTimeInterval(60))
        q.record(.init(project: "a", kind: .permission))
        q.turnOn(until: nil)
        #expect(q.missed == [.init(project: "a", kind: .permission)])
        #expect(q.until == nil)
    }

    @Test func endOfTodayIsTheNextMidnight() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: "Europe/Istanbul"))
        let evening = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 21, minute: 45)))
        let midnight = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 0, minute: 0)))
        #expect(QuietMode.endOfToday(now: evening, calendar: cal) == midnight)
        // Exactly at midnight, "today" is the day that has just begun.
        let next = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        #expect(QuietMode.endOfToday(now: midnight, calendar: cal) == next)
    }

    private func summary(_ projects: [String]) -> String? {
        var q = QuietMode()
        q.turnOn(until: nil)
        for p in projects { q.record(.init(project: p, kind: .stop)) }
        return q.summaryText()
    }

    @Test func summaryWithNothingMissedIsNil() {
        #expect(summary([]) == nil)
    }

    @Test func summaryWithOneProject() {
        #expect(summary(["jarvis"]) == "Sen yokken 1 soru geldi: jarvis. Terminalde bekliyorlar.")
    }

    @Test func summaryNamesDistinctProjectsInOrder() {
        #expect(summary(["a", "b", "a"]) == "Sen yokken 3 soru geldi: a ve b. Terminalde bekliyorlar.")
        #expect(summary(["a", "b", "c"]) == "Sen yokken 3 soru geldi: a, b ve c. Terminalde bekliyorlar.")
    }

    @Test func summaryNamesAtMostThreeProjects() {
        #expect(summary(["a", "b", "c", "d", "e"])
                == "Sen yokken 5 soru geldi: a, b, c ve diğerleri. Terminalde bekliyorlar.")
    }
}

// MARK: - Voice

@Suite struct NotNowIntentTests {
    private func h(_ s: String) -> Heard { Heard(text: s, confidence: 0.9) }

    @Test func wholeUtterancePhrasesAreRecognised() {
        for s in ["şu an konuşamam", "Şimdi konuşamam.", "konuşamam", "Sonra", "sonra konuşalım",
                  "Şu an konuşamam!", "şuan konuşamam"] {
            #expect(IntentParser.notNow(h(s)), "\(s)")
        }
    }

    @Test func fillersAreAllowed() {
        for s in ["şey, sonra", "ya konuşamam ya", "kedi şu an konuşamam", "Şey... sonra konuşalım"] {
            #expect(IntentParser.notNow(h(s)), "\(s)")
        }
    }

    @Test func sonraInsideALongerAnswerDoesNotCount() {
        for s in ["", "şey", "kedi", "şu an", "sonra testleri çalıştır", "evet sonra", "bunu sonra yap",
                  "sonra mı", "konuşamam ama evet", "hayır sonra", "sonra sonra", "ikinci sonra"] {
            #expect(!IntentParser.notNow(h(s)), "\(s)")
        }
    }

    @Test func notNowWinsBeforeTheOtherRules() {
        // Without the not-now rule, a two-word stop reply would be a "continue" instruction.
        #expect(IntentParser.stop(h("sonra konuşalım"), asksQuestion: true).intent == .proceed)
        #expect(IntentParser.notNow(h("sonra konuşalım")))
    }
}

// MARK: - Queue

@Suite struct QuietQueueTests {
    @Test func everyHookKindIsAnsweredAtOnceWithoutADecisionAndCounted() async {
        let conv = FakeConversation { _ in (0, {}, .button(.yes)) }
        let q = RequestQueue(conversation: conv)
        await q.setQuiet(until: nil)
        let requests = [
            quietReq("perm", kind: .permission, project: "a"),
            quietReq("risky", kind: .permission, project: "b", risky: true),
            quietReq("stop", kind: .stop, project: "c"),
            quietReq("question", kind: .stop, project: "c", asksQuestion: true),
            quietReq("choice", kind: .choice, project: "d"),
        ]
        for r in requests {
            expectNoDecision(await q.submit(r), id: r.id)
        }
        #expect(conv.asked.isEmpty)
        let missed = await q.quietMode.missed
        #expect(missed == [.init(project: "a", kind: .permission), .init(project: "b", kind: .permission),
                           .init(project: "c", kind: .stop), .init(project: "c", kind: .stop),
                           .init(project: "d", kind: .choice)])
    }

    @Test func quietResponsesMakeTheHookPrintNothing() async {
        let q = RequestQueue(conversation: FakeConversation { _ in (0, {}, .button(.yes)) })
        await q.setQuiet(until: nil)
        let permission = await q.submit(quietReq("req-1", kind: .permission, risky: true))
        let stop = await q.submit(quietReq("req-1", kind: .stop, asksQuestion: true))
        let choice = await q.submit(quietReq("req-1", kind: .choice))
        func deps(_ r: JarvisResponse) -> HookDeps {
            HookDeps(send: { _ in r }, isInteractive: { true }, excludedPrefixes: [], ofisFileContents: [], env: [:],
                     home: "/Users/test", log: { _ in }, newId: { "req-1" })
        }
        let base = "{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\""
        let perm = Data((base + ",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}").utf8)
        let ask = Data((base + ",\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[{\"question\":\"Q?\",\"header\":\"H\",\"multiSelect\":false,\"options\":[{\"label\":\"x\",\"description\":\"\"},{\"label\":\"y\",\"description\":\"\"}]}]}}").utf8)
        #expect(HookRunner.run(event: .permission, stdin: perm, deps: deps(permission)) == "")
        #expect(HookRunner.run(event: .stop, stdin: Data((base + "}").utf8), deps: deps(stop)) == "")
        #expect(HookRunner.run(event: .ask, stdin: ask, deps: deps(choice)) == "")
    }

    @Test func infoDisplaysAreDroppedAndNotCounted() async {
        let conv = FakeConversation { _ in (0, {}, .button(.ok)) }
        let q = RequestQueue(conversation: conv)
        await q.setQuiet(until: nil)
        let r = await q.submit(quietReq("info", kind: .stop, info: true))
        #expect(r.status == .answered)
        await q.drain()
        #expect(conv.asked.isEmpty)
        #expect(await q.quietMode.missed.isEmpty)
    }

    @Test func appDisplayIsStillShownSilently() async {
        let conv = FakeConversation { _ in (0, {}, .button(.ok)) }
        let q = RequestQueue(conversation: conv)
        await q.setQuiet(until: nil)
        _ = await q.submit(OfisCards.statusRequest("Ofis: 2 karar bekliyor."), showWhenMuted: true)
        await q.drain()
        #expect(conv.asked.count == 1)
        #expect(conv.silentFlags == [true])
        #expect(await q.quietMode.missed.isEmpty)
    }

    @Test func officeAskWaitsForTheEndOfQuietMode() async {
        let conv = FakeConversation { _ in (0, {}, .choices([0])) }
        let q = RequestQueue(conversation: conv)
        await q.setQuiet(until: nil)
        let r = await q.submit(officeAsk("ofis-1"))
        // Not shown, nothing picked: the poller retries it (OfisOutcome `.retry`), and it is not a missed
        // terminal question.
        #expect(r.status == .expired)
        #expect(r.answers == nil)
        #expect(conv.asked.isEmpty)
        #expect(await q.quietMode.missed.isEmpty)
        #expect(OfisOutcome.decide(ask: OfisCards.ask(for: officeKarar())!, response: r, mark: nil) == .retry)
    }

    @Test func quietModeExpiresByTheClock() async {
        let clock = TestClock()
        let conv = FakeConversation { _ in (0, {}, .button(.yes)) }
        let q = RequestQueue(conversation: conv, now: clock.now)
        await q.setQuiet(until: clock.now().addingTimeInterval(60))
        #expect(await q.isQuiet)
        expectNoDecision(await q.submit(quietReq("a")), id: "a")
        clock.advance(60)
        #expect(await !q.isQuiet)
        let r = await q.submit(quietReq("b"))
        #expect(r.status == .answered && r.intent == .allow)
        #expect(conv.asked == ["b"])
        // The missed list stays for the resume sentence until quiet mode is ended.
        #expect(await q.quietMode.missed.count == 1)
    }

    @Test func endQuietReturnsTheMissedListAndResumes() async {
        let conv = FakeConversation { _ in (0, {}, .button(.no)) }
        let q = RequestQueue(conversation: conv)
        await q.setQuiet(until: nil)
        _ = await q.submit(quietReq("a", project: "jarvis"))
        let ended = await q.endQuiet()
        #expect(ended.summaryText() == "Sen yokken 1 soru geldi: jarvis. Terminalde bekliyorlar.")
        #expect(await !q.isQuiet)
        #expect(await q.quietMode == QuietMode())
        let r = await q.submit(quietReq("b"))
        #expect(r.intent == .deny)
        #expect(conv.asked == ["b"])
    }

    @Test func notNowResultEntersQuietModeAndTheNextRequestIsNotAsked() async {
        let clock = TestClock()
        let conv = FakeConversation { _ in (0, {}, .notNow) }
        let q = RequestQueue(conversation: conv, now: clock.now)
        let events = EventBox()
        await q.setQuietObserver { events.add($0) }
        expectNoDecision(await q.submit(quietReq("a", kind: .stop, project: "x")), id: "a")
        let mode = await q.quietMode
        #expect(mode.isOn)
        #expect(mode.until == clock.now().addingTimeInterval(QuietMode.defaultSeconds))
        expectNoDecision(await q.submit(quietReq("b", kind: .choice, project: "y")), id: "b")
        #expect(conv.asked == ["a"])
        let missed = await q.quietMode.missed
        #expect(missed == [.init(project: "x", kind: .stop), .init(project: "y", kind: .choice)])
        #expect(events.events.count == 3)
        if case .on(let m) = events.events.first { #expect(m.missed.isEmpty) } else { Issue.record("expected .on first") }
        #expect(events.events.dropFirst().map { if case .missed(let m, _) = $0 { m.project } else { "?" } } == ["x", "y"])
        // Thirty minutes later the queue asks again.
        clock.advance(QuietMode.defaultSeconds)
        _ = await q.submit(quietReq("c"))
        #expect(conv.asked == ["a", "c"])
    }

    @Test func konusamamButtonEntersQuietModeAndNeverApprovesARiskyAction() async {
        let conv = FakeConversation { _ in (0, {}, .button(.notNow)) }
        let q = RequestQueue(conversation: conv)
        expectNoDecision(await q.submit(quietReq("r", risky: true)), id: "r")
        #expect(await q.isQuiet)
        #expect(await q.quietMode.missed == [.init(project: "p", kind: .permission)])
    }

    @Test func spokenSonraEntersQuietModeForEveryKind() async {
        for kind in [RequestKind.permission, .stop, .choice] {
            let conv = FakeConversation { _ in (0, {}, .heard(Heard(text: "sonra konuşalım", confidence: 0.95))) }
            let q = RequestQueue(conversation: conv)
            expectNoDecision(await q.submit(quietReq("a", kind: kind, asksQuestion: true)), id: "a")
            #expect(await q.isQuiet, "\(kind)")
        }
    }

    @Test func spokenSonraInsideAnAnswerIsNotQuietMode() async {
        let conv = FakeConversation { _ in (0, {}, .heard(Heard(text: "evet sonra", confidence: 0.95))) }
        let q = RequestQueue(conversation: conv)
        let r = await q.submit(quietReq("a", risky: true))
        #expect(r.status == .unclear)
        #expect(r.intent == Intent.none)
        #expect(await !q.isQuiet)
    }

    @Test func notNowOnAnOfficeAskSendsNothingAndIsNotCounted() async {
        let conv = FakeConversation { _ in (0, {}, .button(.notNow)) }
        let q = RequestQueue(conversation: conv)
        let r = await q.submit(officeAsk("ofis-1"))
        #expect(r.status == .expired)
        #expect(r.answers == nil)
        #expect(await q.isQuiet)
        #expect(await q.quietMode.missed.isEmpty)
    }

    @Test func notNowWhileAlreadyQuietKeepsTheEndTime() async {
        // Turned on from the menu ("until turned off") while the ask was on screen; the ask then ends as
        // not-now and must not shorten the manual quiet mode to 30 minutes.
        let gate = Gate()
        let conv = FakeConversation(holds: ["a": gate]) { _ in (0, {}, .notNow) }
        let q = RequestQueue(conversation: conv)
        async let first = q.submit(quietReq("a"))
        await conv.waitForAsk("a")
        await q.setQuiet(until: nil)
        gate.open()
        expectNoDecision(await first, id: "a")
        #expect(await q.quietMode.isOn)
        #expect(await q.quietMode.until == nil)
        #expect(await q.quietMode.missed.count == 1)
    }
}

// MARK: - Review fixes

@Suite struct QuietReviewFixTests {
    private func h(_ s: String) -> Heard { Heard(text: s, confidence: 0.9) }

    private func sonraKarar() -> OfisKarar {
        OfisKarar(note: "n2.md", baslik: "Zamanlama", proje: "blog", tur: "ceo-sorusu", soru: "Ne zaman?",
                  secenekler: [OfisSecenek(kod: "A", metin: "Şimdi"), OfisSecenek(kod: "B", metin: "Sonra")],
                  risk: "normal", riskNedeni: "", ekranOnayiGerekir: false, soruldu: "2026-11-14T10:00",
                  cevapIletildi: false)
    }

    // I1: not-now wins even over an option labelled "Sonra"; the number or code still picks it.
    @Test func sonraNeverPicksAnOptionLabelledSonra() {
        for s in ["sonra", "Sonra.", "şey, sonra", "sonra konuşalım", "konuşamam"] {
            #expect(IntentParser.choice(h(s), options: ["Şimdi", "Sonra"]) == nil, "\(s)")
            #expect(IntentParser.officeChoice(h(s), codes: ["A", "B"], texts: ["Şimdi", "Sonra"]) == nil, "\(s)")
        }
        #expect(IntentParser.choice(h("ikinci"), options: ["Şimdi", "Sonra"]) == 1)
        #expect(IntentParser.officeChoice(h("B"), codes: ["A", "B"], texts: ["Şimdi", "Sonra"]) == 1)
        #expect(IntentParser.officeChoice(h("şimdi"), codes: ["A", "B"], texts: ["Şimdi", "Sonra"]) == 0)
    }

    @Test func officeSpokenPickIgnoresSonra() throws {
        let ask = try #require(OfisCards.ask(for: sonraKarar()))
        #expect(ask.spokenPick(h("sonra")) == nil)
        #expect(ask.spokenPick(h("B")) == 1)
    }

    @Test func officeAskAnsweredBySpokenSonraWaitsForQuietMode() async throws {
        let ask = try #require(OfisCards.ask(for: sonraKarar()))
        // As the app does: a spoken pick answers; anything else goes to the queue as heard.
        let conv = FakeConversation { _ in
            let heard = Heard(text: "sonra", confidence: 0.95)
            return (0, {}, ask.spokenPick(heard).map { .choices([$0]) } ?? .heard(heard))
        }
        let q = RequestQueue(conversation: conv)
        let r = await q.submit(OfisCards.request(for: ask, id: "ofis-2"))
        #expect(r.status == .expired)
        #expect(r.answers == nil)
        #expect(await q.isQuiet)
        #expect(await q.quietMode.missed.isEmpty)
    }

    // M1: a hook request answered while quiet does not cut off the app's own silent display.
    @Test func quietHookRequestDoesNotInterruptTheAppDisplay() async {
        let gate = Gate()
        let conv = FakeConversation(holds: ["info": gate]) { _ in (0, {}, .button(.ok)) }
        let q = RequestQueue(conversation: conv)
        await q.setQuiet(until: nil)
        let infoResponse = await q.submit(quietReq("info", kind: .stop, info: true), showWhenMuted: true)
        #expect(infoResponse.status == .answered)
        await conv.waitForAsk("info")
        async let hook = q.submit(quietReq("perm"))
        await q.waitUntilSubmitted(2)
        #expect(conv.interruptCalls == 0)
        gate.open()
        expectNoDecision(await hook, id: "perm")
        #expect(conv.interrupted.isEmpty)
        #expect(conv.asked == ["info"])
    }

    // M2 (reversed by controller ruling): turning quiet mode on again after an expired period, before
    // `endQuiet`, keeps the missed list; losing a resume sentence is worse than merging two periods.
    @Test func turningOnAfterAnExpiredPeriodKeepsTheMissedList() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var q = QuietMode()
        q.turnOn(until: t0.addingTimeInterval(60))
        q.record(.init(project: "a", kind: .stop))
        // Expired, not yet ended: the next period merges with it.
        #expect(!q.isActive(now: t0.addingTimeInterval(500)))
        q.turnOn(until: nil)
        q.record(.init(project: "b", kind: .permission))
        #expect(q.missed == [.init(project: "a", kind: .stop), .init(project: "b", kind: .permission)])
        #expect(q.isActive(now: t0.addingTimeInterval(500)))
        #expect(q.summaryText() == "Sen yokken 2 soru geldi: a ve b. Terminalde bekliyorlar.")
    }

    @Test func queueQuietAfterAnExpiredPeriodKeepsTheMissedList() async {
        let clock = TestClock()
        let q = RequestQueue(conversation: FakeConversation { _ in (0, {}, .button(.yes)) }, now: clock.now)
        await q.setQuiet(until: clock.now().addingTimeInterval(60))
        _ = await q.submit(quietReq("a", project: "x"))
        clock.advance(120)
        await q.setQuiet(until: nil)
        _ = await q.submit(quietReq("b", project: "y"))
        #expect(await q.quietMode.missed == [.init(project: "x", kind: .permission),
                                             .init(project: "y", kind: .permission)])
        // Ending quiet mode clears it; the next period starts empty.
        #expect(await q.endQuiet().missed.count == 2)
        await q.setQuiet(until: nil)
        #expect(await q.quietMode.missed.isEmpty)
    }

    // M3: the same deps print a decision for an allow response, so the empty outputs above are meaningful.
    @Test func hookPrintsADecisionForAnAllowThroughTheSameDeps() {
        let allow = JarvisResponse(id: "req-1", status: .answered, transcript: "Evet (düğme)", intent: .allow)
        let deps = HookDeps(send: { _ in allow }, isInteractive: { true }, excludedPrefixes: [], ofisFileContents: [],
                            env: [:], home: "/Users/test", log: { _ in }, newId: { "req-1" })
        let perm = Data("{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}".utf8)
        #expect(HookRunner.run(event: .permission, stdin: perm, deps: deps) != "")
    }

    // M4: a plain stop answered "sonra konuşalım" is quiet mode, never a spoken instruction.
    @Test func plainStopSpokenSonraKonusalimIsQuietNotAnInstruction() async {
        let conv = FakeConversation { _ in (0, {}, .heard(Heard(text: "sonra konuşalım", confidence: 0.95))) }
        let q = RequestQueue(conversation: conv)
        let r = await q.submit(quietReq("a", kind: .stop, asksQuestion: false))
        expectNoDecision(r, id: "a")
        #expect(await q.isQuiet)
        let deps = HookDeps(send: { _ in r }, isInteractive: { true }, excludedPrefixes: [], ofisFileContents: [],
                            env: [:], home: "/Users/test", log: { _ in }, newId: { "a" })
        let out = HookRunner.run(event: .stop, stdin: Data("{\"session_id\":\"s1\",\"cwd\":\"/tmp/proj\"}".utf8), deps: deps)
        #expect(!out.contains("[Sesli talimat]"))
        #expect(out == "")
    }

    // M5: quiet turned on while an ask is on screen does not void an answer he then gives.
    @Test func answerGivenAfterTimedQuietStartsMidAskIsApplied() async {
        let gate = Gate()
        let clock = TestClock()
        let conv = FakeConversation(holds: ["a": gate]) { _ in (0, {}, .button(.yes)) }
        let q = RequestQueue(conversation: conv, now: clock.now)
        async let first = q.submit(quietReq("a"))
        await conv.waitForAsk("a")
        await q.setQuiet(until: clock.now().addingTimeInterval(60))
        gate.open()
        let r = await first
        #expect(r.status == .answered)
        #expect(r.intent == .allow)
        #expect(await q.quietMode.missed.isEmpty)
        #expect(await q.isQuiet)
    }
}

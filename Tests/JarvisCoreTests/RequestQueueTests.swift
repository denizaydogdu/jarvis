import Foundation
import Testing
@testable import JarvisCore

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: Double) { lock.lock(); t = t.addingTimeInterval(s); lock.unlock() }
}

/// A one-shot signal: `wait` returns once `open` has been called (at once if it already was).
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if opened { return true }
                waiters.append(c)
                return false
            }
            if go { c.resume() }
        }
    }

    func open() {
        let ws = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters.removeAll() }
            return waiters
        }
        for w in ws { w.resume() }
    }
}

final class FakeConversation: Conversation, @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var inFlight = 0
    private var maxInFlight = 0
    private var silents: [Bool] = []
    private var budgetList: [Double] = []
    /// Id and sequence of the ask in flight when it is an info stop; `interruptInfo` ends only that one,
    /// and only when the sequence matches.
    private var activeInfo: (id: String, sequence: Int)?
    private var interruptedInfo: Set<String> = []
    private var interruptCallCount = 0
    private var interruptSequenceList: [Int] = []
    private var askSequenceList: [Int] = []
    /// Ids whose ask has started, and the tests waiting for one (explicit signals, no sleeps).
    private var startedIds: Set<String> = []
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let script: @Sendable (JarvisRequest) -> (delayMs: UInt64, onAsk: @Sendable () -> Void, result: ConversationResult)
    /// Asks held open (after they started, before their delay) until the request's gate opens.
    private let holds: [String: Gate]

    init(holds: [String: Gate] = [:],
         script: @escaping @Sendable (JarvisRequest) -> (delayMs: UInt64, onAsk: @Sendable () -> Void, result: ConversationResult)) {
        self.holds = holds
        self.script = script
    }

    var asked: [String] { lock.lock(); defer { lock.unlock() }; return order }
    var silentFlags: [Bool] { lock.lock(); defer { lock.unlock() }; return silents }
    var budgets: [Double] { lock.lock(); defer { lock.unlock() }; return budgetList }
    var maxConcurrency: Int { lock.lock(); defer { lock.unlock() }; return maxInFlight }
    var interrupted: Set<String> { lock.lock(); defer { lock.unlock() }; return interruptedInfo }
    var interruptCalls: Int { lock.lock(); defer { lock.unlock() }; return interruptCallCount }
    var interruptSequences: [Int] { lock.lock(); defer { lock.unlock() }; return interruptSequenceList }
    var askSequences: [Int] { lock.lock(); defer { lock.unlock() }; return askSequenceList }

    func interruptInfo(sequence: Int) async {
        lock.withLock {
            interruptCallCount += 1
            interruptSequenceList.append(sequence)
            if let info = activeInfo, info.sequence == sequence { interruptedInfo.insert(info.id) }
        }
    }

    private func enter(_ id: String) {
        lock.withLock {
            order.append(id)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
    }

    private func leave() { lock.withLock { inFlight -= 1 } }

    /// Returns once the ask for `id` has started (at once if it already has).
    func waitForAsk(_ id: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let started = lock.withLock { () -> Bool in
                if startedIds.contains(id) { return true }
                startWaiters[id, default: []].append(c)
                return false
            }
            if started { c.resume() }
        }
    }

    private func signalStarted(_ id: String) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            startedIds.insert(id)
            return startWaiters.removeValue(forKey: id) ?? []
        }
        for w in waiters { w.resume() }
    }

    func ask(_ r: JarvisRequest, silent: Bool, budget: Double, sequence: Int) async -> ConversationResult {
        lock.withLock { silents.append(silent); budgetList.append(budget); askSequenceList.append(sequence) }
        enter(r.id)
        if r.isInfoStop { lock.withLock { activeInfo = (r.id, sequence) } }
        signalStarted(r.id)
        if let gate = holds[r.id] { await gate.wait() }
        let s = script(r)
        // Sleeps in small steps so an interrupted info display ends at once, as the app's does.
        var left = s.delayMs
        while left > 0, !lock.withLock({ interruptedInfo.contains(r.id) }) {
            let step = min(left, 5)
            try? await Task.sleep(nanoseconds: step * 1_000_000)
            left -= step
        }
        lock.withLock { if activeInfo?.id == r.id { activeInfo = nil } }
        s.onAsk() // runs at the end of the ask, after later requests were submitted
        leave()
        return s.result
    }
}

private func req(_ id: String, kind: RequestKind = .permission, risky: Bool = false, deadline: Int = 120,
                 asksQuestion: Bool = false, info: Bool = false) -> JarvisRequest {
    JarvisRequest(id: id, sessionId: "s", project: "p", kind: kind, speech: "x", detail: "d", risky: risky,
                  deadlineS: deadline, asksQuestion: asksQuestion, info: info)
}

@Suite struct RequestQueueTests {
    @Test func fifoOrderWithConcurrentSubmits() async {
        let conv = FakeConversation { r in
            (r.id == "A" ? 200 : 10, {}, .heard(Heard(text: "evet", confidence: 0.9)))
        }
        let q = RequestQueue(conversation: conv)
        async let a = q.submit(req("A"))
        await q.waitUntilSubmitted(1)
        async let b = q.submit(req("B"))
        await q.waitUntilSubmitted(2)
        async let c = q.submit(req("C"))
        let rs = await [a, b, c]
        #expect(conv.asked == ["A", "B", "C"])
        #expect(conv.maxConcurrency == 1)
        #expect(rs.map(\.id) == ["A", "B", "C"])
        #expect(rs.allSatisfy { $0.status == .answered && $0.intent == .allow })
    }

    @Test func mutedAsksSilently() async {
        let conv = FakeConversation { _ in (0, {}, .button(.no)) }
        let q = RequestQueue(conversation: conv)
        await q.setMuted(true)
        #expect(await q.isMuted)
        let r = await q.submit(req("A"))
        #expect(conv.asked == ["A"])
        #expect(conv.silentFlags == [true])
        #expect(r.status == .answered)
    }

    @Test func unmutedAsksAloud() async {
        let conv = FakeConversation { _ in (0, {}, .handoff) }
        let q = RequestQueue(conversation: conv)
        _ = await q.submit(req("A"))
        #expect(conv.silentFlags == [false])
    }

    @Test func mutingWhileWaitingMakesQueuedAskSilently() async {
        let conv = FakeConversation { r in (r.id == "A" ? 150 : 0, {}, .heard(Heard(text: "evet", confidence: 0.9))) }
        let queue = RequestQueue(conversation: conv)
        async let a = queue.submit(req("A"))
        await conv.waitForAsk("A")
        async let b = queue.submit(req("B"))
        await queue.waitUntilSubmitted(2)
        await queue.setMuted(true)
        let (ra, rb) = await (a, b)
        #expect(ra.status == .answered)
        #expect(rb.status == .answered)
        #expect(conv.asked == ["A", "B"])
        #expect(conv.silentFlags == [false, true])
    }

    @Test func buttonYesAllows() async {
        let conv = FakeConversation { _ in (0, {}, .button(.yes)) }
        let r = await RequestQueue(conversation: conv).submit(req("A"))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: "Evet (düğme)", intent: .allow))
    }

    @Test func buttonConfirmAllowsRisky() async {
        let conv = FakeConversation { _ in (0, {}, .button(.confirm)) }
        let r = await RequestQueue(conversation: conv).submit(req("A", risky: true))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: "Evet (düğme)", intent: .allow))
    }

    @Test func buttonYesOnRiskyIsUnclear() async {
        let conv = FakeConversation { _ in (0, {}, .button(.yes)) }
        let r = await RequestQueue(conversation: conv).submit(req("A", risky: true))
        #expect(r == JarvisResponse(id: "A", status: .unclear, transcript: nil, intent: Intent.none))
    }

    @Test func buttonNoDeniesWithTranscript() async {
        let conv = FakeConversation { _ in (0, {}, .button(.no)) }
        let r = await RequestQueue(conversation: conv).submit(req("A"))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: "Hayır (düğme)", intent: .deny))
    }

    @Test func buttonTerminalHandsOff() async {
        let conv = FakeConversation { _ in (0, {}, .button(.terminal)) }
        let r = await RequestQueue(conversation: conv).submit(req("A"))
        #expect(r == JarvisResponse(id: "A", status: .handoff, transcript: nil, intent: Intent.none))
    }

    @Test func buttonDoneOnStopIsNone() async {
        let conv = FakeConversation { _ in (0, {}, .button(.done)) }
        let r = await RequestQueue(conversation: conv).submit(req("A", kind: .stop))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: nil, intent: Intent.none))
    }

    @Test func buttonNotOfferedIsUnclear() async {
        let doneOnPermission = FakeConversation { _ in (0, {}, .button(.done)) }
        let r1 = await RequestQueue(conversation: doneOnPermission).submit(req("A"))
        #expect(r1.status == .unclear)
        #expect(r1.intent == Intent.none)
        let yesOnStop = FakeConversation { _ in (0, {}, .button(.yes)) }
        let r2 = await RequestQueue(conversation: yesOnStop).submit(req("B", kind: .stop))
        #expect(r2.status == .unclear)
        #expect(r2.intent == Intent.none)
    }

    @Test func stopQuestionYesProceedsWithEvet() async {
        let conv = FakeConversation { _ in (0, {}, .button(.yes)) }
        let r = await RequestQueue(conversation: conv).submit(req("A", kind: .stop, asksQuestion: true))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: "Evet", intent: .proceed))
    }

    @Test func stopQuestionNoProceedsWithHayir() async {
        let conv = FakeConversation { _ in (0, {}, .button(.no)) }
        let r = await RequestQueue(conversation: conv).submit(req("A", kind: .stop, asksQuestion: true))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: "Hayır", intent: .proceed))
    }

    @Test func stopQuestionDoneButtonNotOffered() async {
        let conv = FakeConversation { _ in (0, {}, .button(.done)) }
        let r = await RequestQueue(conversation: conv).submit(req("A", kind: .stop, asksQuestion: true))
        #expect(r == JarvisResponse(id: "A", status: .unclear, transcript: nil, intent: Intent.none))
    }

    @Test func voiceSingleEvetOnQuestionProceeds() async {
        let conv = FakeConversation { _ in (0, {}, .heard(Heard(text: "Evet", confidence: 0.4))) }
        let r = await RequestQueue(conversation: conv).submit(req("A", kind: .stop, asksQuestion: true))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: "Evet", intent: .proceed))
    }

    @Test func voiceSingleEvetWithoutQuestionIsUnclear() async {
        let conv = FakeConversation { _ in (0, {}, .heard(Heard(text: "Evet", confidence: 0.9))) }
        let r = await RequestQueue(conversation: conv).submit(req("A", kind: .stop))
        #expect(r == JarvisResponse(id: "A", status: .unclear, transcript: nil, intent: Intent.none))
    }

    @Test func expiredWhenWaitedTooLong() async {
        let clock = TestClock()
        let conv = FakeConversation { r in
            (r.id == "A" ? 150 : 0, { if r.id == "A" { clock.advance(15) } }, .heard(Heard(text: "evet", confidence: 0.9)))
        }
        let q = RequestQueue(conversation: conv, now: { clock.now() }, minAskSeconds: 30)
        async let a = q.submit(req("A", deadline: 40))
        await conv.waitForAsk("A")
        async let b = q.submit(req("B", deadline: 40))
        let (ra, rb) = await (a, b)
        #expect(ra.status == .answered)
        #expect(rb == JarvisResponse(id: "B", status: .expired, transcript: nil, intent: Intent.none))
        #expect(conv.asked == ["A"])
    }

    @Test func handoffMapsToHandoff() async {
        let conv = FakeConversation { _ in (0, {}, .handoff) }
        let q = RequestQueue(conversation: conv)
        let r = await q.submit(req("A"))
        #expect(r == JarvisResponse(id: "A", status: .handoff, transcript: nil, intent: Intent.none))
    }

    @Test func riskyPlainYesIsUnclear() async {
        let conv = FakeConversation { _ in (0, {}, .heard(Heard(text: "evet", confidence: 0.9))) }
        let q = RequestQueue(conversation: conv)
        let r = await q.submit(req("A", risky: true))
        #expect(r.status == .unclear)
        #expect(r.intent == Intent.none)
        #expect(r.transcript == nil)
    }

    @Test func stopTwoWordsHighConfidenceProceeds() async {
        let conv = FakeConversation { _ in (0, {}, .heard(Heard(text: "testleri çalıştır", confidence: 0.9))) }
        let q = RequestQueue(conversation: conv)
        let r = await q.submit(req("A", kind: .stop))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: "testleri çalıştır", intent: .proceed))
    }

    // I2: the ask may not outlive the hook's deadline.
    @Test func budgetIsDeadlineMinusWaitedMinusMargin() async {
        let clock = TestClock()
        let conv = FakeConversation { r in
            (r.id == "A" ? 150 : 0, { if r.id == "A" { clock.advance(20) } }, .handoff)
        }
        let q = RequestQueue(conversation: conv, now: { clock.now() }, minAskSeconds: 30)
        async let a = q.submit(req("A", deadline: 150))
        await conv.waitForAsk("A")
        async let b = q.submit(req("B", deadline: 150))
        _ = await (a, b)
        #expect(conv.budgets == [147, 127])
    }

    // I7: muted, a stop without a question ends at once with nothing to do and is never shown.
    @Test func mutedPlainStopReturnsAtOnceWithoutAsking() async {
        let conv = FakeConversation { _ in (0, {}, .button(.done)) }
        let q = RequestQueue(conversation: conv)
        await q.setMuted(true)
        let r = await q.submit(req("A", kind: .stop))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: nil, intent: Intent.none))
        #expect(conv.asked.isEmpty)
    }

    @Test func mutedQuestionStopAndPermissionStillAskSilently() async {
        let conv = FakeConversation { _ in (0, {}, .button(.terminal)) }
        let q = RequestQueue(conversation: conv)
        await q.setMuted(true)
        _ = await q.submit(req("A", kind: .stop, asksQuestion: true))
        _ = await q.submit(req("B"))
        #expect(conv.asked == ["A", "B"])
        #expect(conv.silentFlags == [true, true])
    }

    // T: the risky-only confirm button never allows a non-risky request.
    @Test func buttonConfirmOnNonRiskyIsUnclear() async {
        let conv = FakeConversation { _ in (0, {}, .button(.confirm)) }
        let r = await RequestQueue(conversation: conv).submit(req("A", risky: false))
        #expect(r == JarvisResponse(id: "A", status: .unclear, transcript: nil, intent: Intent.none))
    }

    // v1.2 info mode: nobody is asked anything, so nothing ever becomes an instruction.
    @Test func infoOkMapsToAnsweredNone() async {
        let none = JarvisResponse(id: "A", status: .answered, transcript: nil, intent: Intent.none)
        let ok = FakeConversation { _ in (0, {}, .button(.ok)) }
        #expect(await RequestQueue(conversation: ok).submit(req("A", kind: .stop, info: true)) == none)
        // Auto-close (silence), stray speech, a handoff or a button not offered: still answered/none.
        for result in [ConversationResult.heard(Heard(text: "", confidence: 0)),
                       .heard(Heard(text: "testleri çalıştır", confidence: 0.9)),
                       .handoff, .button(.yes), .button(.done)] {
            let conv = FakeConversation { _ in (0, {}, result) }
            #expect(await RequestQueue(conversation: conv).submit(req("A", kind: .stop, info: true)) == none)
        }
        // `.ok` is offered only for info stops.
        let okElsewhere = FakeConversation { _ in (0, {}, .button(.ok)) }
        #expect(await RequestQueue(conversation: okElsewhere).submit(req("B", kind: .stop)).status == .unclear)
    }

    @Test func infoIgnoredWhenTheStopAsksAQuestion() async {
        let conv = FakeConversation { _ in (0, {}, .button(.yes)) }
        let r = await RequestQueue(conversation: conv).submit(req("A", kind: .stop, asksQuestion: true, info: true))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: "Evet", intent: .proceed))
    }

    @Test func mutedInfoReturnsImmediately() async {
        let conv = FakeConversation { _ in (0, {}, .button(.ok)) }
        let q = RequestQueue(conversation: conv)
        await q.setMuted(true)
        let r = await q.submit(req("A", kind: .stop, info: true))
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: nil, intent: Intent.none))
        #expect(conv.asked.isEmpty)
    }

    /// R4 (v1.5): the menu's office status is shown even when muted — silently; only the caller that asks
    /// for it gets the exemption, a hook's info stop never does.
    @Test func mutedInfoShownSilentlyOnlyWhenTheCallerAsks() async {
        let conv = FakeConversation { _ in (0, {}, .button(.ok)) }
        let q = RequestQueue(conversation: conv)
        await q.setMuted(true)
        let r = await q.submit(req("S", kind: .stop, info: true), showWhenMuted: true)
        #expect(r == JarvisResponse(id: "S", status: .answered, transcript: nil, intent: Intent.none))
        await q.drain()
        #expect(conv.asked == ["S"])
        #expect(conv.silentFlags == [true])
        _ = await q.submit(req("H", kind: .stop, info: true))
        await q.drain()
        #expect(conv.asked == ["S"])
    }

    // Task 5: an info stop replies at once; its display follows asynchronously through the same FIFO.
    @Test func infoStopRepliesImmediately() async {
        let conv = FakeConversation { _ in (400, {}, .button(.ok)) }
        let q = RequestQueue(conversation: conv)
        let started = Date()
        let r = await q.submit(req("A", kind: .stop, info: true))
        let took = Date().timeIntervalSince(started)
        #expect(r == JarvisResponse(id: "A", status: .answered, transcript: nil, intent: Intent.none))
        #expect(took < 0.2)
        await q.drain()
        #expect(conv.asked == ["A"])
    }

    @Test func infoDisplayWaitsItsTurnAndNeverOverlaps() async {
        let conv = FakeConversation { r in (r.id == "A" ? 150 : 50, {}, r.id == "B" ? .button(.ok) : .button(.yes)) }
        let q = RequestQueue(conversation: conv)
        async let a = q.submit(req("A"))
        await conv.waitForAsk("A")
        let rb = await q.submit(req("B", kind: .stop, info: true))
        #expect(rb.status == .answered)
        #expect(conv.asked == ["A"]) // B's display waits while A is still on the panel
        let rc = await q.submit(req("C"))
        let ra = await a
        #expect(ra.intent == .allow)
        #expect(rc.intent == .allow)
        // v1.3: C is a newer real request, so B's waiting display is dropped at the head.
        #expect(conv.asked == ["A", "C"])
        #expect(conv.maxConcurrency == 1)
    }

    @Test func staleInfoDisplayIsDropped() async {
        let clock = TestClock()
        let conv = FakeConversation { r in
            (r.id == "A" ? 150 : 0, { if r.id == "A" { clock.advance(61) } }, .button(.yes))
        }
        let q = RequestQueue(conversation: conv, now: { clock.now() })
        async let a = q.submit(req("A", deadline: 150))
        await conv.waitForAsk("A")
        let rb = await q.submit(req("B", kind: .stop, info: true))
        #expect(rb == JarvisResponse(id: "B", status: .answered, transcript: nil, intent: Intent.none))
        _ = await a
        await q.drain()
        #expect(conv.asked == ["A"])
    }

    @Test func freshInfoDisplayAfterWaitIsShown() async {
        let clock = TestClock()
        let conv = FakeConversation { r in
            (r.id == "A" ? 150 : 0, { if r.id == "A" { clock.advance(59) } }, .button(.yes))
        }
        let q = RequestQueue(conversation: conv, now: { clock.now() })
        async let a = q.submit(req("A", deadline: 150))
        await conv.waitForAsk("A")
        _ = await q.submit(req("B", kind: .stop, info: true))
        _ = await a
        await q.drain()
        #expect(conv.asked == ["A", "B"])
    }

    // Focused session: nothing was shown; a permission goes to the terminal, a stop ends with nothing to do.
    @Test func skippedMapsByKind() async {
        let conv = FakeConversation { _ in (0, {}, .skipped) }
        let q = RequestQueue(conversation: conv)
        #expect(await q.submit(req("A")) == JarvisResponse(id: "A", status: .handoff, transcript: nil, intent: Intent.none))
        #expect(await q.submit(req("B", risky: true)) == JarvisResponse(id: "B", status: .handoff, transcript: nil, intent: Intent.none))
        #expect(await q.submit(req("C", kind: .stop)) == JarvisResponse(id: "C", status: .answered, transcript: nil, intent: Intent.none))
        #expect(await q.submit(req("D", kind: .stop, asksQuestion: true)) == JarvisResponse(id: "D", status: .answered, transcript: nil, intent: Intent.none))
    }

    // v1.3: a real question preempts info. An active info display ends at once.
    @Test func nonInfoInterruptsActiveInfo() async {
        let conv = FakeConversation { r in (r.id == "I" ? 3000 : 0, {}, r.id == "I" ? .button(.ok) : .button(.yes)) }
        let q = RequestQueue(conversation: conv)
        _ = await q.submit(req("I", kind: .stop, info: true))
        await conv.waitForAsk("I")
        #expect(conv.asked == ["I"]) // the info display is on the panel
        let started = Date()
        let rp = await q.submit(req("P"))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(rp.intent == .allow)
        #expect(conv.interrupted == ["I"])
        #expect(conv.asked == ["I", "P"])
        #expect(conv.maxConcurrency == 1)
    }

    // v1.4: the interrupt names the info display it is meant for, by the sequence its ask was given.
    @Test func interruptInfoCarriesTheInfoSequence() async {
        let conv = FakeConversation { r in (r.id == "I" ? 3000 : 0, {}, r.isInfoStop ? .button(.ok) : .button(.yes)) }
        let q = RequestQueue(conversation: conv)
        #expect(await q.submit(req("A")).intent == .allow) // sequence 0
        _ = await q.submit(req("I", kind: .stop, info: true)) // sequence 1
        await conv.waitForAsk("I")
        #expect(await q.submit(req("P")).intent == .allow) // sequence 2
        #expect(conv.askSequences == [0, 1, 2])
        #expect(conv.interruptSequences == [1])
        #expect(conv.interrupted == ["I"])
    }

    @Test func nonInfoNeverInterruptsANonInfoAsk() async {
        let conv = FakeConversation { r in (r.id == "A" ? 150 : 0, {}, .button(.yes)) }
        let q = RequestQueue(conversation: conv)
        async let a = q.submit(req("A"))
        await conv.waitForAsk("A")
        let rb = await q.submit(req("B"))
        let ra = await a
        #expect(ra.intent == .allow)
        #expect(rb.intent == .allow)
        #expect(conv.interruptCalls == 0)
        #expect(conv.interrupted.isEmpty)
    }

    @Test func waitingInfoDroppedWhenRealQuestionArrives() async {
        let conv = FakeConversation { r in (r.id == "A" ? 150 : 0, {}, r.isInfoStop ? .button(.ok) : .button(.yes)) }
        let q = RequestQueue(conversation: conv)
        async let a = q.submit(req("A"))
        await conv.waitForAsk("A")
        let r1 = await q.submit(req("I1", kind: .stop, info: true)) // waits behind A
        #expect(r1 == JarvisResponse(id: "I1", status: .answered, transcript: nil, intent: Intent.none))
        async let b = q.submit(req("B", kind: .stop, asksQuestion: true)) // a newer real question
        await q.waitUntilSubmitted(3)
        _ = await q.submit(req("I2", kind: .stop, info: true)) // newer than B: still shown
        _ = await (a, b)
        await q.drain()
        #expect(conv.asked == ["A", "B", "I2"])
        // A was a real ask, never an info display: nothing was interrupted.
        #expect(conv.interrupted.isEmpty)
    }

    @Test func infoStillRepliesImmediately() async {
        let conv = FakeConversation { r in (r.id == "A" ? 300 : 0, {}, r.isInfoStop ? .button(.ok) : .button(.yes)) }
        let q = RequestQueue(conversation: conv)
        async let a = q.submit(req("A"))
        await conv.waitForAsk("A")
        for id in ["I1", "I2"] {
            let started = Date()
            let r = await q.submit(req(id, kind: .stop, info: true))
            #expect(Date().timeIntervalSince(started) < 0.2)
            #expect(r == JarvisResponse(id: id, status: .answered, transcript: nil, intent: Intent.none))
        }
        _ = await a
        await q.drain()
        #expect(conv.asked == ["A", "I1", "I2"]) // no real question after them: both shown in turn
    }

    // MARK: - v1.3 multiple-choice questions

    private func choiceReq(_ id: String) -> JarvisRequest {
        func q(_ text: String, _ labels: [String]) -> ChoiceQuestion {
            ChoiceQuestion(question: text, header: "", options: labels.map { ChoiceOption(label: $0, description: "") })
        }
        return JarvisRequest(id: id, sessionId: "s", project: "p", kind: .choice, speech: "x", detail: "",
                             risky: false, deadlineS: 150, choices: [q("A?", ["x", "y"]), q("B?", ["1", "2", "3"])])
    }

    private func choiceResult(_ result: ConversationResult, muted: Bool = false) async -> (JarvisResponse, FakeConversation) {
        let conv = FakeConversation { _ in (0, {}, result) }
        let q = RequestQueue(conversation: conv)
        await q.setMuted(muted)
        return (await q.submit(choiceReq("C")), conv)
    }

    @Test func choicesAnswerWithTheirLabelsInOrder() async {
        let (r, conv) = await choiceResult(.choices([1, 2]))
        #expect(r == JarvisResponse(id: "C", status: .answered, transcript: nil, intent: Intent.none, answers: ["y", "3"]))
        #expect(conv.silentFlags == [false])
    }

    @Test func choicesNotMatchingTheQuestionsAreUnclear() async {
        for picks in [[1], [1, 2, 0], [2, 0], [0, 3], [-1, 0], []] {
            let (r, _) = await choiceResult(.choices(picks))
            #expect(r == JarvisResponse(id: "C", status: .unclear, transcript: nil, intent: Intent.none), "\(picks)")
        }
    }

    @Test func choiceNonAnswersEndWithoutAnswers() async {
        let cases: [(ConversationResult, ResponseStatus)] = [
            (.heard(Heard(text: "", confidence: 0)), .timeout),
            (.heard(Heard(text: "terminal", confidence: 0.9)), .handoff),
            (.heard(Heard(text: "bilmiyorum", confidence: 0.9)), .unclear),
            // A voice pick still comes back as `.choices`; a bare heard text never answers.
            (.heard(Heard(text: "ikinci", confidence: 0.9)), .unclear),
            (.button(.terminal), .handoff),
            (.handoff, .handoff),
            // The focused session's own dialog takes the question.
            (.skipped, .handoff),
            // Option buttons answer only through `.choices`; other buttons are not offered.
            (.button(.option(0)), .unclear),
            (.button(.yes), .unclear),
            (.button(.ok), .unclear),
        ]
        for (result, status) in cases {
            let (r, _) = await choiceResult(result)
            #expect(r == JarvisResponse(id: "C", status: status, transcript: nil, intent: Intent.none), "\(result)")
        }
    }

    @Test func choicesOnlyAnswerAChoice() async {
        let conv = FakeConversation { _ in (0, {}, .choices([0])) }
        let q = RequestQueue(conversation: conv)
        #expect(await q.submit(req("P")).status == .unclear)
        #expect(await q.submit(req("S", kind: .stop, asksQuestion: true)).status == .unclear)
    }

    @Test func mutedChoiceStillAsksSilently() async {
        let (r, conv) = await choiceResult(.choices([0, 0]), muted: true)
        #expect(conv.asked == ["C"])
        #expect(conv.silentFlags == [true])
        #expect(r.answers == ["x", "1"])
    }

    @Test func choiceInterruptsActiveInfo() async {
        let conv = FakeConversation { r in (r.id == "I" ? 3000 : 0, {}, r.isInfoStop ? .button(.ok) : .choices([0, 0])) }
        let q = RequestQueue(conversation: conv)
        _ = await q.submit(req("I", kind: .stop, info: true))
        await conv.waitForAsk("I")
        let started = Date()
        let rc = await q.submit(choiceReq("C"))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(rc.answers == ["x", "1"])
        #expect(conv.interrupted == ["I"])
    }
    // MARK: - v1.4: pinned behaviour

    @Test func expiryBoundaryIsAsked() async {
        // Exactly `minAskSeconds` left: still asked. Below it: expired.
        // A's ask stays open until B and C are both in the queue, so both wait the 10 s A advances by.
        let clock = TestClock()
        let holdA = Gate()
        let conv = FakeConversation(holds: ["A": holdA]) { r in
            (0, { if r.id == "A" { clock.advance(10) } }, .button(.yes))
        }
        let q = RequestQueue(conversation: conv, now: { clock.now() }, minAskSeconds: 30)
        #expect(await q.submit(req("Z", deadline: 30)).status == .answered) // waited 0, 30 left
        async let a = q.submit(req("A", deadline: 150))
        await conv.waitForAsk("A")
        async let b = q.submit(req("B", deadline: 40)) // waits 10, 30 left
        await q.waitUntilSubmitted(3)
        async let c = q.submit(req("C", deadline: 39)) // waits 10, 29 left
        await q.waitUntilSubmitted(4)
        holdA.open()
        let (ra, rb, rc) = await (a, b, c)
        #expect(ra.status == .answered)
        #expect(rb == JarvisResponse(id: "B", status: .answered, transcript: "Evet (düğme)", intent: .allow))
        #expect(rc == JarvisResponse(id: "C", status: .expired, transcript: nil, intent: Intent.none))
        #expect(conv.asked == ["Z", "A", "B"])
    }

    @Test func mutedAndExpiredIsExpired() async {
        // Expiry is decided before the muted shortcuts: a stale request is never asked, muted or not.
        // A's ask stays open until B and C are both in the queue, so both wait the 15 s A advances by.
        let clock = TestClock()
        let holdA = Gate()
        let conv = FakeConversation(holds: ["A": holdA]) { r in
            (0, { if r.id == "A" { clock.advance(15) } }, .button(.yes))
        }
        let q = RequestQueue(conversation: conv, now: { clock.now() }, minAskSeconds: 30)
        await q.setMuted(true)
        async let a = q.submit(req("A", deadline: 150))
        await conv.waitForAsk("A")
        async let b = q.submit(req("B", deadline: 40))
        await q.waitUntilSubmitted(2)
        async let c = q.submit(req("C", kind: .stop, deadline: 40))
        await q.waitUntilSubmitted(3)
        holdA.open()
        let (ra, rb, rc) = await (a, b, c)
        #expect(ra.status == .answered)
        #expect(rb == JarvisResponse(id: "B", status: .expired, transcript: nil, intent: Intent.none))
        #expect(rc == JarvisResponse(id: "C", status: .expired, transcript: nil, intent: Intent.none))
        #expect(conv.asked == ["A"])
        #expect(conv.silentFlags == [true])
    }

    @Test func submitSignalCountsSubmissions() async {
        let conv = FakeConversation { _ in (0, {}, .button(.yes)) }
        let q = RequestQueue(conversation: conv)
        _ = await q.submit(req("A"))
        await q.waitUntilSubmitted(1) // already reached: returns at once
        async let b = q.submit(req("B"))
        await q.waitUntilSubmitted(2)
        #expect(await b.intent == .allow)
    }
}

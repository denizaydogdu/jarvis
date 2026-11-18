import Foundation

public enum ConversationResult: Sendable {
    case heard(Heard)
    case handoff
    case button(AnswerButton)
    /// A `.choice` answered in full: the picked option (0-based) of each question, in order. Any
    /// question left unanswered ends the ask with another result instead (all or nothing); a `.heard`
    /// result for a `.choice` is the answer that picked nothing.
    case choices([Int])
    /// Nothing was shown or asked (the session's own terminal tab is in front).
    case skipped
    /// "Konuşamam" (button or voice, or quiet mode turned on while the ask was on screen): quiet mode goes
    /// on for `QuietMode.defaultSeconds` unless already on, and the ask ends with no decision.
    case notNow
}

public protocol Conversation: Sendable {
    /// `budget`: seconds left before the hook gives up waiting; the ask must end within it.
    /// `sequence`: the queue's submit-order number of this request, unique per request.
    func ask(_ r: JarvisRequest, silent: Bool, budget: Double, sequence: Int) async -> ConversationResult
    /// Ends the info display with this `sequence` at once, shown or still getting ready. A no-op for
    /// any other ask: it never answers a real question, nor an info display other than that one.
    func interruptInfo(sequence: Int) async
}

/// Serialises voice conversations: strictly one `ask` at a time, in submit order.
public actor RequestQueue {
    private let conversation: Conversation
    private let now: @Sendable () -> Date
    private let minAskSeconds: Double
    /// Kept between the end of an ask and the hook's deadline, so the answer still reaches the hook.
    public static let budgetMarginSeconds: Double = 3
    private var muted = false
    /// Tail of the FIFO chain; each new request awaits the previous one before running.
    private var tail: Task<JarvisResponse, Never>?
    /// Submit order, increasing by one per request; never reused.
    private var nextSequence = 0
    /// Sequence number of the newest non-info request; info displays submitted before it are dropped.
    private var newestRealSequence = -1
    /// Sequence number of the info display currently handed to the conversation, if any.
    private var activeInfoSequence: Int?
    /// "Şu an konuşamam": while active, nothing is asked (see `run`).
    private var quiet = QuietMode()
    private var quietObserver: (@Sendable (QuietEvent) -> Void)?
    /// Test support: callers of `waitUntilSubmitted`, each with the submission count it waits for.
    private var submissionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init(conversation: Conversation,
                now: @escaping @Sendable () -> Date = Date.init,
                minAskSeconds: Double = 30) {
        self.conversation = conversation
        self.now = now
        self.minAskSeconds = minAskSeconds
    }

    public func setMuted(_ on: Bool) { muted = on }

    public var isMuted: Bool { muted }

    /// Turns quiet mode on until `until` (nil: until `endQuiet`), or moves its end. Missed requests
    /// recorded so far are kept until `endQuiet`, also when the previous period had already expired.
    public func setQuiet(until: Date?) {
        quiet.turnOn(until: until)
        quietObserver?(.on(quiet))
    }

    /// Ends quiet mode and returns it as it was, with the requests it answered without asking (for the
    /// resume sentence, `QuietMode.summaryText`). A no-op returning the off state when it was not on.
    @discardableResult
    public func endQuiet() -> QuietMode {
        let ended = quiet
        quiet = QuietMode()
        return ended
    }

    /// The current quiet mode; it may be on but past its end time until `endQuiet` is called.
    public var quietMode: QuietMode { quiet }

    /// Quiet mode is on and its end time has not passed.
    public var isQuiet: Bool { quiet.isActive(now: now()) }

    /// Called on the queue's actor whenever quiet mode turns on or a request is answered without asking.
    public func setQuietObserver(_ observer: (@Sendable (QuietEvent) -> Void)?) {
        quietObserver = observer
    }

    /// Test support: waits until everything submitted so far, including detached info displays, has finished.
    func drain() async {
        _ = await tail?.value
    }

    /// Test support: returns once `count` requests have been submitted (each has its place in the FIFO),
    /// so a test can order its submits by an explicit signal instead of a sleep.
    func waitUntilSubmitted(_ count: Int) async {
        if nextSequence >= count { return }
        await withCheckedContinuation { submissionWaiters.append((count, $0)) }
    }

    /// An info display still waiting for the panel after this long is stale and dropped unseen.
    public static let infoMaxWaitSeconds: Double = 60

    /// `showWhenMuted`: an info display the app itself asked for (the office status and replies) is shown
    /// while muted too, silently. Requests from the socket never pass it.
    public func submit(_ r: JarvisRequest, showWhenMuted: Bool = false) async -> JarvisResponse {
        let submittedAt = now()
        let sequence = nextSequence
        nextSequence += 1
        let previous = tail
        let task = Task { [self] () -> JarvisResponse in
            _ = await previous?.value
            return await run(r, sequence: sequence, submittedAt: submittedAt, showWhenMuted: showWhenMuted)
        }
        tail = task
        if !submissionWaiters.isEmpty {
            let reached = submissionWaiters.filter { $0.count <= nextSequence }
            submissionWaiters.removeAll { $0.count <= nextSequence }
            for w in reached { w.continuation.resume() }
        }
        // An info stop asks nothing, so the session never waits for it: reply now; its display still
        // takes its turn in the FIFO above, one panel at a time.
        if r.isInfoStop { return Self.response(r, .answered) }
        // Quiet at submit time: this request will be answered without asking (see `run`), so it does not
        // cut off the app's own silent display nor drop the ones waiting.
        if quiet.isActive(now: submittedAt) { return await task.value }
        // A real question outranks info: older info displays still waiting are dropped at the head
        // (see `run`), and one on screen now ends at once.
        newestRealSequence = sequence
        if let info = activeInfoSequence { await conversation.interruptInfo(sequence: info) }
        return await task.value
    }

    private func run(_ r: JarvisRequest, sequence: Int, submittedAt: Date, showWhenMuted: Bool) async -> JarvisResponse {
        let waited = now().timeIntervalSince(submittedAt)
        if r.isInfoStop, waited > Self.infoMaxWaitSeconds { return Self.response(r, .answered) }
        // A newer real question exists: this info is no longer worth showing.
        if r.isInfoStop, newestRealSequence > sequence { return Self.response(r, .answered) }
        // Quiet mode: nothing is asked. An info display is dropped uncounted, unless the app itself asked
        // for it (shown silently below); every other request ends at once with no decision.
        let quietNow = quiet.isActive(now: now())
        if quietNow, r.isInfoStop, !showWhenMuted { return Self.response(r, .answered) }
        if quietNow, !r.isInfoStop { return quietAnswer(r) }
        if Double(r.deadlineS) - waited < minAskSeconds { return Self.response(r, .expired) }
        // Muted, a plain "what next?" stop or an info stop is not worth holding the turn for: it ends at
        // once with nothing to do and is never shown. Permissions and question stops still ask silently.
        if muted, r.kind == .stop, !r.asksQuestion, !(showWhenMuted && r.isInfoStop) {
            return Self.response(r, .answered)
        }
        let budget = Double(r.deadlineS) - waited - Self.budgetMarginSeconds
        // Muted: the conversation shows the panel and buttons but neither speaks nor listens.
        // `ResponseStatus.muted` stays in the enum for wire compatibility; the queue no longer produces it.
        if r.isInfoStop { activeInfoSequence = sequence }
        let result = await conversation.ask(r, silent: muted || quietNow, budget: budget, sequence: sequence)
        if activeInfoSequence == sequence { activeInfoSequence = nil }
        // Info asks nothing: Tamam, auto-close or anything else ends it with nothing to do, never an instruction.
        if r.isInfoStop { return Self.response(r, .answered) }
        // Quiet mode turned on while this ask was on screen (menu or timer) does not void an answer he then
        // gives: a button press or spoken answer is his explicit act and is applied as usual. Only a
        // not-now result ends the ask without a decision.
        switch result {
        case .notNow, .button(.notNow):
            return notNow(r)
        case .heard(let h) where IntentParser.notNow(h):
            // Before every other rule: "sonra konuşalım" is never an instruction, a yes/no or a pick.
            return notNow(r)
        case .handoff:
            return Self.response(r, .handoff)
        case .skipped:
            // A permission or a multiple-choice question goes to the focused session's own dialog.
            return Self.response(r, r.kind == .stop ? .answered : .handoff)
        case .button(let b):
            return Self.buttonResponse(r, b)
        case .choices(let picks):
            return Self.choiceResponse(r, picks)
        case .heard(let h) where r.kind == .choice:
            // The conversation parses each spoken pick itself; a heard result here picked nothing.
            let d = IntentParser.choiceUnanswered(h)
            return Self.response(r, d.status)
        case .heard(let h):
            let d = r.kind == .permission
                ? IntentParser.permission(h, risky: r.risky)
                : IntentParser.stop(h, asksQuestion: r.asksQuestion)
            return JarvisResponse(id: r.id, status: d.status,
                                  transcript: d.status == .answered ? h.text : nil,
                                  intent: d.intent)
        }
    }

    /// Answered only when there is exactly one valid pick per question; the labels go back in order.
    private static func choiceResponse(_ r: JarvisRequest, _ picks: [Int]) -> JarvisResponse {
        guard r.kind == .choice, !r.choices.isEmpty, picks.count == r.choices.count else { return response(r, .unclear) }
        var labels: [String] = []
        for (q, pick) in zip(r.choices, picks) {
            guard q.options.indices.contains(pick) else { return response(r, .unclear) }
            labels.append(q.options[pick].label)
        }
        return JarvisResponse(id: r.id, status: .answered, transcript: nil, intent: Intent.none, answers: labels)
    }

    private static func buttonResponse(_ r: JarvisRequest, _ b: AnswerButton) -> JarvisResponse {
        // A button not offered for this request is defensive-unclear; only `.confirm` allows risky work.
        guard AnswerButton.buttons(for: r).contains(b) else { return response(r, .unclear) }
        // On a stop, Evet/Hayır answer Claude's question: the word goes back as the next instruction.
        if r.kind == .stop, b == .yes || b == .no {
            return JarvisResponse(id: r.id, status: .answered, transcript: b == .yes ? "Evet" : "Hayır", intent: .proceed)
        }
        switch b {
        case .yes, .confirm:
            return JarvisResponse(id: r.id, status: .answered, transcript: "Evet (düğme)", intent: .allow)
        case .no:
            return JarvisResponse(id: r.id, status: .answered, transcript: "Hayır (düğme)", intent: .deny)
        case .terminal:
            return response(r, .handoff)
        case .done, .ok:
            return response(r, .answered)
        case .cancel:
            // Office asks only (never offered above); the app reads its meaning from its side channel.
            return response(r, .unclear)
        case .notNow:
            // Handled by `run` before any button; never a decision.
            return response(r, .unclear)
        case .option:
            // Options answer only through `.choices`, one per question.
            return response(r, .unclear)
        }
    }

    /// "Konuşamam" ended the ask: quiet mode goes on for the default time (an end already set, or "until
    /// turned off", is kept), and the request is answered as any request reaching the queue while quiet.
    private func notNow(_ r: JarvisRequest) -> JarvisResponse {
        if !quiet.isActive(now: now()) { setQuiet(until: now().addingTimeInterval(QuietMode.defaultSeconds)) }
        return quietAnswer(r)
    }

    /// The answer to a request while quiet; nothing is approved, denied or picked.
    /// - Office decision → `expired`: nothing sent, the poller asks it again after quiet mode
    ///   (`OfisOutcome.retry`); not counted, since no terminal waits for it.
    /// - Hook request (permission, stop, choice) → `handoff`, the same no-decision response as the
    ///   Terminal button: the hook prints nothing and Claude Code shows its own prompt (a stop simply
    ///   ends its turn). Counted as missed with its project and kind only.
    private func quietAnswer(_ r: JarvisRequest) -> JarvisResponse {
        if OfisCards.isOfficeAsk(r) { return Self.response(r, .expired) }
        let m = QuietMode.Missed(project: r.project, kind: r.kind)
        quiet.record(m)
        quietObserver?(.missed(m, quiet))
        return Self.response(r, .handoff)
    }

    private static func response(_ r: JarvisRequest, _ s: ResponseStatus) -> JarvisResponse {
        JarvisResponse(id: r.id, status: s, transcript: nil, intent: Intent.none)
    }
}

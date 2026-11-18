import Foundation
import JarvisCore

/// One conversation: show the panel with answer buttons, speak `speech`, listen for the answer.
/// A silent ask (Sessiz) shows the panel and buttons only: no speech, no listening. A `.choice` whose
/// estimated spoken length (`ChoiceTiming`) exceeds what is left of the cap is asked silently too.
/// An info stop is spoken but never listened to; its panel closes `infoCloseSeconds` after speech.
/// `ask` always finishes within `min(hardCapSeconds, budget)`; a button press ends it at once.
/// When the request's session is the Terminal tab in front, nothing is shown or spoken (`TerminalFocus`).
/// A `.choice` asks its questions one after another in the same ask; it ends with `.choices` only when
/// every question got exactly one option, and any non-answer ends the whole ask (all or nothing).
/// An office ask (`OfisDesk`) is a one-question `.choice` with its own speech, `Konuşamam` but no
/// `Terminal`, voice matched on option text or code, and, for a high-risk card, a confirm step after the
/// pick that only the held `Onaylıyorum` passes (voice is ignored there; `Konuşamam` sends nothing).
/// Quiet mode turned on from the menu ends the ask on screen with `.notNow`; the app's own displays
/// (office status and replies, the resume sentence) are left alone.
@MainActor
final class AppConversation: Conversation {
    /// The whole stop message is now read out, so the cap is well above the old 60 s. The hook waits
    /// 150 s, so every ask still ends before the hook gives up.
    static let hardCapSeconds: Double = 110
    /// An info panel stays this long after its speech ends, then closes by itself.
    static let infoCloseSeconds: Double = 6
    /// A silent (muted) office display closes by itself after this long; Tamam closes it sooner.
    static let silentInfoCloseSeconds: Double = 20
    /// The panel stays hidden at least this long between consecutive asks, so a late click meant for
    /// the previous ask lands on nothing.
    static let gapSeconds: Double = 0.25
    /// Pause between the end of speech and the start of listening, so the prompt's own tail is not heard.
    static let postSpeechSeconds: Double = 0.5
    static let silence = Heard(text: "", confidence: 0)

    /// State of one `ask`. The continuation is resumed exactly once, in `resolve`.
    private final class ActiveAsk {
        let silent: Bool
        /// An info display: `interruptInfo` with its `sequence` may end it; it never ends any other ask.
        let info: Bool
        /// One of the app's own displays (`OfisDesk.registerDisplay`): quiet mode does not end it.
        let display: Bool
        /// The queue's sequence number of this request.
        let sequence: Int
        /// `.choice` only: the question on screen and the options picked so far, in order.
        var question = 0
        var picks: [Int] = []
        var continuation: CheckedContinuation<ConversationResult, Never>?
        var work: Task<Void, Never>?
        var cap: Task<Void, Never>?
        var done: Bool { continuation == nil }

        init(silent: Bool, info: Bool, display: Bool, sequence: Int) {
            self.silent = silent
            self.info = info
            self.display = display
            self.sequence = sequence
        }
    }

    private let speaker: Speaker
    private let listener: Listener
    private let panel: PanelController
    private let log: JarvisLog
    private let focus: TerminalFocus
    private let desk: OfisDesk
    private var active: ActiveAsk?
    /// Sequence of the info ask still in its focus checks and gap, before anything is shown;
    /// `interruptInfo` with that sequence clears it, and the ask then ends unseen.
    private var preparingInfo: Int?
    /// Sequence of an info ask whose interrupt arrived before the ask itself started (the queue's two
    /// hops to the main actor are not ordered); that ask ends unseen as soon as it starts.
    private var earlyInfoInterrupt: Int?
    /// Mirrors the menu's Sessiz state; set after the queue's own state (see StatusMenu).
    private var muted = false
    /// Mirrors the queue's quiet mode (see QuietControl): set after the queue turned it on, cleared before
    /// the queue ends it, and its end time checked at use, so a stale copy never turns it on again.
    private var quietMode = QuietMode()

    init(speaker: Speaker, listener: Listener, panel: PanelController, log: JarvisLog, desk: OfisDesk) {
        self.speaker = speaker
        self.listener = listener
        self.panel = panel
        self.log = log
        self.desk = desk
        self.focus = TerminalFocus(log: log)
    }

    func ask(_ r: JarvisRequest, silent: Bool, budget: Double, sequence: Int) async -> ConversationResult {
        let started = ContinuousClock.now
        let info = r.isInfoStop
        // "Ofis kararlarını sor" was turned off while this office ask waited in the queue: it ends unseen.
        if desk.ask(for: r.id) != nil, !desk.asking {
            desk.mark(r.id, .withdrawn)
            return .skipped
        }
        // An app display (office status or reply, the resume sentence) is shown even when muted: silently,
        // then it closes by itself. Whoever waits for its end is told on every way out of this ask.
        let officeDisplay = info && desk.takeDisplay(r.id)
        defer { if officeDisplay { desk.displayEnded(r.id) } }
        if info, earlyInfoInterrupt == sequence {
            earlyInfoInterrupt = nil
            return .button(.ok)
        }
        if info { preparingInfo = sequence }
        defer { if preparingInfo == sequence { preparingInfo = nil } }
        // (a) At the head of the queue, before anything is shown: his own terminal tab is in front.
        if let skipped = await focusSkip(r) { return skipped }
        let hiddenFor = panel.secondsSinceHidden
        if hiddenFor < Self.gapSeconds {
            try? await Task.sleep(for: .seconds(Self.gapSeconds - hiddenFor))
        }
        // (b) Again right before showing and speaking: he may have switched to this session meanwhile.
        if let skipped = await focusSkip(r) { return skipped }
        // A real question arrived while this info display was getting ready: it ends unseen.
        if info, preparingInfo != sequence { return .button(.ok) }
        if info { preparingInfo = nil }
        // Quiet mode was turned on during the focus checks or the gap: nothing is shown but the app's own
        // displays; the queue answers a real request as any request reaching it while quiet.
        if quietMode.isActive(now: Date()), !officeDisplay { return info ? .button(.ok) : .notNow }
        // Mute may have been turned on during the gap, when no ask was active to hand off: honour it now,
        // as the queue would have. A muted plain or info stop ends at once with nothing to do.
        var silent = silent || muted
        if silent, r.kind == .stop, !r.asksQuestion, !officeDisplay {
            return .button(r.info ? .ok : .done)
        }
        // The ask must end before the hook stops waiting: cap it by what is left of the budget.
        let elapsed = Self.seconds(ContinuousClock.now - started)
        // The focus checks and the gap count toward the cap, so the whole ask ends within min(110, budget).
        let capSeconds = max(0, min(Self.hardCapSeconds, budget) - elapsed)
        let capEnds = ContinuousClock.now + .seconds(capSeconds)
        // A choice too long to speak and hear within the cap is asked silently: buttons only, so it is
        // still answered by a click instead of timing out halfway through the questions.
        if !silent, ChoiceTiming.asksSilently(r, capSeconds: capSeconds) {
            silent = true
            log.append("choice: too long to speak, asked silently")
        }

        // The queue serialises asks; a leftover one would be a bug, so end it rather than overlap.
        interrupt()

        let current = ActiveAsk(silent: silent, info: info, display: officeDisplay, sequence: sequence)
        active = current
        // An app display shows its text alone, without the "still working" line.
        let parts = officeDisplay || OfisCards.isOfficeInfo(r) ? (body: r.detail, question: "", detail: "")
                                                               : SpeechSplit.panel(for: r)
        let buttons = AnswerButton.buttons(for: r)
        let show: @MainActor (CatState) -> Void = { [panel] state in
            panel.show(project: r.project, body: parts.body, question: parts.question, detail: parts.detail,
                       buttons: buttons, state: state)
        }
        if r.kind != .choice {
            // Bound to this ask: a late press (e.g. a hold started during the previous ask) cannot reach another one.
            panel.onButton = { [weak self] button in self?.press(button, on: current) }
            show(silent ? .silent : .speaking)
        }

        let result = await withCheckedContinuation { (c: CheckedContinuation<ConversationResult, Never>) in
            current.continuation = c
            current.cap = Task { [weak self] in
                try? await Task.sleep(for: .seconds(capSeconds))
                guard !Task.isCancelled else { return }
                self?.resolve(current, .heard(Self.silence))
            }
            if r.kind == .choice {
                // One cap for all questions together.
                self.askQuestion(0, of: r, on: current, capEnds: capEnds)
                return
            }
            // A silent office display: shown without speech, closed after a while (or by Tamam).
            if silent, info {
                current.work = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.silentInfoCloseSeconds))
                    guard let self, !Task.isCancelled, !current.done else { return }
                    self.resolve(current, .button(.ok))
                }
                return
            }
            // Silent: buttons only; the cap above ends an unanswered ask as `timeout`.
            guard !silent else { return }
            current.work = Task { [weak self] in
                guard let self else { return }
                // Speech may not outlive the ask: its own limit is bounded by what is left of the cap.
                let left = Self.seconds(capEnds - ContinuousClock.now)
                await self.speaker.speak(r.speech, maxSeconds: max(0, left))
                guard !current.done else { return }
                if info {
                    // Nobody is asked anything: no listening; the panel closes by itself.
                    show(.idle)
                    try? await Task.sleep(for: .seconds(Self.infoCloseSeconds))
                    guard !current.done else { return }
                    self.resolve(current, .button(.ok))
                    return
                }
                try? await Task.sleep(for: .seconds(Self.postSpeechSeconds))
                guard !current.done else { return }
                show(.listening)
                let heard = await self.listener.listen()
                self.resolve(current, .heard(heard))
            }
        }

        if active == nil {
            panel.onButton = nil
            panel.hide()
        }
        return result
    }

    /// Shows and (unless silent) speaks question `q` of a `.choice`, then listens. A clear spoken pick or an
    /// option button moves on to the next question; anything else ends the whole ask.
    private func askQuestion(_ q: Int, of r: JarvisRequest, on current: ActiveAsk, capEnds: ContinuousClock.Instant) {
        guard !current.done else { return }
        // The hook never sends a choice without questions; should one arrive, the terminal takes it.
        guard r.choices.indices.contains(q) else { resolve(current, .handoff); return }
        current.question = q
        let question = r.choices[q]
        let office = desk.ask(for: r.id)
        let parts = office.map { (body: $0.panelBody, question: $0.panelQuestion) }
            ?? SpeechSplit.choicePanel(for: r, question: q)
        let buttons = Self.buttons(for: r, question: q, office: office)
        let speech = office?.speech ?? SpeechText.choice(project: r.project, question: question)
        // A new handler per question restarts the panel's inert window and binds presses to this
        // question: a double click cannot answer the next one.
        panel.onButton = { [weak self] button in self?.pressChoice(button, question: q, of: r, on: current, capEnds: capEnds) }
        let show: @MainActor (CatState) -> Void = { [panel] state in
            panel.show(project: r.project, body: parts.body, question: parts.question, detail: "",
                       buttons: buttons, options: question.options,
                       numberedOptions: OfisCards.numbersOptions(r), state: state)
        }
        show(current.silent ? .silent : .speaking)
        guard !current.silent else { return }
        current.work = Task { [weak self] in
            guard let self else { return }
            let isCurrent = { !Task.isCancelled && !current.done && current.question == q }
            let left = Self.seconds(capEnds - ContinuousClock.now)
            await self.speaker.speak(speech, maxSeconds: max(0, left))
            guard isCurrent() else { return }
            try? await Task.sleep(for: .seconds(Self.postSpeechSeconds))
            guard isCurrent() else { return }
            show(.listening)
            let heard = await self.listener.listen()
            guard isCurrent() else { return }
            let spoken = office.map { $0.spokenPick(heard) }
                ?? IntentParser.choice(heard, options: question.options.map(\.label))
            if let pick = spoken {
                self.log.append("answer: voice option\(pick + 1)")
                self.pick(pick, of: r, on: current, capEnds: capEnds)
            } else {
                // The queue classifies it: silence → timeout, "terminal" → handoff, else unclear.
                self.resolve(current, .heard(heard))
            }
        }
    }

    private func pressChoice(_ button: AnswerButton, question q: Int, of r: JarvisRequest, on a: ActiveAsk,
                             capEnds: ContinuousClock.Instant) {
        guard !a.done, a.question == q else { return }
        log.append("answer: button \(button.logName)")
        let offered = Self.buttons(for: r, question: q, office: desk.ask(for: r.id))
        if case .option(let i) = button, offered.contains(button) {
            pick(i, of: r, on: a, capEnds: capEnds)
        } else {
            // Konuşamam: nothing is sent; the queue turns quiet mode on and the poller asks again after it.
            if button == .notNow, offered.contains(button) { desk.mark(r.id, .notNow) }
            // Terminal hands off; a button not offered ends the ask and the queue answers it as unclear.
            resolve(a, .button(button))
        }
    }

    /// The buttons while question `q` is on screen: an office ask has no `Terminal`.
    private static func buttons(for r: JarvisRequest, question q: Int, office: OfisAsk?) -> [AnswerButton] {
        office != nil ? OfisCards.buttons(for: r) : AnswerButton.buttons(for: r, question: q)
    }

    /// No question is on screen while the focus is re-checked between questions: presses are ignored.
    private static let betweenQuestions = -1
    /// The high-risk confirm step of an office ask is on screen: option presses are ignored.
    private static let confirming = -2

    /// Records the pick for the question on screen, stops its speech and listening, and asks the next
    /// question, or ends the ask with all picks after the last one. Before the next question the focus
    /// is checked again: if he switched to this session's tab, the whole ask ends as handoff and the
    /// terminal's own dialog shows every question.
    private func pick(_ index: Int, of r: JarvisRequest, on a: ActiveAsk, capEnds: ContinuousClock.Instant) {
        guard !a.done else { return }
        a.picks.append(index)
        a.work?.cancel()
        a.work = nil
        speaker.stop()
        listener.cancel()
        if a.picks.count >= r.choices.count {
            if let office = desk.ask(for: r.id), office.needsScreenConfirm {
                confirmStep(index, office: office, of: r, on: a)
            } else {
                resolve(a, .choices(a.picks))
            }
            return
        }
        a.question = Self.betweenQuestions
        let next = a.picks.count
        a.work = Task { [weak self] in
            guard let self else { return }
            let skipped = await self.focusSkip(r)
            guard !Task.isCancelled, !a.done else { return }
            if let skipped {
                self.resolve(a, skipped)
            } else {
                self.askQuestion(next, of: r, on: a, capEnds: capEnds)
            }
        }
    }

    /// The high-risk office confirm step: "<seçim> — Onaylıyor musun?" with the held `Onaylıyorum`, `İptal`
    /// and `Konuşamam`. Nothing is spoken or listened to; only the hold answers, `Konuşamam` sends nothing
    /// and turns quiet mode on, and the ask's cap still ends it unanswered. A new handler restarts the
    /// panel's inert window, so the pick's click cannot reach it.
    private func confirmStep(_ index: Int, office: OfisAsk, of r: JarvisRequest, on a: ActiveAsk) {
        a.question = Self.confirming
        panel.onButton = { [weak self] button in self?.pressConfirm(button, of: r, on: a) }
        panel.show(project: r.project, body: office.riskLine ?? "", question: office.confirmQuestion(forOption: index),
                   detail: "", buttons: Self.confirmButtons, state: a.silent ? .silent : .idle)
    }

    /// The confirm step's buttons; `Konuşamam` is a plain click, only `Onaylıyorum` needs the hold.
    private static let confirmButtons: [AnswerButton] = [.confirm, .cancel, .notNow]

    private func pressConfirm(_ button: AnswerButton, of r: JarvisRequest, on a: ActiveAsk) {
        guard !a.done, a.question == Self.confirming else { return }
        log.append("answer: button \(button.logName)")
        switch button {
        case .confirm:
            desk.mark(r.id, .confirmed)
            resolve(a, .choices(a.picks))
        case .cancel:
            desk.mark(r.id, .cancelled)
            resolve(a, .button(.cancel))
        case .notNow:
            // Nothing is sent; the card is asked again after quiet mode (OfisOutcome `.retry`).
            desk.mark(r.id, .notNow)
            resolve(a, .notNow)
        default:
            break
        }
    }

    /// Nothing is shown or spoken for the focused session: a permission goes to the terminal's own
    /// dialog; a stop (question, plain or info) ends with nothing to do. Logged without content.
    private func focusSkip(_ r: JarvisRequest) async -> ConversationResult? {
        switch await focus.decide(r) {
        case .show:
            return nil
        case .skipHandoff:
            log.append("skipped: focused")
            return .handoff
        case .skipNone:
            log.append("skipped: focused")
            return .skipped
        }
    }

    private static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    /// Ends the current ask with `.handoff`. No-op when idle.
    func interrupt() {
        guard let current = active else { return }
        resolve(current, .handoff)
    }

    /// A real question was submitted while info ask `sequence` was handed to the conversation: that
    /// display ends at once, through the same once-only `resolve`; not yet shown, it ends unseen. Any
    /// other ask, including a newer info display, is left alone.
    func interruptInfo(sequence: Int) {
        if preparingInfo == sequence {
            preparingInfo = nil
            return
        }
        if let current = active, current.info, current.sequence == sequence {
            log.append("info: interrupted by a request")
            resolve(current, .button(.ok))
            return
        }
        // Neither preparing nor on screen: that ask either has not started yet, or has already ended
        // (then the mark is never matched, since sequences are not reused).
        earlyInfoInterrupt = sequence
    }

    /// Sessiz changed. Turned on: a spoken ask is handed to the terminal (v1 behaviour); a silent ask
    /// already matches the muted state and keeps waiting for a button.
    func muteChanged(_ on: Bool) {
        muted = on
        guard on, let current = active, !current.silent else { return }
        resolve(current, .handoff)
    }

    /// Quiet mode changed. Active: the ask on screen ends as if `Konuşamam` was pressed (an info display
    /// just closes); the app's own displays stay.
    func quietChanged(_ mode: QuietMode) {
        quietMode = mode
        guard mode.isActive(now: Date()), let current = active, !current.display else { return }
        log.append("quiet: ended the ask on screen")
        resolve(current, current.info ? .button(.ok) : .notNow)
    }

    private func press(_ button: AnswerButton, on a: ActiveAsk) {
        guard !a.done else { return }
        log.append("answer: button \(button.logName)")
        resolve(a, .button(button))
    }

    private func resolve(_ a: ActiveAsk, _ result: ConversationResult) {
        guard let c = a.continuation else { return }
        a.continuation = nil
        a.cap?.cancel()
        a.work?.cancel()
        // Stop audio first so nothing keeps playing or recording after the answer is decided.
        speaker.stop()
        listener.cancel()
        if active === a { active = nil }
        c.resume(returning: result)
    }
}

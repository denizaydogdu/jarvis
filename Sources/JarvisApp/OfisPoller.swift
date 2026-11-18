import Foundation
import JarvisCore

/// The app-side channel between the poller and the panel for office asks. Office requests never leave the
/// app, so their note, risk and codes travel here, keyed by request id, instead of on the wire.
@MainActor
final class OfisDesk {
    /// Mirrors the menu's "Ofis kararlarını sor"; an office ask that reaches the panel while it is off ends unseen.
    var asking = true
    private var asks: [String: OfisAsk] = [:]
    private var marks: [String: OfisPanelMark] = [:]
    /// Ids of the app's own displays (office status and replies, the quiet-mode resume sentence): shown
    /// even when muted, silently.
    private var displays: Set<String> = []
    /// Displays someone waits for (`waitForDisplayEnd`), with the waiter once it arrived.
    private var watched: Set<String> = []
    private var endWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    /// Watched displays that ended before their waiter arrived.
    private var endedEarly: Set<String> = []

    func register(_ ask: OfisAsk, id: String) { asks[id] = ask }

    /// `watched`: its end can be awaited with `waitForDisplayEnd`.
    func registerDisplay(_ id: String, watched watch: Bool = false) {
        displays.insert(id)
        if watch { watched.insert(id) }
    }

    /// Whether `id` is an app display; read once, when the display reaches the panel.
    func takeDisplay(_ id: String) -> Bool { displays.remove(id) != nil }

    /// The panel is done with display `id` (shown, interrupted or ended unseen).
    func displayEnded(_ id: String) {
        guard watched.remove(id) != nil else { return }
        if let waiter = endWaiters.removeValue(forKey: id) {
            waiter.resume()
        } else {
            endedEarly.insert(id)
        }
    }

    /// Returns when watched display `id` has ended, or after `timeout` seconds: the queue may drop a display
    /// without the panel ever seeing it (stale, or a real question came first).
    func waitForDisplayEnd(_ id: String, timeout: Double) async {
        if endedEarly.remove(id) != nil { return }
        guard watched.contains(id) else { return }
        var timer: Task<Void, Never>?
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            endWaiters[id] = c
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self else { return }
                self.displays.remove(id)
                self.watched.remove(id)
                self.endWaiters.removeValue(forKey: id)?.resume()
            }
        }
        // Ended before the timeout: its timer is not needed any more.
        timer?.cancel()
    }

    /// The office ask behind request `id`; nil for every hook request.
    func ask(for id: String) -> OfisAsk? { asks[id] }

    /// The first mark of an ask wins; it is read once, by `finish`.
    func mark(_ id: String, _ mark: OfisPanelMark) {
        guard asks[id] != nil, marks[id] == nil else { return }
        marks[id] = mark
    }

    /// Forgets the ask and returns what the panel marked for it.
    func finish(_ id: String) -> OfisPanelMark? {
        asks[id] = nil
        return marks.removeValue(forKey: id)
    }
}

/// Polls the office gate for pending decisions and asks them through the shared `RequestQueue`.
///
/// - One loop, never overlapping itself: every 30 s while the gate answers, 5 min while it is off,
///   2 min while unreachable, the Retry-After when rate limited (`OfisGateState`). Each gate state change
///   is logged once, without key or content.
/// - A note is taken once (`pending`) and remembered on disk (`OfisSeen`) only when an answer reached
///   the office; `İptal` snoozes it 30 minutes, `Konuşamam` leaves it for after quiet mode, silence or an unclear answer 10 minutes.
/// - At most one office ask is in the queue at a time: new cards wait in `backlog`, in poll order, and
///   one worker task submits the next only after the previous ask (and its answer) has finished.
/// - Office displays (status, "İletildi." …) are shown even when muted, silently.
/// - While quiet mode is on nothing is asked: cards stay on the office page and are asked after it
///   (`pollNow` when it ends).
/// - Log lines carry note names, codes and states only: never question text or the key.
actor OfisPoller {
    private let client: OfisClient
    private let queue: RequestQueue
    private let desk: OfisDesk
    private let log: JarvisLog
    private let seenPath: String
    private var seen: OfisSeen
    /// Notes enqueued or being answered.
    private var pending: Set<String> = []
    /// "note\0reason" of skips already logged in this run.
    private var loggedSkips: Set<String> = []
    private var gate: OfisGateState?
    private var loop: Task<Void, Never>?
    private var enabled = false
    /// Askable cards not yet submitted, in poll order; their notes are in `pending`.
    private var backlog: [OfisAsk] = []
    /// The single task that submits `backlog` one ask at a time; nil when idle.
    private var worker: Task<Void, Never>?
    /// A "Ofis durumu" call is under way: further clicks are ignored.
    private var statusInFlight = false

    init(client: OfisClient, queue: RequestQueue, desk: OfisDesk, log: JarvisLog, seenPath: String) {
        self.client = client
        self.queue = queue
        self.desk = desk
        self.log = log
        self.seenPath = seenPath
        seen = OfisSeen.load(from: seenPath)
    }

    /// Starts or stops the poll loop ("Ofis kararlarını sor"). Asks already queued still run; the panel
    /// drops them unseen while asking is off (see `OfisDesk.asking`).
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        log.append(on ? "ofis: asking on" : "ofis: asking off")
        if on {
            restartLoop()
        } else {
            loop?.cancel()
            // Not yet submitted: dropped; the next poll after turning it on finds them again.
            for ask in backlog { pending.remove(ask.note) }
            backlog.removeAll()
        }
    }

    /// Quiet mode ended: polls at once instead of at the next tick, so waiting cards are asked now.
    /// A no-op while "Ofis kararlarını sor" is off, and while the gate is backing off (off, unreachable,
    /// rate limited …): its wait is kept and the running loop polls when it is over.
    func pollNow() {
        guard enabled, gate == nil || gate == .ok else { return }
        restartLoop()
    }

    /// Cancels the poll loop (if any) and starts a new one that polls at once. A cancelled loop may still be
    /// finishing its last call: the new one starts after it, so polls never overlap.
    private func restartLoop() {
        let previous = loop
        previous?.cancel()
        loop = Task {
            await previous?.value
            await self.run()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            let wait = await pollOnce()
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// One `kararlar` call; returns the seconds until the next.
    private func pollOnce() async -> TimeInterval {
        do {
            let kararlar = try await client.kararlar()
            // Turned off while the call was under way: nothing is asked.
            guard !Task.isCancelled else { return 0 }
            noteGate(.ok)
            await handle(kararlar)
            return OfisGateState.pollSeconds
        } catch {
            if Task.isCancelled { return 0 }
            let next = OfisGateState.after(error)
            noteGate(next.state)
            return next.wait
        }
    }

    private func noteGate(_ state: OfisGateState) {
        guard state != gate else { return }
        gate = state
        log.append("ofis: gate \(state.rawValue)")
    }

    private func handle(_ kararlar: [OfisKarar]) async {
        let now = Date()
        var updated = seen
        updated.prune(keeping: Set(kararlar.map(\.note)))
        saveIfChanged(updated)
        // Waiting cards that left the list (answered on the page) or got snoozed are not asked.
        let current = Set(kararlar.map(\.note))
        let dropped = backlog.filter { !current.contains($0.note) || !seen.shouldAsk($0.note, now: now) }
        for ask in dropped { pending.remove(ask.note) }
        backlog.removeAll { ask in dropped.contains { $0.note == ask.note } }
        // Quiet mode: nothing is asked; the cards are found again by the poll when it ends.
        if await queue.isQuiet { return }
        let plan = OfisPollPlan.make(kararlar, seen: seen, pending: pending, now: now)
        for skip in plan.skips where loggedSkips.insert(skip.note + "\u{0}" + skip.reason).inserted {
            log.append("ofis: skipped \(JarvisLog.field(skip.note)): \(skip.reason)")
        }
        for ask in plan.asks {
            pending.insert(ask.note)
            backlog.append(ask)
        }
        startWorker()
    }

    /// Starts the one worker unless it runs; it submits the backlog strictly one ask at a time.
    private func startWorker() {
        guard worker == nil, !backlog.isEmpty else { return }
        worker = Task { await self.work() }
    }

    private func work() async {
        while !backlog.isEmpty {
            let ask = backlog.removeFirst()
            // Quiet mode came on while cards waited: the rest is dropped and found again after it.
            if await queue.isQuiet {
                pending.remove(ask.note)
                for waiting in backlog { pending.remove(waiting.note) }
                backlog.removeAll()
                break
            }
            await askAndAnswer(ask)
        }
        // No suspension between the empty check and this: a card added meanwhile is in `backlog`
        // and starts a new worker on the next `startWorker`.
        worker = nil
    }

    private func askAndAnswer(_ ask: OfisAsk) async {
        let id = "ofis-" + UUID().uuidString.lowercased()
        // Registered before the queue can reach it.
        await desk.register(ask, id: id)
        log.append("ofis: asked \(JarvisLog.field(ask.note))")
        let response = await queue.submit(OfisCards.request(for: ask, id: id))
        await finish(ask, id: id, response: response)
    }

    private func finish(_ ask: OfisAsk, id: String, response: JarvisResponse) async {
        let mark = await desk.finish(id)
        defer { pending.remove(ask.note) }
        switch OfisOutcome.decide(ask: ask, response: response, mark: mark) {
        case .retry:
            return
        case .snooze(let seconds):
            snooze(ask.note, for: seconds)
        case .send(let cevap, let ekranOnayi):
            await send(ask, cevap: cevap, ekranOnayi: ekranOnayi)
        }
    }

    /// Sends the answer; after the hold, an input-required reply is continued once with `onayla`.
    private func send(_ ask: OfisAsk, cevap: String, ekranOnayi: Bool) async {
        var reply = OfisReply.classify(await result { try await $0.cevapla(ask: ask, cevap: cevap,
                                                                             ekranOnayi: ekranOnayi) },
                                       mayConfirm: ekranOnayi)
        if case .needsScreenConfirm(let taskId) = reply {
            reply = OfisReply.classify(await result { try await $0.onayla(taskId: taskId) }, mayConfirm: false)
        }
        if reply.marksAsked {
            seen.markAsked(ask.note, at: Date())
            save()
            log.append("ofis: answered \(JarvisLog.field(ask.note)) \(cevap)")
        }
        if case .notDelivered(let reason) = reply {
            log.append("ofis: not delivered \(JarvisLog.field(ask.note)): \(reason)")
        }
        if let seconds = reply.snooze { snooze(ask.note, for: seconds) }
        if let text = reply.speech { await say(text) }
    }

    private func result(_ call: (OfisClient) async throws -> OfisCevapSonucu) async -> Result<OfisCevapSonucu, Error> {
        do {
            return .success(try await call(client))
        } catch {
            return .failure(error)
        }
    }

    private func snooze(_ note: String, for seconds: TimeInterval) {
        seen.snooze(note, for: seconds, now: Date())
        save()
        log.append("ofis: snoozed \(JarvisLog.field(note))")
    }

    // MARK: status

    /// "Ofis durumu": the `durum` text in an info panel, through the queue so it never overlaps an ask.
    func showStatus() async {
        guard !statusInFlight else { return }
        statusInFlight = true
        defer { statusInFlight = false }
        let text: String
        do {
            text = try await client.durum().text
        } catch {
            log.append("ofis: status failed (\(OfisGateState.after(error).state.rawValue))")
            text = Self.statusUnavailable
        }
        await say(text.isEmpty ? Self.statusUnavailable : text, status: true)
    }

    static let statusUnavailable = "Ofise şu an ulaşılamıyor."

    /// An office display: the queue replies at once and shows it in turn; when muted it is shown silently.
    private func say(_ text: String, status: Bool = false) async {
        let request = status ? OfisCards.statusRequest(text)
                             : OfisCards.infoRequest(text, id: "ofis-" + UUID().uuidString.lowercased())
        await desk.registerDisplay(request.id)
        _ = await queue.submit(request, showWhenMuted: true)
    }

    // MARK: persistence

    private func saveIfChanged(_ updated: OfisSeen) {
        guard updated != seen else { return }
        seen = updated
        save()
    }

    private func save() {
        do {
            try seen.save(to: seenPath)
        } catch {
            log.append("ofis: seen file not saved")
        }
    }
}

import Foundation
import JarvisCore

/// One step of `QuietControl`, in the order it arrived.
private enum QuietStep: Sendable {
    /// From the queue's observer: quiet mode turned on (menu, or a "Konuşamam" answer) or a request missed.
    case event(QuietEvent)
    /// Menu: "30 dakika", "1 saat", "Bugün" (nil: until turned off).
    case turnOn(until: Date?)
    /// Menu: "Devam et" or "Rahatsız etme → Kapat".
    case endFromMenu
    /// The timer reached the end time it was set for.
    case endAtTime(Date)
}

/// "Rahatsız etme" in the app: turns quiet mode on and off, ends it at its end time, keeps the menu and
/// the conversation in step with the queue's quiet mode, and has the missed requests said once when it ends.
///
/// Every step (the queue's `QuietEvent`s, the menu's commands, the timer) goes through one serial stream
/// on the main actor, and after each step the shown state is read back from the queue itself; so a late
/// event can never show quiet mode again after it ended. Quiet mode can also be turned on by the queue
/// ("Konuşamam" pressed or said): its `.on` event schedules the timer the same way.
///
/// Log lines carry no content: `quiet: on <minutes|today|manual>`, `quiet: off <timer|menu>`,
/// `quiet: missed <project> <kind>`.
@MainActor
final class QuietControl {
    /// The resume display is waited for at most this long before the office is polled anyway: the queue
    /// keeps an info display at most `RequestQueue.infoMaxWaitSeconds`, then it is spoken and closes.
    static let summaryWaitSeconds: Double = 90
    /// The end-time timer re-checks the wall clock at least this often (clock changes, sleep and wake).
    static let timerStepSeconds: Double = 30

    private let queue: RequestQueue
    private let desk: OfisDesk
    private let log: JarvisLog
    /// The menu: status line, items, icon and count.
    private let onChange: (QuietMode) -> Void
    /// The conversation's copy of quiet mode.
    private let onConversation: (QuietMode) -> Void
    /// After quiet mode ended and the resume sentence (if any) was shown: the office is polled at once.
    private let onResumed: @MainActor () async -> Void
    private let steps: AsyncStream<QuietStep>.Continuation
    private var consumer: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var timerEnd: Date?

    init(queue: RequestQueue, desk: OfisDesk, log: JarvisLog, onChange: @escaping (QuietMode) -> Void,
         onConversation: @escaping (QuietMode) -> Void, onResumed: @escaping @MainActor () async -> Void) {
        self.queue = queue
        self.desk = desk
        self.log = log
        self.onChange = onChange
        self.onConversation = onConversation
        self.onResumed = onResumed
        let (stream, steps) = AsyncStream.makeStream(of: QuietStep.self)
        self.steps = steps
        consumer = Task { [weak self] in
            await queue.setQuietObserver { [steps] event in steps.yield(.event(event)) }
            let initial = await queue.quietMode
            self?.apply(initial)
            for await step in stream {
                guard let self else { return }
                await self.handle(step)
            }
        }
    }

    /// Menu: quiet mode until `until` (nil: until turned off), or its end moved.
    func turnOn(until: Date?) { steps.yield(.turnOn(until: until)) }

    /// Menu: "Devam et" / "Kapat".
    func end() { steps.yield(.endFromMenu) }

    private func handle(_ step: QuietStep) async {
        switch step {
        case .event(.on(let mode)):
            log.append("quiet: on \(QuietStatus.logLabel(mode, now: Date()))")
        case .event(.missed(let missed, _)):
            log.append("quiet: missed \(JarvisLog.field(missed.project)) \(missed.kind.rawValue)")
        case .turnOn(let until):
            // Logged by the `.on` event it causes.
            await queue.setQuiet(until: until)
        case .endFromMenu:
            await end(reason: "menu")
        case .endAtTime(let end):
            if QuietStatus.shouldEnd(await queue.quietMode, timerEnd: end, now: Date()) {
                await self.end(reason: "timer")
            } else if timerEnd == end {
                // Its task has finished, yet the end is not reached (the clock stepped back): forgotten, so
                // `apply` below sets the timer again for the same end.
                timerEnd = nil
            }
        }
        apply(await queue.quietMode)
    }

    private func end(reason: String) async {
        // Cleared first: a stale "quiet" in the conversation would answer an ask with `.notNow`, which
        // turns quiet mode on again once the queue has ended it.
        onConversation(QuietMode())
        let ended = await queue.endQuiet()
        guard ended.isOn else { return }
        log.append("quiet: off \(reason)")
        apply(QuietMode())
        resume(summary: ended.summaryText())
    }

    /// Says what was missed, as an app display (shown also when muted), and polls the office once it is
    /// done, so an office ask does not cut the sentence short. The display can still be dropped: the queue
    /// drops an info that waited longer than `RequestQueue.infoMaxWaitSeconds`, and a real question that
    /// comes first can preempt it; the office is then polled after `summaryWaitSeconds` at the latest.
    private func resume(summary: String?) {
        let queue = self.queue
        let desk = self.desk
        let onResumed = self.onResumed
        Task {
            if let summary {
                let request = QuietStatus.summaryRequest(summary, id: "quiet-" + UUID().uuidString.lowercased())
                desk.registerDisplay(request.id, watched: true)
                _ = await queue.submit(request, showWhenMuted: true)
                await desk.waitForDisplayEnd(request.id, timeout: Self.summaryWaitSeconds)
            }
            await onResumed()
        }
    }

    private func apply(_ mode: QuietMode) {
        onChange(mode)
        onConversation(mode)
        schedule(mode.isOn ? mode.until : nil)
    }

    /// One timer for the current end time; it re-checks the wall clock every `timerStepSeconds`.
    private func schedule(_ end: Date?) {
        guard end != timerEnd else { return }
        timer?.cancel()
        timer = nil
        timerEnd = end
        guard let end else { return }
        let steps = self.steps
        timer = Task {
            while !Task.isCancelled {
                let left = end.timeIntervalSinceNow
                if left <= 0 { break }
                try? await Task.sleep(for: .seconds(min(left, Self.timerStepSeconds)))
            }
            guard !Task.isCancelled else { return }
            steps.yield(.endAtTime(end))
        }
    }
}

import AppKit
import Foundation
import JarvisCore

/// Decides whether a request's session is the Terminal.app tab the user is looking at (see `FocusRule`).
/// The Apple Event to Terminal is sent by an `osascript` child process, run off the main thread and
/// terminated after `timeoutSeconds`, so a hung or prompting Terminal never stalls the panel or leaves
/// a stuck thread behind; any error, timeout or busy worker → not focused.
@MainActor
final class TerminalFocus {
    /// The osascript process is terminated after this long.
    nonisolated static let timeoutSeconds: Double = 1
    /// The caller stops waiting after this long even if the worker never reports (it always should:
    /// the process is terminated, then killed); the margin covers launching and reaping the process.
    static let watchdogSeconds: Double = timeoutSeconds + 0.5
    static let workerResetSeconds: Double = 5

    private let log: JarvisLog
    private var worker = SelectedTtyWorker()
    private var loggedReset = false
    /// Each failure code is logged once per app run.
    private var loggedFailures: Set<String> = []

    init(log: JarvisLog) { self.log = log }

    func decide(_ r: JarvisRequest) async -> FocusDecision {
        // No Apple Event unless it can matter: an unknown session tty or another app in front is
        // never focused. Requiring Terminal to be frontmost also means the script never launches it.
        guard !r.tty.isEmpty, Self.terminalIsFrontmost() else { return .show }
        // No consent yet (or denied): never run the script, so no prompt can race the panel.
        guard TerminalAutomation.status(askUser: false) == noErr else { return .show }
        let selected = await selectedTty()
        // He may have switched apps while Terminal answered: both readings must say Terminal.
        return FocusRule.decide(kind: r.kind, info: r.info, frontmostIsTerminal: Self.terminalIsFrontmost(),
                                selectedTty: selected, requestTty: r.tty)
    }

    private static func terminalIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == FocusRule.terminalBundleId
    }

    /// "/dev/ttysNNN" of Terminal's front window's selected tab; nil on any failure.
    private func selectedTty() async -> String? {
        if worker.busyFor(atLeast: Self.workerResetSeconds) {
            // Safety net: the osascript process is terminated, then killed, so the worker should never
            // stay busy this long; if it does, abandon it and let its queue finish on its own.
            worker = SelectedTtyWorker()
            if !loggedReset { loggedReset = true; log.append("focus: worker reset") }
        }
        let worker = self.worker
        let outcome: SelectedTtyWorker.Outcome = await withCheckedContinuation { c in
            let once = ResumeOnce(c)
            worker.run { once.resume($0) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.watchdogSeconds) {
                once.resume(.failed("watchdog"))
            }
        }
        switch outcome {
        case .tty(let tty):
            return tty
        case .failed(let code):
            if loggedFailures.insert(code).inserted { log.append("focus: check failed \(code)") }
            return nil
        }
    }
}

private final class TokenBox: @unchecked Sendable { var token: NSObjectProtocol? }

/// The Automation (Apple Events) consent for controlling Terminal.
enum TerminalAutomation {
    /// `askUser: true` may block on the system consent prompt; call it only off the main thread.
    static func status(askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: FocusRule.terminalBundleId)
        guard let desc = target.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), askUser)
    }

    static func describe(_ status: OSStatus) -> String {
        switch Int(status) {
        case Int(noErr): return "granted"
        case -1743: return "denied"
        case -600: return "terminal not running"
        case -1744: return "requires user consent (-1744)"
        default: return "code \(status)"
        }
    }

    /// Asks for consent once at launch (no timeout, no panel up). If Terminal is not running,
    /// retries once the next time Terminal becomes frontmost; at most one retry per app run.
    @MainActor
    static func requestAtLaunch(log: JarvisLog) {
        ask(log: log) { code in
            guard code == -600 else { return }
            let box = TokenBox()
            box.token = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == FocusRule.terminalBundleId else { return }
                if let t = box.token { NSWorkspace.shared.notificationCenter.removeObserver(t); box.token = nil }
                ask(log: log) { _ in }
            }
        }
    }

    private static func ask(log: JarvisLog, then: @escaping @Sendable (Int) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let code = status(askUser: true)
            log.append("focus: automation permission \(describe(code))")
            DispatchQueue.main.async { then(Int(code)) }
        }
    }
}

/// Resumes a continuation exactly once, whichever of the script or the timeout finishes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SelectedTtyWorker.Outcome, Never>?

    init(_ c: CheckedContinuation<SelectedTtyWorker.Outcome, Never>) { continuation = c }

    func resume(_ outcome: SelectedTtyWorker.Outcome) {
        let c: CheckedContinuation<SelectedTtyWorker.Outcome, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: outcome)
    }
}

/// Runs osascript on one private serial queue, at most one at a time. A call made while an earlier one
/// is still running fails at once as "busy" instead of piling up behind it.
///
/// Why a child process instead of NSAppleScript: an in-process Apple Event that hangs (e.g. on a
/// consent prompt or a wedged Terminal) cannot be cancelled and keeps its thread forever; a process
/// can be terminated. TCC attributes the child's Apple Events to its responsible process, which for a
/// process Jarvis spawns (no responsibility disclaim) is Jarvis itself, so the same Automation consent
/// that `TerminalAutomation` checks applies.
private final class SelectedTtyWorker: @unchecked Sendable {
    enum Outcome: Sendable {
        case tty(String)
        case failed(String)
    }

    private static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    private static let source = #"tell application "Terminal" to tty of selected tab of front window"#
    /// After `terminate()` (SIGTERM), osascript gets this long to exit before it is killed.
    private static let killGraceSeconds: Double = 0.2

    private let queue = DispatchQueue(label: "local.jarvis.terminal-focus")
    private let lock = NSLock()
    private var busySince: Date?

    func run(_ done: @escaping @Sendable (Outcome) -> Void) {
        let start = lock.withLock { () -> Bool in
            guard busySince == nil else { return false }
            busySince = Date()
            return true
        }
        guard start else { done(.failed("busy")); return }
        queue.async { [self] in
            let outcome = Self.execute(timeout: TerminalFocus.timeoutSeconds)
            lock.withLock { busySince = nil }
            done(outcome)
        }
    }

    func busyFor(atLeast seconds: Double) -> Bool {
        lock.withLock { busySince.map { Date().timeIntervalSince($0) > seconds } ?? false }
    }

    /// Blocks this worker queue (never the main thread) for at most about `timeout` plus the kill grace.
    private static func execute(timeout: Double) -> Outcome {
        let process = Process()
        process.executableURL = osascript
        process.arguments = ["-e", source]
        let out = Pipe()
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failed("launch")
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + killGraceSeconds) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + killGraceSeconds)
            }
            return .failed("timeout")
        }
        // The process has exited, so its end of each pipe is closed: these reads end at EOF.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            return .failed(errorCode(errors) ?? "exit \(process.terminationStatus)")
        }
        let tty = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return tty.isEmpty ? .failed("empty") : .tty(tty)
    }

    /// The AppleScript error number osascript ends its message with, e.g. "... (-1743)"; never the text.
    private static func errorCode(_ stderr: Data) -> String? {
        let text = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let inner = text[text.index(after: open)..<text.index(before: text.endIndex)]
        guard !inner.isEmpty, inner.count <= 8, Int(inner) != nil else { return nil }
        return String(inner)
    }
}

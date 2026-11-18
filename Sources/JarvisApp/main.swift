import AppKit
import AVFoundation
import Foundation
import JarvisCore
import Speech

/// Authorisation requests. Kept off the main actor: the system calls these handlers on its own queues.
enum Permissions {
    static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status) }
        }
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in c.resume(returning: granted) }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = JarvisPaths.standard(home: FileManager.default.homeDirectoryForCurrentUser.path)
    private lazy var log = JarvisLog(path: paths.log)
    private var lockFD: Int32 = -1
    private var server: SocketServer?
    private var menu: StatusMenu?
    private var conversation: AppConversation?
    private var ofisPoller: OfisPoller?
    private var quiet: QuietControl?
    /// "Ofis kararlarını sor" changes reach the poller strictly in click order.
    private var ofisChain: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: a second app would otherwise unlink and replace the live socket.
        guard acquireInstanceLock() else { exit(1) }

        let desk = OfisDesk()
        let conversation = AppConversation(speaker: Speaker(log: log), listener: Listener(log: log),
                                           panel: PanelController(), log: log, desk: desk)
        self.conversation = conversation
        let queue = RequestQueue(conversation: conversation)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let poller = OfisPoller(client: OfisClient(keyPath: OfisClient.standardKeyPath(home: home), log: log),
                                queue: queue, desk: desk, log: log, seenPath: OfisSeen.path(in: paths))
        ofisPoller = poller

        let server = SocketServer(path: paths.socket) { request in await queue.submit(request) }
        do {
            try server.start()
        } catch {
            log.append("app start failed: socket server: \(error)")
            exit(1)
        }
        self.server = server

        // Quiet mode ("Rahatsız etme"): the menu shows it, the conversation ends the ask on screen when it
        // comes on, and the office is polled at once (after the resume sentence) when it ends.
        let quiet = QuietControl(queue: queue, desk: desk, log: log, onChange: { [weak self] mode in
            self?.menu?.quietChanged(mode)
        }, onConversation: { [weak conversation] mode in
            conversation?.quietChanged(mode)
        }, onResumed: {
            await poller.pollNow()
        })
        self.quiet = quiet

        let ofisAsking = StatusMenu.ofisAskingSetting
        menu = StatusMenu(queue: queue, log: log, ofisAsking: ofisAsking, onMuted: { [weak conversation] muted in
            // Muting also silences a spoken conversation that is already under way (handed to the terminal).
            conversation?.muteChanged(muted)
        }, onOfisAsking: { [weak self] on in
            self?.setOfisAsking(on, desk: desk, poller: poller)
        }, onOfisStatus: {
            Task { await poller.showStatus() }
        }, onQuiet: { [weak quiet] until in
            quiet?.turnOn(until: until)
        }, onResume: { [weak quiet] in
            quiet?.end()
        })
        setOfisAsking(ofisAsking, desk: desk, poller: poller)
        log.append("app started")
        TerminalAutomation.requestAtLaunch(log: log)

        Task {
            let speech = await Permissions.requestSpeech()
            let mic = await Permissions.requestMicrophone()
            if speech != .authorized || !mic {
                log.append("authorisation missing: speech=\(speech.rawValue) microphone=\(mic)")
            }
        }
    }

    private func setOfisAsking(_ on: Bool, desk: OfisDesk, poller: OfisPoller) {
        desk.asking = on
        let previous = ofisChain
        ofisChain = Task {
            await previous?.value
            await poller.setEnabled(on)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    /// Holds an exclusive `flock` on ~/.jarvis/app.lock for the life of the process.
    /// The kernel releases it when the process exits, so a crash never leaves a stale lock.
    /// Logs the reason on failure.
    private func acquireInstanceLock() -> Bool {
        mkdir(paths.dir, 0o700)
        let fd = open(paths.dir + "/app.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let e = errno
            log.append("app start failed: instance lock open failed: errno \(e)")
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            log.append("app start failed: another instance is running")
            return false
        }
        lockFD = fd
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

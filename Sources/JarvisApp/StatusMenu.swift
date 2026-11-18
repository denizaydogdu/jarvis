import AppKit
import JarvisCore
import ServiceManagement

/// Menu-bar item: "Sessiz" (mute), "Rahatsız etme" (quiet mode: "30 dakika", "1 saat", "Bugün", and
/// "Kapat" while on), while quiet the disabled "Sessiz: 21:45'e kadar" line and "Devam et", "Girişte başlat"
/// (launch at login), the office items ("Ofis durumu", "Ofis kararlarını sor", the disabled "Ofise iş ver
/// (yakında)") and "Çıkış" (quit). While quiet the icon is a moon with the missed count beside it.
/// Sessiz and Rahatsız etme are independent: Sessiz still shows the panel, quiet mode shows nothing.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let queue: RequestQueue
    private let log: JarvisLog
    private let onMuted: (Bool) -> Void
    private let onOfisAsking: (Bool) -> Void
    private let onOfisStatus: () -> Void
    private let onQuiet: (Date?) -> Void
    private let onResume: () -> Void
    private let muteItem = NSMenuItem(title: "Sessiz", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Girişte başlat", action: nil, keyEquivalent: "")
    private let ofisStatusItem = NSMenuItem(title: "Ofis durumu", action: nil, keyEquivalent: "")
    private let ofisAskItem = NSMenuItem(title: "Ofis kararlarını sor", action: nil, keyEquivalent: "")
    /// Shown disabled until the gate offers job adding.
    private let ofisJobItem = NSMenuItem(title: "Ofise iş ver (yakında)", action: nil, keyEquivalent: "")
    private let quietItem = NSMenuItem(title: "Rahatsız etme", action: nil, keyEquivalent: "")
    private let quietOffItem = NSMenuItem(title: "Kapat", action: nil, keyEquivalent: "")
    /// "Sessiz: 21:45'e kadar"; shown disabled, only while quiet.
    private let quietStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Devam et", action: nil, keyEquivalent: "")
    private var muted = false
    private var ofisAsking: Bool
    /// The queue's quiet mode as last reported by `QuietControl`.
    private var quiet = QuietMode()

    /// UserDefaults key of "Ofis kararlarını sor"; on by default.
    static let ofisAskingKey = "ofisKararlariniSor"

    static var ofisAskingSetting: Bool {
        UserDefaults.standard.object(forKey: ofisAskingKey) as? Bool ?? true
    }
    /// Mute changes are applied to the queue strictly in click order.
    private var muteChain: Task<Void, Never>?

    init(queue: RequestQueue, log: JarvisLog, ofisAsking: Bool, onMuted: @escaping (Bool) -> Void,
         onOfisAsking: @escaping (Bool) -> Void, onOfisStatus: @escaping () -> Void,
         onQuiet: @escaping (Date?) -> Void, onResume: @escaping () -> Void) {
        self.queue = queue
        self.log = log
        self.ofisAsking = ofisAsking
        self.onMuted = onMuted
        self.onOfisAsking = onOfisAsking
        self.onOfisStatus = onOfisStatus
        self.onQuiet = onQuiet
        self.onResume = onResume
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        muteItem.target = self
        muteItem.action = #selector(toggleMute)
        loginItem.target = self
        loginItem.action = #selector(toggleLogin)
        let quitItem = NSMenuItem(title: "Çıkış", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        ofisStatusItem.target = self
        ofisStatusItem.action = #selector(showOfisStatus)
        ofisAskItem.target = self
        ofisAskItem.action = #selector(toggleOfisAsking)
        // No action: the menu shows it disabled.
        ofisJobItem.isEnabled = false
        menu.addItem(muteItem)
        menu.addItem(makeQuietItem())
        quietStatusItem.isEnabled = false
        menu.addItem(quietStatusItem)
        resumeItem.target = self
        resumeItem.action = #selector(resume)
        menu.addItem(resumeItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(ofisStatusItem)
        menu.addItem(ofisAskItem)
        menu.addItem(ofisJobItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        item.menu = menu
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    /// Quiet mode changed (on, off, its end moved, or a request missed).
    func quietChanged(_ mode: QuietMode) {
        quiet = mode
        refresh()
    }

    /// The "Rahatsız etme" submenu: "30 dakika", "1 saat", "Bugün", and "Kapat" while on.
    private func makeQuietItem() -> NSMenuItem {
        let sub = NSMenu()
        for (title, action) in [("30 dakika", #selector(quietHalfHour)), ("1 saat", #selector(quietHour)),
                                ("Bugün", #selector(quietToday))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            sub.addItem(entry)
        }
        quietOffItem.target = self
        quietOffItem.action = #selector(resume)
        sub.addItem(quietOffItem)
        quietItem.submenu = sub
        return quietItem
    }

    private func refresh() {
        muteItem.state = muted ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        ofisAskItem.state = ofisAsking ? .on : .off
        let line = QuietStatus.menuLine(quiet)
        quietItem.state = line != nil ? .on : .off
        quietOffItem.isHidden = line == nil
        quietStatusItem.title = line ?? ""
        quietStatusItem.isHidden = line == nil
        resumeItem.isHidden = line == nil
        let symbol = quiet.isOn ? "moon.zzz" : muted ? "speaker.slash" : "waveform"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jarvis")
        image?.isTemplate = true
        item.button?.image = image
        let count = QuietStatus.countTitle(quiet)
        item.button?.title = count
        item.button?.imagePosition = count.isEmpty ? .imageOnly : .imageLeading
    }

    @objc private func quietHalfHour() { onQuiet(Date().addingTimeInterval(QuietMode.defaultSeconds)) }

    @objc private func quietHour() { onQuiet(Date().addingTimeInterval(60 * 60)) }

    @objc private func quietToday() { onQuiet(QuietMode.endOfToday(now: Date())) }

    @objc private func resume() { onResume() }

    @objc private func toggleMute() {
        muted.toggle()
        let value = muted
        let previous = muteChain
        let queue = self.queue
        let onMuted = self.onMuted
        // The queue is muted before the active ask is interrupted, so the next queued request
        // can never start speaking in between. This Task runs on the main actor.
        muteChain = Task {
            await previous?.value
            await queue.setMuted(value)
            onMuted(value)
        }
        log.append(value ? "muted" : "unmuted")
        refresh()
    }

    @objc private func showOfisStatus() {
        onOfisStatus()
    }

    @objc private func toggleOfisAsking() {
        ofisAsking.toggle()
        UserDefaults.standard.set(ofisAsking, forKey: Self.ofisAskingKey)
        onOfisAsking(ofisAsking)
        refresh()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            log.append("launch-at-login change failed: \(error.localizedDescription)")
        }
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

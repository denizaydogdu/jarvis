import AppKit
import JarvisCore
import SwiftUI

/// A panel that can never take keyboard focus or activate the app.
/// Clicks outside a button do nothing (v1's "click anywhere → handoff" is gone; `Terminal` replaces it).
final class JarvisPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets the first click act on a non-key, non-activating panel instead of being swallowed.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Everything the panel shows for one moment of an ask. A value, so measuring and drawing see the same thing.
struct PanelContent {
    var project = ""
    var body = ""
    var question = ""
    var detail = ""
    var buttons: [AnswerButton] = []
    /// A multiple-choice question's options: `.option(i)` shows label `i` with its description.
    var options: [ChoiceOption] = []
    /// False for an office ask: its option labels are already "A) …".
    var numberedOptions = true
    var state: CatState = .idle
    /// False while the panel is hidden: the cat's animation timeline is paused.
    var active = false
    /// Changes once per `onButton` assignment (one ask); resets button state such as a hold in progress.
    var generation = 0
    /// The handler captured when this content was built, so a press can only ever reach the ask it was shown for.
    var onButton: (@MainActor (AnswerButton) -> Void)?
}

/// Shows the cat, the text and the answer buttons at the right edge of the main screen, vertically centred.
/// Width is fixed; height follows the content, capped at half the visible screen height.
@MainActor
final class PanelController {
    static let width: CGFloat = 380
    static let edgeMargin: CGFloat = 12
    static let maxScreenFraction: CGFloat = 0.5
    /// Buttons ignore presses for this long after a new ask appears (a double click or a late click
    /// meant for the previous ask must not answer this one).
    static let inertSeconds: TimeInterval = 0.6

    /// Called with the pressed button. Set once per ask, before `show`.
    var onButton: (@MainActor (AnswerButton) -> Void)? {
        didSet { generation += 1 }
    }

    private var generation = 0
    /// Uptime (the `NSEvent.timestamp` clock) at which the current ask's panel appeared.
    private var shownAt: TimeInterval = .infinity
    private var shownGeneration = -1
    /// Uptime of the last left mouse-down inside the panel, recorded by a local event monitor.
    private var lastMouseDownAt: TimeInterval?
    private var hiddenAt: TimeInterval?
    private var mouseMonitor: Any?
    private var content = PanelContent()
    private lazy var host = FirstClickHostingView(rootView: PanelCard(content: content, height: nil))
    private lazy var measurer = NSHostingController(rootView: PanelCard(content: content, height: nil))
    private lazy var panel: JarvisPanel = makePanel()

    /// Seconds since the panel was last hidden; infinite before the first hide.
    var secondsSinceHidden: TimeInterval {
        hiddenAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
    }

    func show(project: String, body: String, question: String, detail: String,
              buttons: [AnswerButton], options: [ChoiceOption] = [], numberedOptions: Bool = true, state: CatState) {
        installMouseMonitor()
        // A new ask (or a re-appearing panel) restarts the inert window; a state change within one ask does not.
        if generation != shownGeneration || !panel.isVisible {
            shownAt = ProcessInfo.processInfo.systemUptime
            shownGeneration = generation
        }
        // Only a press with a recorded mouse-down counts; there is no accessibility path (see HoldToConfirmButton).
        var gated: (@MainActor (AnswerButton) -> Void)?
        if let handler = onButton {
            gated = { [weak self] (b: AnswerButton) in
                guard let self, self.acceptsPress() else { return }
                handler(b)
            }
        }
        content = PanelContent(project: project, body: body, question: question, detail: detail,
                               buttons: buttons, options: options, numberedOptions: numberedOptions, state: state,
                               active: true, generation: generation, onButton: gated)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = fittedHeight(maxHeight: floor(visible.height * Self.maxScreenFraction))
        host.rootView = PanelCard(content: content, height: height)
        let size = NSSize(width: Self.width, height: height)
        let origin = NSPoint(x: visible.maxX - size.width - Self.edgeMargin, y: visible.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
        // Never makeKey / activate: the user's terminal keeps keyboard focus.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        hiddenAt = ProcessInfo.processInfo.systemUptime
        content.state = .idle
        content.active = false
        content.onButton = nil
        host.rootView = PanelCard(content: content, height: nil)
    }

    /// A press counts only when the inert window has passed and its mouse-down happened after the panel
    /// appeared. No recorded mouse-down (e.g. a press without a mouse) is ignored: voice or Terminal remain.
    private func acceptsPress() -> Bool {
        guard inertWindowPassed() else { return false }
        guard let down = lastMouseDownAt, down >= shownAt else { return false }
        return true
    }

    /// The panel has been up for at least `inertSeconds` in the current ask.
    private func inertWindowPassed() -> Bool {
        ProcessInfo.processInfo.systemUptime - shownAt >= Self.inertSeconds
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if event.window is JarvisPanel {
                let t = event.timestamp
                MainActor.assumeIsolated { self?.lastMouseDownAt = t }
            }
            return event
        }
    }

    /// The content's natural height at the fixed width, capped; above the cap the body scrolls.
    private func fittedHeight(maxHeight: CGFloat) -> CGFloat {
        var probe = content
        probe.active = false
        measurer.rootView = PanelCard(content: probe, height: nil)
        let natural = measurer.sizeThatFits(in: CGSize(width: Self.width, height: 100_000)).height
        return min(ceil(natural), maxHeight)
    }

    private func makePanel() -> JarvisPanel {
        let p = JarvisPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        // The app is never active (accessory, non-activating panel): without this no tooltip shows.
        p.allowsToolTipsWhenApplicationIsInactive = true
        p.becomesKeyOnlyIfNeeded = true
        p.isFloatingPanel = true
        p.isReleasedWhenClosed = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .utilityWindow
        // The window frame is set explicitly in `show`; the hosting view must not resize it.
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }
}

// MARK: - Views (8 pt grid, corner radius 12, neutral + orange accent, red only for "Hayır")

private struct PanelCard: View {
    /// The cat's height in the header; it is drawn at `CatView.size` and scaled down to this.
    static let catHeight: CGFloat = 64
    static var catScale: CGFloat { catHeight / CatView.size.height }

    let content: PanelContent
    /// nil: natural height (measuring), the whole body laid out flat. Otherwise the exact height; the
    /// body scrolls, so the question line and the buttons always stay visible.
    let height: CGFloat?

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 8) {
            header
            // The full text, full width: nothing flows beside the cat, so no sentence is ever cut.
            if !content.body.isEmpty {
                if height == nil {
                    bodyText(content.body)
                } else {
                    ScrollView(.vertical) { bodyText(content.body) }
                        .scrollIndicators(.automatic)
                }
            }
            if !content.question.isEmpty {
                Text(content.question)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !content.detail.isEmpty {
                Text(content.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06)))
            }
            // Takes any slack after the scroll body, so the buttons stay pinned to the bottom.
            Spacer(minLength: 0)
                .layoutPriority(-2)
            if !content.buttons.isEmpty {
                AnswerButtonsRow(buttons: content.buttons, options: content.options,
                                 outlined: content.state == .silent, onButton: content.onButton,
                                 numbered: content.numberedOptions)
                    .id(content.generation)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(width: PanelController.width, alignment: .topLeading)

        Group {
            if let height {
                card.frame(height: height, alignment: .top)
            } else {
                card.fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One header row: the project caption (and the Sessiz label) on the left, the cat on the right.
    /// No body text sits beside the cat.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(content.project)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !copyText.isEmpty {
                        CopyButton(text: copyText).id(content.generation)
                    }
                }
                if content.state == .listening {
                    // Tells the user that Jarvis hears them now: speak the answer.
                    Label {
                        Text("Dinliyorum").foregroundStyle(.primary)
                    } icon: {
                        SoundWave(active: content.active, barCount: 4, barWidth: 2, maxHeight: 11)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                if content.state == .silent {
                    // Tells the user that Jarvis is not listening: answer with a button.
                    // Primary text stays legible in light mode; only the icon carries the accent.
                    Label {
                        Text("Sessiz").foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "speaker.slash.fill").foregroundStyle(Palette.accent)
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CatView(state: content.state, active: content.active)
                .scaleEffect(Self.catScale)
                .frame(width: CatView.size.width * Self.catScale, height: Self.catHeight)
                .overlay(alignment: .top) {
                    if content.state == .listening {
                        // A small wave bubble over the cat's head while the microphone is open.
                        SoundWave(active: content.active, barCount: 5, barWidth: 2.5, maxHeight: 10)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
                            .overlay(Capsule().stroke(Palette.accent.opacity(0.6), lineWidth: 1))
                            .offset(y: -14)
                            .accessibilityHidden(true)
                    }
                }
        }
    }

    private var copyText: String {
        PanelCopy.text(body: content.body, question: content.question, detail: content.detail,
                       options: content.options, numberedOptions: content.numberedOptions)
    }
}

/// Puts the card's text on the clipboard; the icon turns into a check mark for a moment.
/// A plain SwiftUI button outside `onButton`: it never answers the ask and needs no inert window.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Palette.accent : .secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Metni kopyala")
        .accessibilityLabel(Text(copied ? "Kopyalandı" : "Metni kopyala"))
    }
}

/// Orange equaliser bars that rise and fall: "the microphone is open". Paused while the panel is hidden.
private struct SoundWave: View {
    let active: Bool
    let barCount: Int
    let barWidth: CGFloat
    let maxHeight: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: barWidth) {
                ForEach(0..<barCount, id: \.self) { i in
                    let level = 0.5 + 0.5 * sin(t * 7 + Double(i) * 1.3) * cos(t * 2.1 + Double(i) * 0.7)
                    Capsule().fill(Palette.accent)
                        .frame(width: barWidth, height: max(barWidth, maxHeight * (0.25 + 0.75 * level)))
                }
            }
            .frame(height: maxHeight)
        }
    }
}

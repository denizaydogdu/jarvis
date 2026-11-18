import AppKit
import JarvisCore
import SwiftUI

// MARK: - Answer buttons (8 pt grid, corner radius 8, neutral + orange accent, red only for "Hayır")

struct AnswerButtonsRow: View {
    let buttons: [AnswerButton]
    let options: [ChoiceOption]
    /// Silent (Sessiz) ask: a subtle orange outline shows that the panel waits for a click.
    let outlined: Bool
    let onButton: (@MainActor (AnswerButton) -> Void)?
    /// False for office asks, whose labels are already "A) …": no "1." number in front.
    var numbered = true

    /// Option buttons stack full width, one per row (label plus description); the rest share a row below.
    var body: some View {
        let optionButtons = buttons.filter { if case .option = $0 { return true } else { return false } }
        let others = buttons.filter { if case .option = $0 { return false } else { return true } }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(optionButtons, id: \.self) { b in
                if case .option(let i) = b, options.indices.contains(i) {
                    Button { onButton?(b) } label: { OptionLabel(text: AnswerButton.optionText(i, label: options[i].label, numbered: numbered),
                                                              description: options[i].description) }
                        .buttonStyle(OptionButtonStyle())
                }
            }
            if !others.isEmpty { row(others) }
        }
        // Drawn just outside the row, inside the card's padding: the layout (and so the measured
        // panel height) is the same with or without it.
        .overlay {
            if outlined {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Palette.accent.opacity(0.55), lineWidth: 1.5)
                    .padding(-Self.outlineInset)
                    .allowsHitTesting(false)
            }
        }
    }

    static let outlineInset: CGFloat = 4

    private func row(_ buttons: [AnswerButton]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(buttons, id: \.self) { b in
                if b.requiresHold {
                    VStack(spacing: 4) {
                        HoldToConfirmButton(title: b.title, action: { onButton?(b) })
                        Text("basılı tut")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(b.title) { onButton?(b) }
                        .buttonStyle(AnswerButtonStyle(kind: Self.kind(of: b)))
                }
            }
        }
    }

    static func kind(of b: AnswerButton) -> AnswerButtonStyle.Kind {
        switch b {
        case .yes, .confirm, .ok: return .prominent
        case .no: return .destructive
        case .done, .option, .cancel: return .secondary
        case .terminal, .notNow: return .plain
        }
    }
}

/// "1. Label" (or the office's "A) Label") with the option's description below it, shown but never spoken.
private struct OptionLabel: View {
    let text: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The label of a one-line answer button: font, single line, colour and the 32 pt full-width frame.
/// `prominentAnswerLabel()` is the accent-button variant shared by `AnswerButtonStyle` and `HoldToConfirmButton`.
/// Four buttons share the 348 pt row (about 81 pt each, e.g. `Onaylıyorum`, `Hayır`, `Konuşamam`,
/// `Terminal`): a title that does not fit shrinks a little instead of being cut.
struct AnswerLabel: ViewModifier {
    let foreground: Color

    func body(content: Content) -> some View {
        content
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 32)
    }
}

extension View {
    func answerLabel(foreground: Color) -> some View { modifier(AnswerLabel(foreground: foreground)) }
    func prominentAnswerLabel() -> some View { answerLabel(foreground: Palette.onAccent) }
}

struct AnswerButtonStyle: ButtonStyle {
    enum Kind { case prominent, secondary, destructive, plain }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .answerLabel(foreground: foreground)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    private var foreground: Color {
        switch kind {
        case .prominent: return Palette.onAccent
        case .secondary: return .primary
        case .destructive: return .red
        case .plain: return .secondary
        }
    }

    private var background: Color {
        switch kind {
        case .prominent: return Palette.accent
        case .secondary, .destructive: return Color.primary.opacity(0.08)
        case .plain: return .clear
        }
    }
}

/// `Onaylıyorum`: fires only after being held for `holdSeconds`; a darker band sweeps across while held.
/// Releasing, the gesture being cancelled, or dragging off the button before then resets it and does
/// nothing; a hold that left the button stays cancelled until the mouse is released.
///
/// NO ACCESSIBILITY CONFIRM (controller ruling, v1.5): there is deliberately no accessibility action.
/// Any process with Accessibility rights (e.g. osascript / System Events run from a Terminal that has
/// them, so also a Claude session) could AXPress "Onaylıyorum" and send `ekranOnayi: true` or approve a
/// risky command without a human hold. VoiceOver users say "onaylıyorum" for a risky permission; a
/// high-risk office card stays answerable on the office page. `HoldConfirmPolicyTests` pins this.
struct HoldToConfirmButton: View {
    static let holdSeconds: Double = 1.0

    let title: String
    let action: @MainActor () -> Void

    @GestureState private var pressing = false
    @State private var progress: Double = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var fired = false
    @State private var size: CGSize = .zero
    /// Set when the pointer leaves the button during a press; cleared on release.
    @State private var abandoned = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Text(title)
            .prominentAnswerLabel()
            .background(
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        shape.fill(Palette.accent)
                        Rectangle().fill(Color.black.opacity(0.25)).frame(width: g.size.width * progress)
                    }
                    .onAppear { size = g.size }
                    .onChange(of: g.size) { _, s in size = s }
                }
            )
            .clipShape(shape)
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($pressing) { _, state, _ in state = true }
                .onChanged { value in
                    // Unknown size counts as outside: never fire without knowing the pointer is on the button.
                    let inside = size.width > 0 && size.height > 0
                        && CGRect(origin: .zero, size: size).contains(value.location)
                    if !inside { abandon() }
                })
            .onChange(of: pressing) { _, now in
                if now {
                    begin()
                } else {
                    cancel()
                    abandoned = false
                }
            }
            .onDisappear { cancel() }
            .accessibilityAddTraits(.isButton)
            // Only a physical 1 s hold confirms; see the type's comment (no accessibility confirm).
            .accessibilityHint(Text("1 saniye basılı tut"))
    }

    private func abandon() {
        abandoned = true
        cancel()
    }

    private func begin() {
        guard !fired, !abandoned, holdTask == nil else { return }
        withAnimation(.linear(duration: Self.holdSeconds)) { progress = 1 }
        let action = self.action
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.holdSeconds))
            // Belt and braces: the left button must still be down, even if a gesture end was missed.
            guard !Task.isCancelled, !abandoned, NSEvent.pressedMouseButtons & 1 != 0 else { return }
            fired = true
            holdTask = nil
            action()
        }
    }

    private func cancel() {
        holdTask?.cancel()
        holdTask = nil
        guard !fired else { return }
        withAnimation(.easeOut(duration: 0.15)) { progress = 0 }
    }
}

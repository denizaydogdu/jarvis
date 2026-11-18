import SwiftUI

enum CatState: Sendable, Equatable {
    case idle, speaking, listening, silent
}

/// Shared palette: one neutral family (the cat's warm greys), one orange accent.
enum Palette {
    static let accent = Color(red: 0.96, green: 0.56, blue: 0.20)
    static let onAccent = Color.black.opacity(0.85)
    static let fur = Color(red: 0.62, green: 0.58, blue: 0.55)
    static let furDark = Color(red: 0.43, green: 0.40, blue: 0.38)
    static let furLight = Color(red: 0.84, green: 0.81, blue: 0.78)
    static let eye = Color(red: 0.16, green: 0.14, blue: 0.13)
}

/// Jarvis's cat: an original design drawn with SwiftUI shapes only — a sitting, front-facing
/// warm-grey cat with orange inner ears, three orange forehead stripes, an orange collar with a
/// round tag and an orange-tipped curled tail.
/// - idle: slow blink, gentle breathing.
/// - speaking: mouth opens and closes, occasional blink.
/// - listening: ears perk up, round eyes, soft orange rings.
/// - silent: calm pose, eyes half-closed, slow breathing.
/// The animation timeline is paused while `active` is false (panel hidden).
struct CatView: View {
    static let size = CGSize(width: 110, height: 120)

    let state: CatState
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            figure(t: context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .accessibilityElement()
        .accessibilityLabel(Text("Jarvis"))
    }

    // MARK: - Figure (coordinates are offsets from the frame centre; y grows downward)

    private func figure(t: Double) -> some View {
        let breathe = state == .speaking ? 1.0 : 1 + 0.015 * sin(t * (state == .silent ? 1.0 : 1.6))
        return ZStack {
            if state == .listening { rings(t: t) }
            tail(t: t)
            torso(breathe: breathe)
            head(t: t)
        }
    }

    private func torso(breathe: Double) -> some View {
        ZStack {
            Ellipse().fill(Palette.fur).frame(width: 66, height: 50)
            Ellipse().fill(Palette.furLight).frame(width: 30, height: 30).offset(y: 6)
            Ellipse().fill(Palette.furLight).frame(width: 16, height: 10).offset(x: -14, y: 22)
            Ellipse().fill(Palette.furLight).frame(width: 16, height: 10).offset(x: 14, y: 22)
        }
        .scaleEffect(x: 1, y: breathe, anchor: .bottom)
        .offset(y: 34)
    }

    private func tail(t: Double) -> some View {
        let sway = state == .silent ? 2 * sin(t * 0.8) : 6 * sin(t * 1.4)
        return ZStack {
            TailShape().stroke(Palette.fur, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            TailShape().trim(from: 0.8, to: 1)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .rotationEffect(.degrees(sway), anchor: UnitPoint(x: 0.70, y: 0.92))
    }

    private func head(t: Double) -> some View {
        ZStack {
            ear(left: true)
            ear(left: false)
            Ellipse().fill(Palette.fur).frame(width: 76, height: 62)
            stripes.offset(y: -24)
            eyes(t: t).offset(y: -6)
            muzzle(t: t).offset(y: 10)
            whiskers.offset(y: 10)
            collar.offset(y: 28)
        }
        .offset(y: -8)
    }

    // MARK: - Parts

    private func ear(left: Bool) -> some View {
        let perked = state == .listening
        let sign: Double = left ? -1 : 1
        let tilt = sign * (perked ? 4 : 16)
        return ZStack {
            EarShape().fill(Palette.fur).frame(width: 26, height: 28)
            EarShape().fill(Palette.accent.opacity(0.85)).frame(width: 14, height: 16).offset(y: 4)
        }
        .rotationEffect(.degrees(tilt), anchor: .bottom)
        .offset(x: sign * 23, y: perked ? -32 : -26)
    }

    private var stripes: some View {
        HStack(spacing: 4) {
            Capsule().fill(Palette.accent).frame(width: 3, height: 7)
            Capsule().fill(Palette.accent).frame(width: 3, height: 10)
            Capsule().fill(Palette.accent).frame(width: 3, height: 7)
        }
    }

    private func eyes(t: Double) -> some View {
        HStack(spacing: 20) {
            eye(t: t)
            eye(t: t)
        }
    }

    @ViewBuilder
    private func eye(t: Double) -> some View {
        switch state {
        case .idle:
            // Slow blink: closed for about half a second every five seconds (open at t = 0).
            let phase = t.truncatingRemainder(dividingBy: 5)
            let openness = phase > 4.5 ? abs(cos((phase - 4.5) / 0.5 * .pi)) : 1
            Capsule().fill(Palette.eye).frame(width: 9, height: max(2, 12 * openness))
        case .speaking:
            let blink = t.truncatingRemainder(dividingBy: 3.4) > 3.28
            Capsule().fill(Palette.eye).frame(width: 9, height: blink ? 2 : 12)
        case .listening:
            Circle().fill(Palette.eye).frame(width: 13, height: 13)
                .overlay(Circle().fill(Palette.furLight).frame(width: 4, height: 4).offset(x: 2, y: -2))
        case .silent:
            HalfEye().fill(Palette.eye).frame(width: 11, height: 6).offset(y: 3)
        }
    }

    private func muzzle(t: Double) -> some View {
        ZStack {
            Ellipse().fill(Palette.furLight).frame(width: 17, height: 13).offset(x: -7, y: 3)
            Ellipse().fill(Palette.furLight).frame(width: 17, height: 13).offset(x: 7, y: 3)
            NoseShape().fill(Palette.accent).frame(width: 8, height: 6).offset(y: -2)
            mouth(t: t).offset(y: 7)
        }
    }

    @ViewBuilder
    private func mouth(t: Double) -> some View {
        if state == .speaking {
            let open = 2 + 6 * abs(sin(t * 9) * cos(t * 2.3))
            Ellipse().fill(Palette.furDark).frame(width: 8, height: open).offset(y: open / 2 - 1)
        } else {
            MouthShape().stroke(Palette.furDark, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: 12, height: 4)
        }
    }

    private var whiskers: some View {
        WhiskersShape().stroke(Palette.furDark.opacity(0.8), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            .frame(width: 96, height: 14)
    }

    private var collar: some View {
        ZStack {
            Capsule().fill(Palette.accent).frame(width: 40, height: 6)
            Circle().fill(Palette.accent).frame(width: 7, height: 7).offset(y: 6)
        }
    }

    /// Soft rings spreading from the head: "I'm listening".
    private func rings(t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let p = (t * 0.6 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Circle()
                    .stroke(Palette.accent.opacity(0.7 * (1 - p)), lineWidth: 2.5)
                    .frame(width: 74 + 34 * p, height: 74 + 34 * p)
            }
        }
        .offset(y: -10)
    }
}

// MARK: - Shapes

/// A pointed ear with a slightly rounded tip.
private struct EarShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX - r.width * 0.08, y: r.minY + r.height * 0.06))
        p.addQuadCurve(to: CGPoint(x: r.midX + r.width * 0.08, y: r.minY + r.height * 0.06),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.02))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A small rounded downward triangle.
private struct NoseShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.6))
        return p
    }
}

/// A closed "w" mouth.
private struct MouthShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.minX + r.width / 4, y: r.maxY * 1.4))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - r.width / 4, y: r.maxY * 1.4))
        return p
    }
}

/// A half-closed eye: a gently arched lid over the lower half of the eye — a calm look.
private struct HalfEye: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.3))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.3),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.2))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.3),
                       control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.6))
        p.closeSubpath()
        return p
    }
}

/// Three whiskers per side, leaving a gap for the muzzle.
private struct WhiskersShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let gap: CGFloat = 16
        for (i, dy) in [-1.0, 0.0, 1.0].enumerated() {
            let inner = r.midY + CGFloat(dy) * 3
            let outer = r.midY + CGFloat(dy) * 7 - 2 + CGFloat(i)
            p.move(to: CGPoint(x: r.midX - gap, y: inner))
            p.addLine(to: CGPoint(x: r.minX, y: outer))
            p.move(to: CGPoint(x: r.midX + gap, y: inner))
            p.addLine(to: CGPoint(x: r.maxX, y: outer))
        }
        return p
    }
}

/// The tail: rises from behind the body on the right and curls back inward at the tip.
/// Drawn in the full 110×120 frame.
private struct TailShape: Shape {
    func path(in r: CGRect) -> Path {
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: r.minX + x / 110 * r.width, y: r.minY + y / 120 * r.height)
        }
        var p = Path()
        p.move(to: pt(76, 110))
        p.addCurve(to: pt(104, 92), control1: pt(92, 112), control2: pt(104, 104))
        p.addCurve(to: pt(102, 72), control1: pt(104, 84), control2: pt(106, 76))
        p.addQuadCurve(to: pt(91, 74), control: pt(96, 66))
        return p
    }
}

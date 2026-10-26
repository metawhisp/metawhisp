import SwiftUI

/// Screen 1 of 4 — what MetaWhisp is, in one look, and one button (US1). Variant 1 (owner 2026-10-24): the voice
/// first, then what else it does. The mark forms from a voice; the words arrive after it, one part at a time.
struct WelcomeScreen: View {
    struct Chip {
        let symbol: String
        let title: String
    }

    static let title = "Speak instead of typing."
    static let subtitle = "Your words appear in the text field you’re in."
    static let chips = [Chip(symbol: "mic", title: "Dictation"), Chip(symbol: "globe", title: "Translation"),
                        Chip(symbol: "video", title: "Meeting notes"), Chip(symbol: "bubble.left", title: "MetaChat"),
                        Chip(symbol: "checklist", title: "Tasks")]
    static let start = "Get started"

    @ObservedObject var flow: OnboardingFlow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var began = Date()
    @State private var markDone = false
    @State private var glow = false
    @State private var wavesShown = false
    /// How many parts under the mark have arrived: the title, the line, five chips, the button.
    @State private var shown = 0

    var body: some View {
        OnboardingPage {
            VStack(spacing: 0) {
                ZStack {
                    OnboardingWaves(drifting: wavesShown && !reduceMotion)
                        .frame(width: OnboardingWindowController.size.width, height: 214)
                        .opacity(wavesShown ? 1 : 0)
                        .accessibilityHidden(true)
                    MWMarkView(began: began, finished: markDone)
                        .frame(width: 300, height: 207)
                        .shadow(color: Color.primary.opacity(glow ? 0.55 : 0), radius: 11)
                        .accessibilityHidden(true)
                }
                .frame(width: OnboardingStyle.column, height: 214)
                OnboardingTitle(text: Self.title)
                    .padding(.top, 18)
                    .modifier(Arrival(shown: shown > 0))
                Text(Self.subtitle)
                    .font(OnboardingStyle.body)
                    .foregroundStyle(MW.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .modifier(Arrival(shown: shown > 1))
                HStack(spacing: 8) {
                    ForEach(Array(Self.chips.enumerated()), id: \.offset) { index, chip in
                        WelcomeChipView(chip: chip).modifier(Arrival(shown: shown > 2 + index))
                    }
                }
                .padding(.top, 20)
            }
        } leading: {
            EmptyView()
        } center: {
            Button { flow.next() } label: { ArrowLabel(text: Self.start) }
                .buttonStyle(CapsuleButtonStyle())
                .keyboardShortcut(.defaultAction)
                .modifier(Arrival(shown: shown > 7))
        }
        .task { await introduce() }
    }

    /// The mark forms (1.8 s), glows once, the waves come up behind it, then each part arrives 0.12 s after the
    /// last. Reduce Motion: the finished mark, and the parts fade in without moving.
    private func introduce() async {
        if !reduceMotion { try? await Task.sleep(for: .seconds(MWMark.duration)) }
        markDone = true
        if !reduceMotion {
            withAnimation(.easeOut(duration: 0.38)) { glow = true }
            Task {
                try? await Task.sleep(for: .milliseconds(380))
                withAnimation(.easeIn(duration: 0.72)) { glow = false }
            }
        }
        withAnimation(.easeOut(duration: 0.9)) { wavesShown = true }
        for part in 1...8 {
            withAnimation(.easeOut(duration: reduceMotion ? 0.1 : 0.28)) { shown = part }
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(120)) }
        }
    }
}

private struct WelcomeChipView: View {
    let chip: WelcomeScreen.Chip

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: chip.symbol)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(MW.textPrimary)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            Text(chip.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: 100)
    }
}

/// The MW mark, measured on the app icon (mockup v6 `MWL`): one line through eight points in a 290 × 200 box,
/// 21 wide, with 5.5-point rounded joins — and the intro that forms it from a voice (`mwIntro`).
enum MWMark {
    static let box = CGSize(width: 290, height: 200)
    static let points = [CGPoint(x: 16.5, y: 180), CGPoint(x: 56.75, y: 15.9), CGPoint(x: 90.3, y: 166.1),
                         CGPoint(x: 126.5, y: 15.8), CGPoint(x: 163.4, y: 185.1), CGPoint(x: 199.4, y: 35.6),
                         CGPoint(x: 233, y: 184.6), CGPoint(x: 273, y: 22)]
    static let strokeWidth: CGFloat = 21
    static let cornerRadius: CGFloat = 5.5
    /// The intro's length, in seconds.
    static let duration: TimeInterval = 1.8

    struct Frame: Equatable {
        /// The line as drawn, left to right.
        var points: [CGPoint]
        var width: CGFloat
        var opacity: Double
        /// The intro is over: the finished mark, with its rounded joins.
        var done: Bool
    }

    static let finished = Frame(points: points, width: strokeWidth, opacity: 1, done: true)

    /// The finished line's height at `x`, straight between the measured points.
    static func y(atX x: CGFloat) -> CGFloat {
        for index in 0..<(points.count - 1) where x <= points[index + 1].x {
            let a = points[index], b = points[index + 1]
            return a.y + (b.y - a.y) * max(0, x - a.x) / (b.x - a.x)
        }
        return points[points.count - 1].y
    }

    /// `t` seconds into the intro: silence, a flat line fading in (0.35 s); a voice, a wave that grows (to 1.05 s);
    /// the wave settling into M and W (to 1.8 s). Reduce Motion: the finished mark at once.
    static func frame(at t: TimeInterval, reduceMotion: Bool) -> Frame {
        guard !reduceMotion, t < duration else { return finished }
        let ms = CGFloat(t * 1000)
        let first = points[0].x, last = points[points.count - 1].x
        let xs = (0..<samples).map { first + (last - first) * CGFloat($0) / CGFloat(samples - 1) }
        let wave = { (x: CGFloat, shift: CGFloat) -> CGFloat in cos(2 * .pi * (x - 56.75) / 70 - shift) }
        if ms < 350 {
            return Frame(points: xs.map { CGPoint(x: $0, y: 100 + sin($0 * 0.9 + ms / 60) * 0.6) },
                         width: 2, opacity: min(1, ms / 250), done: false)
        }
        if ms < 1050 {
            let k = 1 - pow(1 - (ms - 350) / 700, 3)
            let shift = (1 - k) * 5.5 + sin(ms / 90) * 0.15 * (1 - k)
            return Frame(points: xs.map { x in
                CGPoint(x: x, y: 100 - 80 * k * wave(x, shift) + (1 - k) * sin(x * 0.7 + ms / 40) * 3)
            }, width: 2 + 5 * k, opacity: 1, done: false)
        }
        let p = (ms - 1050) / 750
        let k = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        return Frame(points: xs.map { x in
            let wavy = 100 - 80 * wave(x, 0)
            return CGPoint(x: x, y: wavy + (y(atX: x) - wavy) * k)
        }, width: 7 + (strokeWidth - 7) * k, opacity: 1, done: false)
    }

    private static let samples = 140

    /// The finished mark: the measured line, each join rounded with a quadratic curve.
    static let finishedPath: Path = {
        var path = Path()
        path.move(to: points[0])
        for index in 1..<(points.count - 1) {
            let a = points[index - 1], v = points[index], b = points[index + 1]
            let ua = CGPoint(x: a.x - v.x, y: a.y - v.y), ub = CGPoint(x: b.x - v.x, y: b.y - v.y)
            let la = hypot(ua.x, ua.y), lb = hypot(ub.x, ub.y)
            let half = acos((ua.x * ub.x + ua.y * ub.y) / (la * lb)) / 2
            let cut = cornerRadius / tan(half)
            path.addLine(to: CGPoint(x: v.x + ua.x / la * cut, y: v.y + ua.y / la * cut))
            path.addQuadCurve(to: CGPoint(x: v.x + ub.x / lb * cut, y: v.y + ub.y / lb * cut), control: v)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }()
}

/// Draws the mark's intro, then the finished mark, in the box's proportions.
private struct MWMarkView: View {
    let began: Date
    let finished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: finished || reduceMotion)) { context in
            Canvas { canvas, size in
                let frame = finished ? MWMark.finished
                    : MWMark.frame(at: context.date.timeIntervalSince(began), reduceMotion: reduceMotion)
                let scale = min(size.width / MWMark.box.width, size.height / MWMark.box.height)
                let fit = CGAffineTransform(translationX: (size.width - MWMark.box.width * scale) / 2,
                                            y: (size.height - MWMark.box.height * scale) / 2)
                    .scaledBy(x: scale, y: scale)
                var line = Path()
                line.addLines(frame.points)
                canvas.opacity = frame.opacity
                canvas.stroke((frame.done ? MWMark.finishedPath : line).applying(fit), with: .foreground,
                              style: StrokeStyle(lineWidth: frame.width * scale, lineCap: .butt, lineJoin: .round))
            }
        }
        .foregroundStyle(Color.primary.opacity(0.95))
    }
}

/// Dotted waves behind the mark — the site's motif, quiet; they drift slowly once the mark has formed.
private struct OnboardingWaves: View {
    /// Base line, height, waves per 240 pt, phase, opacity — in a 720 × 220 box.
    private static let lines: [(base: CGFloat, height: CGFloat, waves: CGFloat, phase: CGFloat, opacity: Double)] =
        [(78, 7, 1, 0.3, 0.16), (98, 11, 2, 1.4, 0.1), (116, 6, 1, 2.2, 0.14), (134, 9, 3, 0.9, 0.08), (150, 5, 2, 2.9, 0.12)]

    let drifting: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !drifting)) { context in
            Canvas { canvas, size in
                // One period of every line is 240 pt, so a 240 pt drift every 20 s loops without a seam.
                let drift = drifting ? CGFloat(context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 20) / 20) * 240 : 0
                let scale = CGSize(width: size.width / 720, height: size.height / 220)
                for line in Self.lines {
                    var path = Path()
                    for x in stride(from: CGFloat(0), through: 1440, by: 8) {
                        let point = CGPoint(x: (x - drift) * scale.width,
                                            y: (line.base + line.height * sin(2 * .pi * line.waves * x / 240 + line.phase))
                                                * scale.height)
                        if x == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    canvas.stroke(path, with: .color(Color.primary.opacity(line.opacity)),
                                  style: StrokeStyle(lineWidth: 1.1, lineCap: .round, dash: [1.4, 5]))
                }
            }
        }
    }
}

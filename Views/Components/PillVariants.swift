import SwiftUI

// MARK: - Shared Types

typealias PillStage = TranscriptionCoordinator.Stage

// MARK: - Bar Visualizer

struct BarVisualizer: View {
    let bars: [Float]
    var height: CGFloat = 20

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<bars.count, id: \.self) { i in
                Rectangle()
                    .fill(MW.textPrimary.opacity(Double(bars[i]) * 0.8 + 0.15))
                    .frame(width: 2, height: max(2, height * CGFloat(bars[i])))
                    .animation(.easeOut(duration: 0.06), value: bars[i])
            }
        }
        .frame(height: height)
    }
}

// MARK: - Shimmer Text (monochrome)

struct BlocksShimmerText: View {
    let text: String
    @State private var phase: CGFloat = 0

    var body: some View {
        Text(text)
            .font(MW.monoLg)
            .foregroundStyle(MW.textPrimary)
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, phase - 0.15)),
                            .init(color: MW.textPrimary.opacity(0.6), location: phase),
                            .init(color: .clear, location: min(1, phase + 0.15)),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width)
                    .mask(Text(text).font(MW.monoLg))
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
    }
}

// MARK: - 1. Capsule Pill

/// Default floating recording pill — Liquid Glass spec § 8 Capsule.
/// Glass pill with specular rim + state-coloured outer glow when active.
/// Layout: [colored dot] [bars (recording only)] [LABEL].
struct CapsulePillView: View {
    let stage: PillStage
    let isTranslating: Bool
    let audioLevel: Float
    let bars: [Float]

    @State private var appeared = false
    @State private var pulseDot = false
    @State private var displayedStage: PillStage = .idle

    private var isActive: Bool { displayedStage != .idle }
    /// Per-stage signal color (matches `MW.stateColor` mapping):
    /// recording=red, processing=blue, postProcessing=accent, idle=green.
    private var stageColor: Color { MW.stateColor(displayedStage.rawValue) }
    /// Stage-coloured halo opacity. Idle = 0 (no halo), active = 0.55/0.45.
    /// Animated as a single Double to avoid the trail artefact of switching
    /// shadow color to `.clear` mid-transition.
    private var haloOpacity: Double {
        guard isActive else { return 0 }
        return MW.isDark ? 0.55 : 0.45
    }

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing colored dot — pulses on recording, steady otherwise.
            Circle()
                .fill(stageColor)
                .frame(width: 8, height: 8)
                .shadow(color: stageColor.opacity(0.55), radius: 4)
                .scaleEffect(displayedStage == .recording && pulseDot ? 1.18 : 1.0)
                .opacity(displayedStage == .recording && pulseDot ? 0.85 : 1.0)

            // Voice-reactive bars — recording only.
            if displayedStage == .recording {
                BarVisualizer(bars: bars, height: 14)
            }

            // Stage label — uppercase tracked.
            Text(stageLabel(displayedStage))
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(1)
                .foregroundStyle(MW.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            // Specular rim — top-down white gradient for the glass look.
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(MW.isDark ? 0.22 : 0.85),
                            Color.white.opacity(MW.isDark ? 0.04 : 0.25),
                            Color.white.opacity(0)
                        ],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 1
                )
                .blendMode(.overlay)
        }
        .overlay(Capsule(style: .continuous).strokeBorder(MW.border, lineWidth: 0.5))
        .clipShape(Capsule(style: .continuous))
        // Two-shadow stack: black raised + state-coloured halo. Halo radius
        // is FIXED at 28; the visibility is animated via opacity only (NOT
        // by switching color to .clear or animating radius). That kept the
        // halo "trailing" during stage→idle transitions because color/radius
        // animated separately and could read as a half-faded ghost.
        .shadow(color: .black.opacity(MW.isDark ? 0.45 : 0.18), radius: 24, x: 0, y: 8)
        .shadow(color: stageColor.opacity(haloOpacity), radius: 28)
        .scaleEffect(appeared ? 1 : 0.85)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: displayedStage)
        .animation(.easeOut(duration: 0.25), value: haloOpacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            displayedStage = stage
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { appeared = true }
            startDotPulse(stage)
        }
        .onChange(of: stage) { _, newStage in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                displayedStage = newStage
            }
            startDotPulse(newStage)
        }
    }

    private func stageLabel(_ s: PillStage) -> String {
        switch s {
        case .idle: "READY"
        case .recording: "RECORDING"
        case .processing: "TRANSCRIBING"
        case .postProcessing: isTranslating ? "TRANSLATING" : "PROCESSING"
        }
    }

    private func startDotPulse(_ s: PillStage) {
        if s == .recording {
            pulseDot = false
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulseDot = true }
        } else {
            pulseDot = false
        }
    }
}

// MARK: - Island Contour Builder

private enum IslandContour {
    /// Outer contour: left-down → BL arc → bottom → BR arc → right-up (NO top edge)
    static func outer(cx: CGFloat, topY: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, n: Int = 25) -> [CGPoint] {
        var pts: [CGPoint] = []
        let x0 = cx - w / 2, x1 = cx + w / 2, y1 = topY + h
        // Left side down
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            pts.append(CGPoint(x: x0, y: topY + 6 + t * (h - 6 - r)))
        }
        // BL arc (π → π/2, clockwise down to bottom)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let a = CGFloat.pi - t * CGFloat.pi / 2
            pts.append(CGPoint(x: x0 + r + r * cos(a), y: y1 - r + r * sin(a)))
        }
        // Bottom
        for i in 0..<(n * 2) {
            let t = CGFloat(i) / CGFloat(n * 2 - 1)
            pts.append(CGPoint(x: x0 + r + t * (w - 2 * r), y: y1))
        }
        // BR arc (π/2 → 0, clockwise up to right side)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let a = CGFloat.pi / 2 - t * CGFloat.pi / 2
            pts.append(CGPoint(x: x1 - r + r * cos(a), y: y1 - r + r * sin(a)))
        }
        // Right side up
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            pts.append(CGPoint(x: x1, y: y1 - r - t * (h - 6 - r)))
        }
        return pts
    }

    /// Inner contour (inside expanded notch, skipping camera zone)
    static func inner(cx: CGFloat, topY: CGFloat, w: CGFloat, h: CGFloat, r: CGFloat, margin: CGFloat, n: Int = 25) -> [CGPoint] {
        var pts: [CGPoint] = []
        let ix0 = cx - w / 2 + margin, ix1 = cx + w / 2 - margin
        let iy0 = topY + margin + 10 // skip camera zone
        let iy1 = topY + h - margin
        let ir = min(r - margin / 2, 12)
        // Left down
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            pts.append(CGPoint(x: ix0, y: iy0 + ir + t * (iy1 - iy0 - 2 * ir)))
        }
        // BL arc (π → π/2)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let a = CGFloat.pi - t * CGFloat.pi / 2
            pts.append(CGPoint(x: ix0 + ir + ir * cos(a), y: iy1 - ir + ir * sin(a)))
        }
        // Bottom
        for i in 0..<(n * 2) {
            let t = CGFloat(i) / CGFloat(n * 2 - 1)
            pts.append(CGPoint(x: ix0 + ir + t * (ix1 - ix0 - 2 * ir), y: iy1))
        }
        // BR arc (π/2 → 0)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let a = CGFloat.pi / 2 - t * CGFloat.pi / 2
            pts.append(CGPoint(x: ix1 - ir + ir * cos(a), y: iy1 - ir + ir * sin(a)))
        }
        // Right up
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            pts.append(CGPoint(x: ix1, y: iy1 - ir - t * (iy1 - iy0 - 2 * ir)))
        }
        return pts
    }
}

// MARK: - Contour Snake Canvas (TimelineView for continuous animation)

private struct ContourSnakeCanvas: View {
    let color: Color
    let bounceSpeed: Double
    let isInner: Bool
    let notchW: CGFloat
    let notchH: CGFloat
    let notchR: CGFloat
    var innerMargin: CGFloat = 12

    @State private var startTime: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            let time: Double = {
                if let st = startTime {
                    return timeline.date.timeIntervalSince(st)
                } else {
                    DispatchQueue.main.async { startTime = timeline.date }
                    return 0
                }
            }()
            Canvas { ctx, size in
                let cx = size.width / 2
                let pts: [CGPoint]
                if isInner {
                    pts = IslandContour.inner(cx: cx, topY: 0, w: notchW, h: notchH, r: notchR, margin: innerMargin)
                } else {
                    pts = IslandContour.outer(cx: cx, topY: 0, w: notchW, h: notchH, r: notchR)
                }
                drawSnake(ctx: ctx, pts: pts, time: time)
            }
        }
    }

    private func drawSnake(ctx: GraphicsContext, pts: [CGPoint], time: Double) {
        let total = pts.count
        guard total > 1 else { return }

        let progress = (time / bounceSpeed).truncatingRemainder(dividingBy: 2.0)
        let phase = progress <= 1 ? progress : 2 - progress
        let headIdx = min(Int(phase * Double(total - 1)), total - 1)
        let tailLen = Int(Double(total) * 0.28)
        let goingForward = progress <= 1

        // Dim base contour
        var basePath = Path()
        for (i, pt) in pts.enumerated() {
            if i == 0 { basePath.move(to: pt) } else { basePath.addLine(to: pt) }
        }
        ctx.stroke(basePath, with: .color(color.opacity(0.06)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        // Build snake indices from tail-end → head
        var snakeIndices: [(idx: Int, frac: CGFloat)] = []
        for off in stride(from: tailLen, through: 0, by: -1) {
            let idx = goingForward ? headIdx - off : headIdx + off
            if idx >= 0 && idx < total {
                snakeIndices.append((idx, 1.0 - CGFloat(off) / CGFloat(tailLen)))
            }
        }

        // Draw body segments with gradient fade
        for i in 0..<(snakeIndices.count - 1) {
            let curr = snakeIndices[i]
            let next = snakeIndices[i + 1]
            let frac = next.frac
            let alpha = frac * frac * 0.7
            let w = 1.5 + frac * 2.5

            var seg = Path()
            seg.move(to: pts[curr.idx])
            seg.addLine(to: pts[next.idx])
            ctx.stroke(seg, with: .color(color.opacity(alpha)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round))

            // Soft glow on brighter segments
            if frac > 0.3 {
                ctx.stroke(seg, with: .color(color.opacity(frac * 0.2)),
                           style: StrokeStyle(lineWidth: w + 4, lineCap: .round))
            }
        }

        // Head: concentric glow circles
        let hp = pts[headIdx]
        for (radius, opacity) in [(CGFloat(14), 0.12), (CGFloat(8), 0.25), (CGFloat(5), 0.45)] as [(CGFloat, Double)] {
            let p = Path(ellipseIn: CGRect(x: hp.x - radius, y: hp.y - radius, width: radius * 2, height: radius * 2))
            ctx.fill(p, with: .color(color.opacity(opacity)))
        }
        // Bright core
        let core = Path(ellipseIn: CGRect(x: hp.x - 3, y: hp.y - 3, width: 6, height: 6))
        ctx.fill(core, with: .color(color.opacity(0.9)))
        // White center
        let center = Path(ellipseIn: CGRect(x: hp.x - 1.5, y: hp.y - 1.5, width: 3, height: 3))
        ctx.fill(center, with: .color(color.opacity(0.9)))
    }
}

// MARK: - Contour Dual Snake Canvas (two snakes, opposite directions)

private struct ContourDualSnakeCanvas: View {
    let color: Color
    let bounceSpeed: Double
    let notchW: CGFloat
    let notchH: CGFloat
    let notchR: CGFloat
    var innerMargin: CGFloat = 12

    @State private var startTime: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            let time: Double = {
                if let st = startTime {
                    return timeline.date.timeIntervalSince(st)
                } else {
                    DispatchQueue.main.async { startTime = timeline.date }
                    return 0
                }
            }()
            Canvas { ctx, size in
                let cx = size.width / 2
                let pts = IslandContour.inner(
                    cx: cx, topY: 0, w: notchW, h: notchH, r: notchR, margin: innerMargin
                )
                drawDualSnakes(ctx: ctx, pts: pts, time: time)
            }
        }
    }

    private func drawDualSnakes(ctx: GraphicsContext, pts: [CGPoint], time: Double) {
        let total = pts.count
        guard total > 1 else { return }

        // Dim base contour
        var basePath = Path()
        for (i, pt) in pts.enumerated() {
            if i == 0 { basePath.move(to: pt) } else { basePath.addLine(to: pt) }
        }
        ctx.stroke(basePath, with: .color(color.opacity(0.06)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        // Two snakes bouncing in opposite directions
        let progress = (time / bounceSpeed).truncatingRemainder(dividingBy: 2.0)
        let phase1 = progress <= 1 ? progress : 2 - progress
        let phase2 = 1.0 - phase1 // opposite direction

        drawOneSnake(ctx: ctx, pts: pts, phase: phase1, goingForward: progress <= 1)
        drawOneSnake(ctx: ctx, pts: pts, phase: phase2, goingForward: progress > 1)
    }

    private func drawOneSnake(ctx: GraphicsContext, pts: [CGPoint], phase: Double, goingForward: Bool) {
        let total = pts.count
        let headIdx = min(Int(phase * Double(total - 1)), total - 1)
        let tailLen = Int(Double(total) * 0.22)

        var snakeIndices: [(idx: Int, frac: CGFloat)] = []
        for off in stride(from: tailLen, through: 0, by: -1) {
            let idx = goingForward ? headIdx - off : headIdx + off
            if idx >= 0 && idx < total {
                snakeIndices.append((idx, 1.0 - CGFloat(off) / CGFloat(tailLen)))
            }
        }

        for i in 0..<(snakeIndices.count - 1) {
            let curr = snakeIndices[i]
            let next = snakeIndices[i + 1]
            let frac = next.frac
            let alpha = frac * frac * 0.65
            let w = 1.5 + frac * 2.0

            var seg = Path()
            seg.move(to: pts[curr.idx])
            seg.addLine(to: pts[next.idx])
            ctx.stroke(seg, with: .color(color.opacity(alpha)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round))

            if frac > 0.4 {
                ctx.stroke(seg, with: .color(color.opacity(frac * 0.15)),
                           style: StrokeStyle(lineWidth: w + 4, lineCap: .round))
            }
        }

        // Head glow
        let hp = pts[headIdx]
        for (radius, opacity) in [(CGFloat(10), 0.1), (CGFloat(6), 0.2), (CGFloat(4), 0.4)] as [(CGFloat, Double)] {
            let p = Path(ellipseIn: CGRect(x: hp.x - radius, y: hp.y - radius, width: radius * 2, height: radius * 2))
            ctx.fill(p, with: .color(color.opacity(opacity)))
        }
        let core = Path(ellipseIn: CGRect(x: hp.x - 2.5, y: hp.y - 2.5, width: 5, height: 5))
        ctx.fill(core, with: .color(color.opacity(0.85)))
    }
}

// MARK: - Contour Voice Pulse Canvas (responds to audioLevel)

private struct ContourVoicePulseCanvas: View {
    let audioLevel: Float
    let notchW: CGFloat
    let notchH: CGFloat
    let notchR: CGFloat
    var innerMargin: CGFloat = 12

    private let pulseColor = Color(red: 1.0, green: 0.16, blue: 0.08)

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let pts = IslandContour.inner(cx: cx, topY: 0, w: notchW, h: notchH, r: notchR, margin: innerMargin)
            drawPulse(ctx: ctx, pts: pts)
        }
    }

    private func drawPulse(ctx: GraphicsContext, pts: [CGPoint]) {
        let total = pts.count
        guard total > 1 else { return }
        let midIdx = total / 2
        let voiceLevel = CGFloat(min(1.0, max(0.08, audioLevel)))
        let halfSpread = Int(voiceLevel * CGFloat(midIdx))

        // Dim base contour
        var basePath = Path()
        for (i, pt) in pts.enumerated() {
            if i == 0 { basePath.move(to: pt) } else { basePath.addLine(to: pt) }
        }
        ctx.stroke(basePath, with: .color(pulseColor.opacity(0.04)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

        // Expanding pulse from center outward
        for off in stride(from: halfSpread, through: 0, by: -1) {
            let idxL = midIdx - off
            let idxR = midIdx + off
            guard idxL >= 0, idxR < total else { continue }

            let distFromCenter = CGFloat(off) / max(1, CGFloat(halfSpread))
            let fade = 1.0 - distFromCenter * distFromCenter
            let alpha = fade * 0.8
            let w = 2.0 + fade * 1.5

            // Left-side segment
            if idxL + 1 < total {
                var seg = Path()
                seg.move(to: pts[idxL])
                seg.addLine(to: pts[idxL + 1])
                ctx.stroke(seg, with: .color(pulseColor.opacity(alpha)),
                           style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
            // Right-side segment
            if idxR - 1 >= 0 {
                var seg = Path()
                seg.move(to: pts[idxR])
                seg.addLine(to: pts[idxR - 1])
                ctx.stroke(seg, with: .color(pulseColor.opacity(alpha)),
                           style: StrokeStyle(lineWidth: w, lineCap: .round))
            }
        }

        // Center glow dot
        let cp = pts[midIdx]
        for (radius, opacity) in [(CGFloat(6), 0.3), (CGFloat(3), 0.7)] as [(CGFloat, Double)] {
            let p = Path(ellipseIn: CGRect(x: cp.x - radius, y: cp.y - radius, width: radius * 2, height: radius * 2))
            ctx.fill(p, with: .color(pulseColor.opacity(opacity)))
        }
    }
}

// MARK: - 2. Island Aura Pill — Liquid Glass spec § 8 Island Aura
//
// Notch UNCHANGED. Halo blooms in the bezel AROUND it. Status badge sits
// BELOW the notch (never inside Apple's reserved sensor zone). Spec asks
// for 2-3 blur layers (was 5) — voice drives SCALE not opacity, so even a
// quiet pill remains readable. Stage colour comes from `MW.stateColor`.

struct IslandAuraPillView: View {
    let stage: PillStage
    let isTranslating: Bool
    let audioLevel: Float
    let bars: [Float]

    @State private var appeared = false
    @State private var pulseDot = false
    @ObservedObject private var notch = NotchDetector.shared

    private var notchW: CGFloat { notch.notchWidth > 0 ? notch.notchWidth : 200 }
    private var notchH: CGFloat { notch.notchHeight > 0 ? notch.notchHeight : 32 }
    private var isActive: Bool { stage != .idle }
    private var stageColor: Color { MW.stateColor(stage.rawValue) }

    /// 0..1 voice level with a sqrt power curve so quiet input still reads.
    private var voiceLevel: CGFloat { min(1.0, sqrt(CGFloat(audioLevel)) * 1.5) }
    /// Voice-driven scale (1 → 1.18) per spec — replaces the prior opacity wobble.
    private var auraScale: CGFloat { 1 + voiceLevel * 0.18 }
    private var auraOpacity: Double { isActive ? 0.85 + Double(voiceLevel) * 0.15 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Layer 1 — outer soft bloom (large + heavy blur)
                if isActive && appeared {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [stageColor.opacity(0.7), .clear],
                                center: .center,
                                startRadius: 0, endRadius: 180
                            )
                        )
                        .frame(width: 360, height: 140)
                        .blur(radius: 28)
                        .opacity(auraOpacity * 0.6)
                        .scaleEffect(auraScale * 1.4)
                        .offset(y: -50)
                }
                // Layer 2 — inner crisper bloom (smaller + lighter blur, hugs the notch)
                if isActive && appeared {
                    Ellipse()
                        .fill(
                            RadialGradient(
                                colors: [stageColor.opacity(0.85), .clear],
                                center: .center,
                                startRadius: 0, endRadius: 125
                            )
                        )
                        .frame(width: 250, height: 80)
                        .blur(radius: 12)
                        .opacity(auraOpacity * 0.9)
                        .scaleEffect(auraScale)
                        .offset(y: -20)
                }

                // Status badge — BELOW the notch, never inside it.
                if isActive && appeared {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(stageColor)
                            .frame(width: 5, height: 5)
                            .shadow(color: stageColor.opacity(0.55), radius: 5)
                            .scaleEffect(stage == .recording && pulseDot ? 1.2 : 1.0)
                        Text(stageLabel(stage))
                            .font(.system(size: 8.5, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(MW.textPrimary.opacity(0.85))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .overlay(Capsule().strokeBorder(MW.border, lineWidth: 0.5))
                    .offset(y: notchH + 6)
                }
            }
            .frame(width: notchW, height: notchH)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.12), value: audioLevel)
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { appeared = true }
            startDotPulse(stage)
        }
        .onChange(of: stage) { _, newStage in
            startDotPulse(newStage)
        }
    }

    private func stageLabel(_ s: PillStage) -> String {
        switch s {
        case .idle: "READY"
        case .recording: "RECORDING"
        case .processing: "TRANSCRIBING"
        case .postProcessing: isTranslating ? "TRANSLATING" : "PROCESSING"
        }
    }

    private func startDotPulse(_ s: PillStage) {
        pulseDot = false
        if s == .recording {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulseDot = true }
        }
    }
}

// MARK: - 3. Island Expand Pill — Liquid Glass spec § 8 Island Expand
//
// The notch ITSELF grows wider/taller AND hosts the content inside it.
// Spec ask: «вся анимация внутри челки» — the dot, voice bars, and label
// render directly on the expanded black notch surface, no separate pill
// below. Aura blooms around the expanded shape and tracks its spring anim.

struct IslandPillView: View {
    let stage: PillStage
    let isTranslating: Bool
    let audioLevel: Float
    let bars: [Float]

    @State private var appeared = false
    @State private var pulseDot = false
    @ObservedObject private var notch = NotchDetector.shared

    private var isActive: Bool { stage != .idle }
    private let trueBlack = Color(red: 0, green: 0, blue: 0)

    private var notchW: CGFloat { notch.notchWidth > 0 ? notch.notchWidth : 200 }
    private var notchH: CGFloat { notch.notchHeight > 0 ? notch.notchHeight : 32 }
    /// Expanded geometry — wide enough for dot + 24-bar visualizer + label,
    /// tall enough for the content (≈28pt) plus comfortable padding.
    private var expandedW: CGFloat { max(notchW + 160, 340) }
    private var expandedH: CGFloat { max(notchH + 22, 52) }
    /// Match expanded radius to `--r-lg` (MW.rLarge) per spec ask.
    private var expandedR: CGFloat { MW.rLarge / 2 }

    /// Live geometry — at idle stays at the OS notch, otherwise expands.
    private var currentW: CGFloat { isActive ? expandedW : notchW }
    private var currentH: CGFloat { isActive ? expandedH : notchH }
    private var currentR: CGFloat { isActive ? expandedR : (notch.notchRadius > 0 ? notch.notchRadius : 12) }

    private var stageColor: Color { MW.stateColor(stage.rawValue) }
    private var voiceLevel: CGFloat { min(1.0, sqrt(CGFloat(audioLevel)) * 1.5) }
    private var auraScale: CGFloat { 1 + voiceLevel * 0.12 }

    /// Aura geometry derived from notch. Width capped to fit inside the 520pt
    /// host window (520 - 40pt safety = 480 max outer aura width).
    private var auraW: CGFloat { min(currentW + 80, 440) }
    private var auraH: CGFloat { currentH * 3 + 30 }

    var body: some View {
        // Critical: ZStack frame is pinned to the NOTCH size (not the aura's
        // natural size). Aura ellipses .offset render OUTSIDE this frame but
        // don't enlarge it — so the ZStack stays anchored at the very top of
        // the host window. Without this pin, when the aura appears the ZStack
        // grows to fit it and the whole layout slides downward (the symptom
        // user reported as "челка появляется снизу и едет наверх").
        ZStack(alignment: .top) {
            // Aura around the expanded notch. Two layers: outer soft bloom +
            // inner crisper halo. Modifier order matters — we `.scaleEffect`
            // BEFORE `.blur` so the blur kernel is applied to the final pixel
            // size (otherwise the soft edge gets stretched/compressed and
            // creates a visible hard ring at the falloff). Three-stop gradient
            // gives a smooth fade-to-clear instead of a hard edge.
            if isActive && appeared {
                // Outer soft bloom — centered on the notch's vertical center.
                // Frame height for outer is `auraH + 50`. ZStack alignment .top
                // places this frame's TOP at y=0, so the natural center is
                // at frame_h/2. To re-center on the notch midpoint we offset
                // by `currentH/2 - frame_h/2` (negative — moves the aura UP).
                Ellipse()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: stageColor.opacity(0.7), location: 0),
                                .init(color: stageColor.opacity(0.18), location: 0.55),
                                .init(color: .clear, location: 1)
                            ],
                            center: .center, startRadius: 0, endRadius: auraW / 1.6
                        )
                    )
                    .frame(width: auraW + 80, height: auraH + 50)
                    .opacity(0.55)
                    .scaleEffect(auraScale * 1.12)
                    .blur(radius: 32)
                    .offset(y: currentH / 2 - (auraH + 50) / 2)
                // Inner crisper bloom — same centering trick with its own frame.
                Ellipse()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: stageColor.opacity(0.85), location: 0),
                                .init(color: stageColor.opacity(0.25), location: 0.5),
                                .init(color: .clear, location: 1)
                            ],
                            center: .center, startRadius: 0, endRadius: auraW / 2
                        )
                    )
                    .frame(width: auraW + 30, height: auraH + 20)
                    .opacity(0.85)
                    .scaleEffect(auraScale)
                    .blur(radius: 16)
                    .offset(y: currentH / 2 - (auraH + 20) / 2)
            }

            // The expanded notch — black shape grows wider AND taller via spring,
            // hosts content as an overlay. ZStack alignment .top + ZStack's explicit
            // notch-sized frame keep this rectangle pinned to the very top edge.
            UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 0, bottomLeading: currentR,
                bottomTrailing: currentR, topTrailing: 0
            ))
            .fill(trueBlack)
            .frame(width: currentW, height: currentH)
            .shadow(color: isActive ? stageColor.opacity(0.5) : .clear, radius: isActive ? 16 : 0, y: 4)
            .overlay(alignment: .bottom) {
                    // Content lives INSIDE the black notch, anchored to the bottom
                    // edge — the top zone of the notch is occluded by the display
                    // bezel/camera hardware, so content reads cleanly only in the
                    // expanded region (below the OS notch baseline).
                    if isActive && appeared {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(stageColor)
                                .frame(width: 7, height: 7)
                                .shadow(color: stageColor.opacity(0.7), radius: 5)
                                .scaleEffect(stage == .recording && pulseDot ? 1.25 : 1.0)
                            if stage == .recording {
                                BarVisualizer(bars: bars, height: 14)
                                Text(stageLabel(stage))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .tracking(1)
                                    .foregroundStyle(.white.opacity(0.9))
                            } else {
                                // Spinner for processing / translating — inside the notch.
                                Circle()
                                    .trim(from: 0, to: 0.7)
                                    .stroke(stageColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                    .frame(width: 12, height: 12)
                                    .rotationEffect(.degrees(pulseDot ? 360 : 0))
                                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: pulseDot)
                                Text(stageLabel(stage))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .tracking(1)
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 7)
                        // Just opacity — combining .scale on top of the parent's
                        // size spring caused visible jitter on appear.
                        .transition(.opacity.animation(.easeOut(duration: 0.22)))
                    }
                }
            .animation(.spring(response: 0.7, dampingFraction: 0.88), value: isActive)
        }
        // Pin to the OS notch slot at the very top edge — frame matches the
        // notch's expanded size so the ZStack doesn't drift when aura is added.
        .frame(width: currentW, height: currentH, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { appeared = true }
            startDotPulse(stage)
        }
        .onChange(of: stage) { _, newStage in
            startDotPulse(newStage)
        }
    }

    private func stageLabel(_ s: PillStage) -> String {
        switch s {
        case .idle: "READY"
        case .recording: "RECORDING"
        case .processing: "TRANSCRIBING"
        case .postProcessing: isTranslating ? "TRANSLATING" : "PROCESSING"
        }
    }

    private func startDotPulse(_ s: PillStage) {
        pulseDot = false
        if s != .idle {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulseDot = true }
        }
    }
}

// MARK: - 4. Top Edge Glow Pill — Liquid Glass spec § 8 Edge Glow
//
// Glow runs along the FULL TOP EDGE of the screen. Voice-reactive on EVERY
// active stage (not just recording) — thickness, brightness, falloff, and
// hot-spot bloom all pulse with input level. Shimmer sweep travels across
// the strip continuously when active. Notch stays normal.

struct GlowStripPillView: View {
    let stage: PillStage
    let audioLevel: Float

    @State private var visible: CGFloat = 0
    @State private var sweepX: CGFloat = -0.3

    private var color: Color { MW.stateColor(stage.rawValue) }
    private var glow: Color { color.opacity(0.7) }
    private var isActive: Bool { stage != .idle }

    /// Voice 0..1 with sqrt curve so quiet input still moves things.
    private var voiceLevel: CGFloat { min(1.0, sqrt(CGFloat(audioLevel)) * 1.5) }
    /// Strip thickness — 4 at silence, 9 at peak voice.
    private var stripH: CGFloat { 4 + voiceLevel * 5 }
    /// Falloff gradient depth — 90 at silence, 140 at peak.
    private var falloffH: CGFloat { 90 + voiceLevel * 50 }
    private var falloffOpacity: Double { 0.7 + Double(voiceLevel) * 0.3 }
    private var stripOpacity: Double { 0.95 + Double(voiceLevel) * 0.05 }
    /// Hot-spot width — bloom blob at left+right that grows with voice.
    private var hotspotW: CGFloat { 80 + voiceLevel * 120 }
    private var hotspotOpacity: Double { 0.6 + Double(voiceLevel) * 0.4 }

    var body: some View {
        ZStack(alignment: .top) {
            if isActive && visible > 0 {
                // Main strip — solid bright line at the top, with multi-layer glow shadow.
                Rectangle()
                    .fill(color)
                    .frame(height: stripH)
                    .opacity(stripOpacity)
                    .shadow(color: glow, radius: 18)
                    .shadow(color: glow, radius: 36)
                    .shadow(color: glow, radius: 56)
                    .shadow(color: glow, radius: 80)

                // Falloff into the screen — voice-reactive.
                LinearGradient(colors: [glow, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: falloffH)
                    .opacity(falloffOpacity)
                    .allowsHitTesting(false)

                // Secondary inner falloff — richer color, screen blend mode.
                LinearGradient(colors: [color, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: falloffH * 0.4)
                    .opacity(0.35 + Double(voiceLevel) * 0.25)
                    .blendMode(.screen)
                    .allowsHitTesting(false)

                // Voice-driven hotspots — left and right.
                GeometryReader { geo in
                    ZStack(alignment: .top) {
                        Capsule()
                            .fill(
                                RadialGradient(
                                    colors: [color, .clear],
                                    center: .center, startRadius: 0, endRadius: hotspotW / 1.5
                                )
                            )
                            .frame(width: hotspotW, height: stripH * 1.8)
                            .opacity(hotspotOpacity)
                            .blur(radius: 2)
                            .position(x: geo.size.width * 0.15, y: stripH / 2)
                        Capsule()
                            .fill(
                                RadialGradient(
                                    colors: [color, .clear],
                                    center: .center, startRadius: 0, endRadius: hotspotW / 1.5
                                )
                            )
                            .frame(width: hotspotW, height: stripH * 1.8)
                            .opacity(hotspotOpacity)
                            .blur(radius: 2)
                            .position(x: geo.size.width * 0.85, y: stripH / 2)

                        // Cinematic shimmer sweep — linear-gradient highlight that
                        // travels from -0.3 to 1.3 across full width, ALWAYS on.
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: max(0, sweepX - 0.15)),
                                .init(color: Color.white.opacity(0.95), location: sweepX),
                                .init(color: .clear, location: min(1, sweepX + 0.15)),
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(height: stripH)
                        .blendMode(.plusLighter)
                    }
                }
                .frame(height: stripH)
            }
        }
        .opacity(Double(visible))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.08), value: audioLevel)
        .onAppear {
            if isActive {
                withAnimation(.easeIn(duration: 0.6)) { visible = 1 }
            }
            startSweep()
        }
        .onChange(of: stage) { _, new in
            if new == .idle {
                withAnimation(.easeOut(duration: 0.8)) { visible = 0 }
            } else if visible < 1 {
                withAnimation(.easeIn(duration: 0.4)) { visible = 1 }
            }
            startSweep()
        }
    }

    /// Sweep travels left → right continuously when active. 2.4s cycle per spec.
    private func startSweep() {
        sweepX = -0.3
        guard isActive else { return }
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            sweepX = 1.3
        }
    }
}

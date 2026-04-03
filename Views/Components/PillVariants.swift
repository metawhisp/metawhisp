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

struct CapsulePillView: View {
    let stage: PillStage
    let isTranslating: Bool
    let audioLevel: Float
    let bars: [Float]
    @State private var appeared = false
    @State private var pulse = false
    @State private var borderRotation: Double = 0
    @State private var processingGlow = false

    private var isProcessing: Bool { stage == .processing || stage == .postProcessing }

    @State private var displayedStage: PillStage = .idle

    var body: some View {
        HStack(spacing: MW.sp12) {
            stageIndicator(for: displayedStage)
            Rectangle().fill(MW.border).frame(width: MW.hairline, height: 16)
            if displayedStage == .processing || displayedStage == .postProcessing {
                BlocksShimmerText(text: stageLabel(displayedStage))
            } else {
                Text(stageLabel(displayedStage).uppercased())
                    .font(MW.monoLg).foregroundStyle(MW.textPrimary).tracking(1)
            }
            if displayedStage == .recording {
                BarVisualizer(bars: bars, height: 14)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(MW.surface)
        .overlay(
            Capsule()
                .stroke(displayedStage == .recording ? MW.textPrimary.opacity(pulse ? 0.4 : 0.15) : MW.border,
                        lineWidth: displayedStage == .recording ? 1 : MW.hairline)
        )
        .overlay {
            if displayedStage == .processing || displayedStage == .postProcessing {
                Capsule()
                    .stroke(
                        AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.35),
                                .init(color: MW.textPrimary.opacity(0.6), location: 0.65),
                                .init(color: MW.textPrimary.opacity(0.2), location: 1.0),
                            ],
                            center: .center,
                            angle: .degrees(borderRotation)
                        ),
                        lineWidth: 1.5
                    )
            }
        }
        .clipShape(Capsule())
        .shadow(color: isProcessing ? MW.textPrimary.opacity(processingGlow ? 0.15 : 0.03) : .clear,
                radius: isProcessing ? (processingGlow ? 12 : 4) : 0)
        .scaleEffect(appeared ? 1 : 0.85)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: displayedStage)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            displayedStage = stage
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { appeared = true }
            startStageAnimations(stage)
        }
        .onChange(of: stage) { _, newStage in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                displayedStage = newStage
            }
            startStageAnimations(newStage)
        }
    }

    @ViewBuilder
    private func stageIndicator(for s: PillStage) -> some View {
        switch s {
        case .recording:
            Circle().fill(MW.live).frame(width: 6, height: 6)
                .shadow(color: .red.opacity(0.6), radius: 4)
        case .processing:
            Image(systemName: "brain").font(.system(size: 12, weight: .light)).foregroundStyle(MW.textSecondary)
        case .postProcessing:
            Image(systemName: "globe").font(.system(size: 12, weight: .light)).foregroundStyle(MW.textSecondary)
        case .idle:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .light)).foregroundStyle(MW.textSecondary)
        }
    }

    private func stageLabel(_ s: PillStage) -> String {
        switch s {
        case .idle: "Done"
        case .recording: "Recording"
        case .processing: "Transcribing"
        case .postProcessing: isTranslating ? "Translating" : "Processing"
        }
    }

    private func startStageAnimations(_ s: PillStage) {
        if s == .recording {
            pulse = false
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { pulse = true }
        }
        if s == .processing || s == .postProcessing {
            borderRotation = 0
            processingGlow = false
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                borderRotation = 360
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                processingGlow = true
            }
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

// MARK: - 2. Island Aura Pill (Concept A — replaces Dot Glow)
// Notch stays original size. Red aura glow for recording, snake for processing/translating.

struct IslandAuraPillView: View {
    let stage: PillStage
    let isTranslating: Bool
    let audioLevel: Float
    let bars: [Float]

    @State private var appeared = false
    @State private var auraPulse: CGFloat = 0
    @ObservedObject private var notch = NotchDetector.shared

    private let trueBlack = Color(red: 0, green: 0, blue: 0)
    private var notchW: CGFloat { notch.notchWidth }
    private var notchH: CGFloat { notch.notchHeight }
    private var notchR: CGFloat { notch.notchRadius }

    // Amplify audio level: raw value 0..1 is often low, boost it so aura reacts visibly
    private var voiceLevel: CGFloat {
        let raw = CGFloat(audioLevel)
        // Apply power curve: sqrt makes quiet sounds more visible, *1.5 boosts range
        return min(1.0, sqrt(raw) * 1.5)
    }

    private var stageColor: Color {
        switch stage {
        case .recording: Color(red: 1.0, green: 0.14, blue: 0.06)
        case .processing: isTranslating ? Color(red: 0.14, green: 0.82, blue: 0.39) : Color(red: 0.27, green: 0.53, blue: 1.0)
        case .postProcessing: Color(red: 0.14, green: 0.82, blue: 0.39)
        case .idle: .clear
        }
    }

    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 0, bottomLeading: notchR,
            bottomTrailing: notchR, topTrailing: 0
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Layer 1: Aura glow (recording — intense blurred glow around notch)
                if stage == .recording && appeared {
                    // Voice is the primary driver: 0.3 base + 0.7 from voice
                    let vl = voiceLevel
                    let pulse = auraPulse * 0.1  // subtle background pulse
                    let intensity = 0.3 + vl * 0.7 + pulse

                    // Hot core — always visible, brighter with voice
                    notchShape
                        .fill(stageColor.opacity(0.5 + vl * 0.5))
                        .frame(width: notchW + 40, height: notchH + 20)
                        .blur(radius: 60)
                    // Inner glow — scales with voice
                    notchShape
                        .fill(stageColor.opacity(intensity * 0.9))
                        .frame(width: notchW + 20, height: notchH + 10)
                        .blur(radius: 120)
                    // Tight spread — appears with voice
                    notchShape
                        .fill(stageColor.opacity(intensity * 0.8))
                        .frame(width: notchW, height: notchH)
                        .blur(radius: 200)
                    // Medium spread — voice-driven expansion
                    notchShape
                        .fill(stageColor.opacity(intensity * 0.6))
                        .frame(width: notchW, height: notchH)
                        .blur(radius: 320)
                    // Wide ambient — only visible when speaking loudly
                    notchShape
                        .fill(stageColor.opacity(max(0, vl - 0.3) * 0.7))
                        .frame(width: notchW, height: notchH)
                        .blur(radius: 480)
                }

                // Layer 2: Aura glow for processing/translating (blue/green)
                if (stage == .processing || stage == .postProcessing) && appeared {
                    let procColor = isTranslating ? Color(red: 0.14, green: 0.82, blue: 0.39) : Color(red: 0.27, green: 0.53, blue: 1.0)
                    // Core
                    notchShape
                        .fill(procColor.opacity(0.9))
                        .frame(width: notchW, height: notchH)
                        .blur(radius: 40)
                    // Medium spread
                    notchShape
                        .fill(procColor.opacity(0.6))
                        .frame(width: notchW, height: notchH)
                        .blur(radius: 90)
                    // Wide ambient
                    notchShape
                        .fill(procColor.opacity(0.35))
                        .frame(width: notchW, height: notchH)
                        .blur(radius: 150)

                    // Snake animation on top of glow
                    ContourSnakeCanvas(
                        color: procColor,
                        bounceSpeed: 5.0,
                        isInner: false,
                        notchW: notchW,
                        notchH: notchH,
                        notchR: notchR
                    )
                    .allowsHitTesting(false)
                }

                // Layer 3: Subtle edge glow line (recording)
                if stage == .recording && appeared {
                    notchShape
                        .stroke(
                            LinearGradient(
                                colors: [.clear, stageColor.opacity(0.05),
                                         stageColor.opacity(0.3 + voiceLevel * 0.4),
                                         stageColor.opacity(0.05), .clear],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                        .frame(width: notchW, height: notchH)
                }

                // Camera dot (not drawn — real camera is behind the notch)
                // No true-black shape — the real notch IS black already
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.12), value: audioLevel)
        .onAppear {
            withAnimation(.easeIn(duration: 0.3)) { appeared = true }
            startAnimations(stage)
        }
        .onChange(of: stage) { _, newStage in
            startAnimations(newStage)
        }
    }

    private func startAnimations(_ s: PillStage) {
        auraPulse = 0
        if s == .recording {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { auraPulse = 1 }
        }
    }
}

// MARK: - 3. Island Expand Pill (Concept B)
// Notch expands. Voice pulse for recording, snake inside for processing/translating.

struct IslandPillView: View {
    let stage: PillStage
    let isTranslating: Bool
    let audioLevel: Float
    let bars: [Float]

    @State private var appeared = false
    @State private var contentVisible = false
    @State private var pulseGlow: CGFloat = 0
    @ObservedObject private var notch = NotchDetector.shared

    private var isActive: Bool { stage != .idle }
    private let trueBlack = Color(red: 0, green: 0, blue: 0)

    private let seedW: CGFloat = 120
    private let seedH: CGFloat = 8
    private var notchW: CGFloat { notch.notchWidth > 0 ? notch.notchWidth : 200 }
    private var notchH: CGFloat { notch.notchHeight > 0 ? notch.notchHeight : 32 }
    private var expandedW: CGFloat { max(notchW * 1.7, 340) }
    private let expandedH: CGFloat = 70
    private let expandedR: CGFloat = 20

    private var voiceLevel: CGFloat { min(1.0, CGFloat(audioLevel)) }

    private var currentW: CGFloat {
        if !appeared { return seedW }
        return isActive ? expandedW : notchW
    }
    private var currentH: CGFloat {
        if !appeared { return seedH }
        return isActive ? expandedH : notchH
    }
    private var currentRadius: CGFloat {
        if !appeared { return 4 }
        return isActive ? expandedR : 12
    }

    private var stageColor: Color {
        switch stage {
        case .recording: Color(red: 1.0, green: 0.12, blue: 0.08)
        case .processing: isTranslating ? Color(red: 0.1, green: 0.85, blue: 0.4) : Color(red: 0.3, green: 0.55, blue: 1.0)
        case .postProcessing: Color(red: 0.1, green: 0.85, blue: 0.4)
        case .idle: .clear
        }
    }

    private var edgeIntensity: CGFloat {
        switch stage {
        case .recording: 0.3 + voiceLevel * 0.5
        case .processing: 0.2 + pulseGlow * 0.3
        case .postProcessing: 0.25 + pulseGlow * 0.25
        case .idle: 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Island shape — true black
                UnevenRoundedRectangle(cornerRadii: .init(
                    topLeading: 0, bottomLeading: currentRadius,
                    bottomTrailing: currentRadius, topTrailing: 0
                ))
                .fill(trueBlack)
                .frame(width: currentW, height: currentH)

                // Edge glow line
                if isActive && contentVisible {
                    UnevenRoundedRectangle(cornerRadii: .init(
                        topLeading: 0, bottomLeading: currentRadius,
                        bottomTrailing: currentRadius, topTrailing: 0
                    ))
                    .stroke(
                        LinearGradient(
                            colors: [.clear, stageColor.opacity(0.05), stageColor.opacity(edgeIntensity),
                                     stageColor.opacity(0.05), .clear],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: currentW, height: currentH)
                    .shadow(color: stageColor.opacity(edgeIntensity * 0.5), radius: 8, y: 2)
                }

                // Camera indicator dot
                Circle().fill(Color(white: 0.10)).frame(width: 7, height: 7)
                    .padding(.top, 10)
                    .opacity(appeared ? 1 : 0)

                // Content: contour-based visualizations
                if isActive && contentVisible {
                    islandVisualization
                        .frame(width: currentW, height: currentH)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appeared)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isActive)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: stage)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { appeared = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeIn(duration: 0.15)) { contentVisible = true }
            }
            startAnimations(stage)
        }
        .onChange(of: stage) { _, newStage in
            if newStage == .idle {
                contentVisible = false
            } else if !contentVisible {
                withAnimation(.easeIn(duration: 0.1)) { contentVisible = true }
            }
            startAnimations(newStage)
        }
    }

    @ViewBuilder
    private var islandVisualization: some View {
        switch stage {
        case .recording:
            // Voice pulse expanding from center along inner contour
            ContourVoicePulseCanvas(
                audioLevel: audioLevel,
                notchW: expandedW,
                notchH: expandedH,
                notchR: expandedR
            )
            .allowsHitTesting(false)
        case .processing, .postProcessing:
            // Dual snakes moving in opposite directions along contour
            let snakeColor = isTranslating ? Color(red: 0.1, green: 0.85, blue: 0.4) : Color(red: 0.3, green: 0.55, blue: 1.0)
            ContourDualSnakeCanvas(
                color: snakeColor,
                bounceSpeed: 3.0,
                notchW: expandedW,
                notchH: expandedH,
                notchR: expandedR
            )
            .allowsHitTesting(false)
        case .idle:
            EmptyView()
        }
    }

    private func startAnimations(_ s: PillStage) {
        pulseGlow = 0
        switch s {
        case .recording:
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) { pulseGlow = 1 }
        case .processing, .postProcessing:
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { pulseGlow = 1 }
        case .idle:
            break
        }
    }
}

// MARK: - 4. Top Edge Glow Pill

struct GlowStripPillView: View {
    let stage: PillStage
    let audioLevel: Float

    @State private var pulse: CGFloat = 0
    @State private var shimmerX: CGFloat = -0.2
    @State private var visible: CGFloat = 0

    private var color: Color {
        switch stage {
        case .recording: Color(red: 1.0, green: 0.15, blue: 0.1)
        case .processing: Color(red: 0.3, green: 0.55, blue: 1.0)
        case .postProcessing: Color(red: 0.1, green: 0.9, blue: 0.4)
        case .idle: .clear
        }
    }

    private var voiceLevel: CGFloat { min(1.0, CGFloat(audioLevel)) }

    private var intensity: CGFloat {
        switch stage {
        case .recording:    0.5 + voiceLevel * 0.5
        case .processing:   0.3 + pulse * 0.4
        case .postProcessing: 0.35 + pulse * 0.35
        case .idle:         0
        }
    }

    private var glowDepth: CGFloat {
        switch stage {
        case .recording:    25 + voiceLevel * 55
        case .processing:   40 + pulse * 25
        case .postProcessing: 35 + pulse * 20
        case .idle:         0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(color.opacity(min(1, intensity * 2.0)))
                .frame(height: 2.5)

            ZStack {
                LinearGradient(
                    colors: [color.opacity(intensity * 0.8), color.opacity(intensity * 0.25), .clear],
                    startPoint: .top, endPoint: .bottom
                )

                if stage == .processing {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, shimmerX - 0.12)),
                            .init(color: color.opacity(intensity * 0.6), location: shimmerX),
                            .init(color: .clear, location: min(1, shimmerX + 0.12)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .mask(
                        LinearGradient(colors: [.white, .clear],
                                      startPoint: .top, endPoint: .bottom)
                    )
                }
            }
            .frame(height: max(1, glowDepth * visible))
            .animation(.easeOut(duration: 0.1), value: audioLevel)

            Spacer()
        }
        .opacity(Double(visible))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .onAppear {
            if stage != .idle {
                withAnimation(.easeIn(duration: 1.0)) { visible = 1 }
            }
            startAnimations()
        }
        .onChange(of: stage) { old, new in
            if new == .idle {
                withAnimation(.easeOut(duration: 1.5)) { visible = 0 }
            } else if visible < 1 {
                withAnimation(.easeIn(duration: 0.6)) { visible = 1 }
            }
            startAnimations()
        }
    }

    private func startAnimations() {
        pulse = 0; shimmerX = -0.2
        switch stage {
        case .processing:
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = 1 }
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { shimmerX = 1.2 }
        case .postProcessing:
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { pulse = 1 }
        default: break
        }
    }
}

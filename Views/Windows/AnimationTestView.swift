import SwiftUI

/// Test bench for 3 processing animation variants side by side.
/// Launch via: AnimationTestWindowController().show()
struct AnimationTestView: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("PROCESSING ANIMATION VARIANTS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.gray).tracking(2)
                .padding(.top, 16)

            HStack(alignment: .top, spacing: 24) {
                variantColumn("A: WAVES", view: AnyView(WavesIsland()))
                variantColumn("B: PULSE", view: AnyView(PulseIsland()))
                variantColumn("C: DUAL SNAKES", view: AnyView(DualSnakeIsland()))
            }
            .padding(24)

            Spacer()
        }
        .frame(width: 900, height: 350)
        .background(Color.black)
    }

    private func variantColumn(_ label: String, view: AnyView) -> some View {
        VStack(spacing: 8) {
            view.frame(width: 260, height: 200)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6)).tracking(1)
        }
    }
}

// MARK: - Shared Constants

private let islandW: CGFloat = 240
private let islandH: CGFloat = 60
private let islandR: CGFloat = 18
private let trueBlack = Color(red: 0, green: 0, blue: 0)
private let procBlue = Color(red: 0.27, green: 0.53, blue: 1.0)

private var islandShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(cornerRadii: .init(
        topLeading: 0, bottomLeading: islandR,
        bottomTrailing: islandR, topTrailing: 0
    ))
}

// MARK: - A: Waves radiating outward

private struct WavesIsland: View {
    @State private var startTime: Date?

    var body: some View {
        ZStack(alignment: .top) {
            // Waves via TimelineView for smooth continuous animation
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

                    // 5 expanding wave rings
                    for i in 0..<5 {
                        let period = 2.5
                        let delay = Double(i) * (period / 5)
                        let phase = ((time + delay) / period).truncatingRemainder(dividingBy: 1.0)
                        let scaleX: CGFloat = 1.0 + CGFloat(phase) * 1.2
                        let scaleY: CGFloat = 1.0 + CGFloat(phase) * 2.5
                        let opacity = (1.0 - CGFloat(phase)) * 0.6
                        let lineW = max(0.5, (1.0 - CGFloat(phase)) * 2.5)

                        let w = islandW * scaleX
                        let h = islandH * scaleY
                        let x = cx - w / 2
                        let y: CGFloat = 0

                        let rect = CGRect(x: x, y: y, width: w, height: h)
                        let path = Path(roundedRect: rect, cornerRadius: islandR * scaleX)
                        ctx.stroke(path, with: .color(procBlue.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: lineW))
                    }
                }
            }
            .frame(width: 260, height: 200)

            // Island body on top
            islandShape
                .fill(trueBlack)
                .frame(width: islandW, height: islandH)

            // Edge glow
            islandShape
                .stroke(procBlue.opacity(0.5), lineWidth: 1.5)
                .frame(width: islandW, height: islandH)

            // Camera dot
            Circle().fill(Color(white: 0.1)).frame(width: 7, height: 7)
                .padding(.top, 10)

            // Label
            Text("TRANSCRIBING")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7)).tracking(1)
                .padding(.top, 24)
        }
    }
}

// MARK: - B: Pulsing gradient inside

private struct PulseIsland: View {
    @State private var pulse: CGFloat = 0
    @State private var shimmerX: CGFloat = -0.3

    var body: some View {
        ZStack(alignment: .top) {
            // Soft outer glow
            islandShape
                .fill(procBlue.opacity(0.15 + pulse * 0.15))
                .frame(width: islandW + 20, height: islandH + 10)
                .blur(radius: 20)

            // Island body
            islandShape
                .fill(trueBlack)
                .frame(width: islandW, height: islandH)

            // Internal gradient pulse
            islandShape
                .fill(
                    LinearGradient(
                        colors: [
                            procBlue.opacity(0.05 + pulse * 0.15),
                            procBlue.opacity(0.15 + pulse * 0.25),
                            procBlue.opacity(0.05 + pulse * 0.15),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: islandW, height: islandH)

            // Shimmer sweep
            islandShape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, shimmerX - 0.15)),
                            .init(color: procBlue.opacity(0.3), location: shimmerX),
                            .init(color: .clear, location: min(1, shimmerX + 0.15)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: islandW, height: islandH)

            // Edge glow
            islandShape
                .stroke(procBlue.opacity(0.2 + pulse * 0.3), lineWidth: 1.5)
                .frame(width: islandW, height: islandH)

            // Camera dot
            Circle().fill(Color(white: 0.1)).frame(width: 7, height: 7)
                .padding(.top, 10)

            // Label
            Text("TRANSCRIBING")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7)).tracking(1)
                .padding(.top, 24)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulse = 1.0
            }
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                shimmerX = 1.3
            }
        }
    }
}

// MARK: - C: Dual snakes moving in opposite directions

private struct DualSnakeIsland: View {
    @State private var startTime: Date?

    var body: some View {
        ZStack(alignment: .top) {
            // Soft glow
            islandShape
                .fill(procBlue.opacity(0.15))
                .frame(width: islandW + 10, height: islandH + 6)
                .blur(radius: 15)

            // Island body
            islandShape
                .fill(trueBlack)
                .frame(width: islandW, height: islandH)

            // Dual snake canvas
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
                    let pts = buildContour(in: size)
                    drawDualSnakes(ctx: ctx, pts: pts, time: time)
                }
            }
            .frame(width: islandW, height: islandH)
            .clipShape(islandShape)

            // Edge glow
            islandShape
                .stroke(procBlue.opacity(0.3), lineWidth: 1)
                .frame(width: islandW, height: islandH)

            // Camera dot
            Circle().fill(Color(white: 0.1)).frame(width: 7, height: 7)
                .padding(.top, 10)

            // Label
            Text("TRANSCRIBING")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7)).tracking(1)
                .padding(.top, 24)
        }
    }

    /// Contour from notch edges: left-down → BL arc → bottom → BR arc → right-up (NO top edge)
    /// Same as red voice pulse — starts at top-left, ends at top-right
    private func buildContour(in size: CGSize) -> [CGPoint] {
        let w = size.width, h = size.height, r = islandR
        let n = 25
        var pts: [CGPoint] = []

        // Left side down (from top-left corner)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            pts.append(CGPoint(x: 0, y: 6 + t * (h - 6 - r)))
        }
        // BL arc
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let a = CGFloat.pi - t * CGFloat.pi / 2
            pts.append(CGPoint(x: r + r * cos(a), y: h - r + r * sin(a)))
        }
        // Bottom
        for i in 0..<(n * 2) {
            let t = CGFloat(i) / CGFloat(n * 2 - 1)
            pts.append(CGPoint(x: r + t * (w - 2 * r), y: h))
        }
        // BR arc
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let a = CGFloat.pi / 2 - t * CGFloat.pi / 2
            pts.append(CGPoint(x: w - r + r * cos(a), y: h - r + r * sin(a)))
        }
        // Right side up (to top-right corner)
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            pts.append(CGPoint(x: w, y: h - r - t * (h - 6 - r)))
        }
        return pts
    }

    private func drawDualSnakes(ctx: GraphicsContext, pts: [CGPoint], time: Double) {
        let total = pts.count
        guard total > 1 else { return }

        // Dim base contour
        var basePath = Path()
        for (i, pt) in pts.enumerated() {
            if i == 0 { basePath.move(to: pt) } else { basePath.addLine(to: pt) }
        }
        basePath.closeSubpath()
        ctx.stroke(basePath, with: .color(procBlue.opacity(0.06)),
                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        // Snake 1: clockwise
        let speed = 4.0
        let phase1 = (time / speed).truncatingRemainder(dividingBy: 1.0)
        drawSnake(ctx: ctx, pts: pts, headFrac: phase1, color: procBlue)

        // Snake 2: counter-clockwise
        let phase2 = (1.0 - phase1).truncatingRemainder(dividingBy: 1.0)
        drawSnake(ctx: ctx, pts: pts, headFrac: phase2, color: procBlue)
    }

    private func drawSnake(ctx: GraphicsContext, pts: [CGPoint], headFrac: CGFloat, color: Color) {
        let total = pts.count
        let headIdx = Int(headFrac * CGFloat(total - 1))
        let tailLen = Int(Double(total) * 0.2)

        for off in stride(from: tailLen, through: 0, by: -1) {
            let idx = (headIdx - off + total) % total
            let nextIdx = (idx + 1) % total
            let frac = 1.0 - CGFloat(off) / CGFloat(tailLen)
            let alpha = frac * frac * 0.8
            let w = 1.5 + frac * 2.5

            var seg = Path()
            seg.move(to: pts[idx])
            seg.addLine(to: pts[nextIdx])
            ctx.stroke(seg, with: .color(color.opacity(alpha)),
                       style: StrokeStyle(lineWidth: w, lineCap: .round))

            if frac > 0.4 {
                ctx.stroke(seg, with: .color(color.opacity(frac * 0.2)),
                           style: StrokeStyle(lineWidth: w + 4, lineCap: .round))
            }
        }

        // Head glow
        let hp = pts[headIdx]
        for (radius, opacity) in [(CGFloat(10), 0.15), (CGFloat(6), 0.3), (CGFloat(3), 0.6)] as [(CGFloat, Double)] {
            let p = Path(ellipseIn: CGRect(x: hp.x - radius, y: hp.y - radius, width: radius * 2, height: radius * 2))
            ctx.fill(p, with: .color(color.opacity(opacity)))
        }
    }
}

// MARK: - Window Controller

@MainActor
final class AnimationTestWindowController {
    private var window: NSWindow?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = AnimationTestView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Animation Test Bench"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

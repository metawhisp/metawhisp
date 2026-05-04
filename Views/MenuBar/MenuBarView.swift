import SwiftUI

struct MenuBarView: View {
    @ObservedObject var coordinator: TranscriptionCoordinator
    @ObservedObject var recorder: AudioRecordingService
    @ObservedObject var meetingRecorder: MeetingRecorder
    @ObservedObject var screenContext: ScreenContextService
    @ObservedObject private var settings = AppSettings.shared
    var closePopover: () -> Void = {}
    var openMainWindow: () -> Void = {}
    var onMeetingToggle: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            meetingStrip
            screenContextStrip
            stageContent
            lastOutput
            errorView
            controls
            footer
        }
        .background(MW.bg)
        // Specular rim — top-down white gradient, fades by 30% mark.
        // Mirror of the design's `.popover::before` pseudo-element.
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Color.white.opacity(0.18), Color.white.opacity(0.04), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 80)
            .allowsHitTesting(false)
            .blendMode(.plusLighter)
            .opacity(0.6)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(MW.border, lineWidth: MW.hairline)
        )
        .animation(.easeInOut(duration: 0.25), value: coordinator.stage)
        .frame(width: 300)
    }

    // MARK: - Status Strip

    private var statusStrip: some View {
        HStack(spacing: 8) {
            // Status dot — green-pulse idle, red-pulse recording, blue processing, accent translating.
            // Replaces the old conditional stageIcon — single primitive, color-driven by state.
            statusDot
            Text(statusLabel.uppercased())
                .font(MW.label).tracking(1.8).lineLimit(1)
                .foregroundStyle(coordinator.stage == .idle ? MW.textSecondary : .white)

            if coordinator.stage == .processing || coordinator.stage == .postProcessing {
                BounceDots()
            }

            Spacer()
            stageTrailing
        }
        .padding(.horizontal, MW.sp16)
        .padding(.vertical, MW.sp8)
        .background(coordinator.stage == .idle ? .clear : Color.white.opacity(0.04))
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
        .overlay(alignment: .bottom) {
            if coordinator.stage == .processing || coordinator.stage == .postProcessing {
                ScanLine()
            }
        }
    }

    /// Status pulse dot — color + glow driven by current stage. Mirrors design
    /// spec `.sdot.ok / .alert / .warn / .muted`. Pulses on idle (slow) and
    /// recording (fast); steady on processing/translating.
    @ViewBuilder
    private var statusDot: some View {
        switch coordinator.stage {
        case .idle:
            PulsingDot(color: MW.idle, size: 7, period: 1.6)
        case .recording:
            PulsingDot(color: MW.live, size: 7, period: 1.0)
        case .processing:
            Circle().fill(MW.processing).frame(width: 7, height: 7)
                .shadow(color: MW.processing.opacity(0.6), radius: 3)
        case .postProcessing:
            Circle().fill(MW.accent).frame(width: 7, height: 7)
                .shadow(color: MW.accent.opacity(0.6), radius: 3)
        }
    }

    @ViewBuilder
    private var stageTrailing: some View {
        switch coordinator.stage {
        case .idle:
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")").font(MW.monoSm).foregroundStyle(MW.textMuted)
        case .recording:
            RecordingTimer()
        case .processing:
            if let result = coordinator.lastResult {
                Text(String(format: "%.1fs AUDIO", result.duration))
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        case .postProcessing:
            if coordinator.translateNext {
                Text("\(settings.transcriptionLanguage.uppercased()) → \(settings.translateTo.uppercased())")
                    .font(MW.monoSm).foregroundStyle(MW.textSecondary)
            } else {
                Text("AI").font(MW.monoSm).foregroundStyle(MW.textSecondary)
            }
        }
    }

    // MARK: - Meeting Strip

    @ViewBuilder
    private var meetingStrip: some View {
        if settings.meetingRecordingEnabled {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if meetingRecorder.isRecording {
                        Circle().fill(MW.live).frame(width: 5, height: 5)
                            .shadow(color: .red.opacity(0.5), radius: 3)
                        Text("MEETING RECORDING").font(MW.label).tracking(1).foregroundStyle(.white)
                        Spacer()
                        MeetingTimer(startDate: meetingRecorder.recordingStartedAt)
                        Button {
                            onMeetingToggle()
                        } label: {
                            Text("STOP")
                                .font(MW.label).tracking(0.8)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(
                                    Capsule().fill(MW.live.opacity(0.20))
                                        .overlay(Capsule().stroke(MW.live.opacity(0.45), lineWidth: 0.5))
                                )
                        }
                        .buttonStyle(.plain)
                    } else if meetingRecorder.isStarting {
                        ProgressView().controlSize(.mini)
                        Text("STARTING...").font(MW.label).tracking(1).foregroundStyle(MW.textSecondary)
                        Spacer()
                    } else {
                        Image(systemName: "video").font(.system(size: 9)).foregroundStyle(MW.textMuted)
                        if let app = SystemAudioCaptureService.detectActiveMeetingApp() {
                            Text("\(app.uppercased()) DETECTED").font(MW.label).tracking(1).foregroundStyle(MW.textSecondary)
                        } else {
                            Text("NO MEETING").font(MW.label).tracking(1).foregroundStyle(MW.textMuted)
                        }
                        Spacer()
                        Button {
                            onMeetingToggle()
                        } label: {
                            Text("RECORD")
                                .font(MW.label).tracking(0.8)
                                .foregroundStyle(MW.textPrimary)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(
                                    Capsule().fill(Color.white.opacity(0.08))
                                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MW.sp16)
                .padding(.vertical, 6)
                .background(meetingRecorder.isRecording ? Color.red.opacity(0.08) : .clear)

                // Live waveform during active recording — shows mic+system audio level
                // (FEAT-0001§ui-contract.waveform)
                if meetingRecorder.isRecording {
                    MeetingWaveform(bars: meetingRecorder.audioBars)
                }

                // Surface permission / setup errors so user knows why recording didn't start.
                // Clickable — opens System Settings when error is about permissions.
                if let err = meetingRecorder.lastError {
                    Button {
                        // If the error is about screen recording, open that pane directly.
                        // Keyword match is crude but works for our known error strings.
                        if err.lowercased().contains("screen recording") || err.contains("🎥") {
                            PermissionsService.shared.openScreenRecordingSettings()
                        } else if err.lowercased().contains("microphone") || err.contains("🎤") {
                            PermissionsService.shared.openMicrophoneSettings()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(err)
                                .font(MW.monoSm).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 9))
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .padding(.horizontal, MW.sp16).padding(.vertical, 4)
                        .background(Color.red.opacity(0.08))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Warn if mic didn't join (user's voice won't be captured)
                if meetingRecorder.isRecording && meetingRecorder.micOnlyMode {
                    Text("⚠️ Mic unavailable — only other participants will be captured")
                        .font(MW.monoSm).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MW.sp16).padding(.vertical, 4)
                        .background(Color.orange.opacity(0.08))
                }
            }
            .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
        }
    }

    // MARK: - Screen Context Strip

    /// Shows that Screen Context monitoring is active + last captured app/window.
    /// (spec://intelligence/FEAT-0002#ui-indicator)
    @ViewBuilder
    private var screenContextStrip: some View {
        if settings.screenContextEnabled && screenContext.isActive {
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .font(.system(size: 9))
                    .foregroundStyle(MW.textMuted)
                Text("SCREEN CONTEXT")
                    .font(MW.label).tracking(1)
                    .foregroundStyle(MW.textMuted)
                Spacer()
                if let ctx = screenContext.lastContext {
                    Text(ctx.appName.uppercased())
                        .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("WATCHING...")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
                // Small pulsing indicator so user sees "alive"
                Circle().fill(MW.idle).frame(width: 5, height: 5)
            }
            .padding(.horizontal, MW.sp16)
            .padding(.vertical, 5)
            .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
        }
    }

    // MARK: - Stage Content (dynamic middle section)

    @ViewBuilder
    private var stageContent: some View {
        switch coordinator.stage {
        case .idle:
            EmptyView()
        case .recording:
            AudioLevelWave(bars: recorder.audioBars)
                .padding(MW.sp16)
                .transition(.opacity)
        case .processing:
            VStack(alignment: .leading, spacing: MW.sp4) {
                HStack(spacing: 0) {
                    if let result = coordinator.lastResult {
                        Text(result.text)
                            .font(MW.mono).foregroundStyle(MW.textPrimary)
                            .lineLimit(2)
                    } else {
                        Text("...")
                            .font(MW.mono).foregroundStyle(MW.textMuted)
                    }
                    BlinkingCursor()
                }
            }
            .padding(MW.sp16)
            .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
            .transition(.opacity)
        case .postProcessing:
            if coordinator.translateNext, let result = coordinator.lastResult {
                VStack(alignment: .leading, spacing: MW.sp8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.transcriptionLanguage.uppercased())
                            .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        Text(result.text)
                            .font(MW.mono).foregroundStyle(MW.textMuted).lineLimit(1)
                    }
                    Rectangle().fill(MW.border).frame(height: MW.hairline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.translateTo.uppercased())
                            .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        HStack(spacing: 0) {
                            Text("...")
                                .font(MW.mono).foregroundStyle(MW.textPrimary)
                            BlinkingCursor()
                        }
                    }
                }
                .padding(MW.sp16)
                .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
                .transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(MW.textSecondary)
                    Text(" Processing").font(MW.mono).foregroundStyle(MW.textSecondary)
                    BlinkingCursor()
                }
                .padding(MW.sp16)
                .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
                .transition(.opacity)
            }
        }
    }

    // MARK: - Last Output

    @State private var showCopied = false

    private var lastOutput: some View {
        Group {
            if let result = coordinator.lastResult, coordinator.stage == .idle {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.text, forType: .string)
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { showCopied = false }
                } label: {
                    VStack(alignment: .leading, spacing: MW.sp4) {
                        HStack {
                            Text(showCopied ? "COPIED" : "LAST OUTPUT")
                                .font(MW.label).tracking(1.5)
                                .foregroundStyle(showCopied ? .white : MW.textMuted)
                                .animation(.easeInOut(duration: 0.2), value: showCopied)
                            Spacer()
                            if let lang = result.language {
                                Text(lang.uppercased()).font(MW.monoSm).foregroundStyle(MW.textSecondary)
                                Text("\u{2022}").font(MW.monoSm).foregroundStyle(MW.textMuted)
                            }
                            Text(String(format: "%.1fs", result.processingTime))
                                .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        }
                        Text(result.text)
                            .font(MW.mono).foregroundStyle(MW.textPrimary)
                            .lineLimit(3).lineSpacing(3)
                    }
                    .padding(MW.sp16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
            }
        }
    }

    // MARK: - Error

    private var errorView: some View {
        Group {
            if let error = coordinator.lastError {
                Text(error)
                    .font(MW.monoSm).foregroundStyle(.red)
                    .padding(.horizontal, MW.sp16).padding(.vertical, MW.sp8)
                    .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                coordinator.toggle()
            } label: {
                controlBtn(
                    icon: coordinator.stage == .recording ? "stop.fill" : "mic.fill",
                    label: coordinator.stage == .recording ? "STOP" : "RECORD",
                    hint: "R\u{2318}",
                    active: coordinator.stage == .recording
                )
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(coordinator.stage == .processing || coordinator.stage == .postProcessing)

            Rectangle().fill(MW.border).frame(width: 0.5)

            Button {
                coordinator.toggleWithTranslation()
            } label: {
                controlBtn(
                    icon: "globe",
                    label: "TRANSLATE",
                    hint: "R\u{2325}",
                    active: coordinator.translateNext
                )
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(coordinator.stage == .processing || coordinator.stage == .postProcessing)
        }
        .frame(height: 44)
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
    }

    /// Action-grid button per design A: accent icon, label tracked, hotkey
    /// badge right-aligned. Compact: padding 8×10, icon 11pt. Matches the old
    /// 48pt-height action row height-wise; only chrome (accent icon, capsule
    /// hotkey) is the Liquid Glass refresh.
    private func controlBtn(icon: String, label: String, hint: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? .white : MW.accent)
                .frame(width: 14, height: 14)
            Text(label)
                .font(MW.label).tracking(0.6).lineLimit(1).fixedSize()
                .foregroundStyle(active ? .white : MW.textPrimary)
            Spacer(minLength: 4)
            Keycap(text: hint).layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(active ? Color.white.opacity(0.06) : .clear)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button { openMainWindow() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape").font(.system(size: 10, weight: .regular))
                    Text("SETTINGS").font(MW.label).tracking(1.0)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(MW.textMuted)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(radius: MW.rSmall))

            Button { NSApplication.shared.terminate(nil) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .regular))
                    Text("QUIT").font(MW.label).tracking(1.0)
                }
                .frame(maxWidth: .infinity)
                .foregroundStyle(MW.textMuted)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle(radius: MW.rSmall))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    private var statusLabel: String {
        switch coordinator.stage {
        case .idle: "Ready"
        case .recording: "Recording"
        case .processing: "Transcribing"
        case .postProcessing: coordinator.translateNext ? "Translating" : "Processing"
        }
    }
}

// MARK: - Recording Timer

private struct RecordingTimer: View {
    @State private var elapsed: TimeInterval = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(formatted)
            .font(MW.mono).foregroundStyle(MW.textSecondary)
            .onReceive(timer) { _ in elapsed += 1 }
    }

    private var formatted: String {
        let m = Int(elapsed) / 60
        let s = Int(elapsed) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Audio Level Wave (mini oscilloscope)

private struct AudioLevelWave: View {
    let bars: [Float]

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let midY = h / 2
            let count = bars.count
            guard count > 0 else { return }

            // Subtle center line
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: midY))
            centerLine.addLine(to: CGPoint(x: w, y: midY))
            context.stroke(centerLine, with: .color(Color.white.opacity(0.06)),
                           style: StrokeStyle(lineWidth: 0.5))

            let gap: CGFloat = 2
            let barW: CGFloat = max(2, (w - CGFloat(count - 1) * gap) / CGFloat(count))
            let maxBarH = h * 0.42

            for i in 0..<count {
                let val = CGFloat(bars[i])
                let barH = max(1.5, val * maxBarH)
                let x = CGFloat(i) * (barW + gap)

                // Bar going UP from center
                let upRect = CGRect(x: x, y: midY - barH, width: barW, height: barH)
                let upPath = Path(roundedRect: upRect, cornerRadius: barW / 2)
                let alpha = 0.3 + val * 0.7
                context.fill(upPath, with: .color(Color.white.opacity(alpha)))

                // Mirror going DOWN (dimmer, shorter)
                let downH = barH * 0.55
                let downRect = CGRect(x: x, y: midY, width: barW, height: downH)
                let downPath = Path(roundedRect: downRect, cornerRadius: barW / 2)
                context.fill(downPath, with: .color(Color.white.opacity(alpha * 0.3)))
            }
        }
        .animation(.easeOut(duration: 0.06), value: bars)
        .frame(height: 50)
        .mwCard(radius: MW.rSmall, elevation: .flat)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(MW.border, lineWidth: MW.hairline)
        )
    }
}

// MARK: - Blinking Cursor

struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: 1.5, height: 14)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - Bounce Dots (animated ellipsis)

private struct BounceDots: View {
    @State private var step = 0
    let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(Color.white)
                    .frame(width: 2, height: 2)
                    .opacity(i <= step ? 0.9 : 0.15)
            }
        }
        .onReceive(timer) { _ in step = (step + 1) % 4 }
    }
}

// MARK: - Scan Line (indeterminate progress)

private struct ScanLine: View {
    @State private var pos: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.white.opacity(0.35), .clear],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 80, height: MW.hairline)
                .offset(x: pos * (w + 80) - 80)
        }
        .frame(height: MW.hairline)
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { pos = 1 }
        }
    }
}

// MARK: - Meeting Timer

/// Timer based on the meeting's actual start date + TimelineView for tick updates.
/// The start date is sourced from `MeetingRecorder.recordingStartedAt` so the
/// elapsed counter is correct no matter when the user opens the popover. If the
/// start date is nil (recording not yet active), shows 00:00.
private struct MeetingTimer: View {
    let startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = startDate.map { context.date.timeIntervalSince($0) } ?? 0
            Text(formatted(elapsed))
                .font(MW.mono).foregroundStyle(MW.live)
        }
    }

    private func formatted(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Meeting Waveform (compact, red-tinted for recording context)

/// Compact waveform strip shown under the meeting recording indicator.
/// Distinct from AudioLevelWave: shorter (32pt), red tint, mirrored bars
/// reflecting max(mic, system) level from MeetingRecorder.
private struct MeetingWaveform: View {
    let bars: [Float]

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let midY = h / 2
            let count = bars.count
            guard count > 0 else { return }

            let gap: CGFloat = 2
            let barW: CGFloat = max(2, (w - CGFloat(count - 1) * gap) / CGFloat(count))
            let maxBarH = h * 0.42

            for i in 0..<count {
                let val = CGFloat(bars[i])
                let barH = max(1.5, val * maxBarH)
                let x = CGFloat(i) * (barW + gap)

                // Top bar — full opacity red
                let topRect = CGRect(x: x, y: midY - barH, width: barW, height: barH)
                let alpha = 0.4 + val * 0.6
                context.fill(Path(roundedRect: topRect, cornerRadius: barW / 2),
                             with: .color(Color.red.opacity(alpha)))

                // Mirror bottom — dimmer
                let downH = barH * 0.55
                let downRect = CGRect(x: x, y: midY, width: barW, height: downH)
                context.fill(Path(roundedRect: downRect, cornerRadius: barW / 2),
                             with: .color(Color.red.opacity(alpha * 0.35)))
            }
        }
        .animation(.easeOut(duration: 0.06), value: bars)
        .frame(height: 32)
        .background(Color.red.opacity(0.04))
    }
}

// MARK: - Pulsing Dot (status indicator)

/// 7px circle with state-color glow + opacity pulse. Used in the status strip
/// to mirror design's `.sdot.ok / .alert` animations (1.6s ok pulse, 1.0s alert).
private struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    let period: Double

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
            .opacity(dim ? 0.55 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

// MARK: - Hover Button Style (action grid + footer hover bg)

/// Plain button with hover-tinted background. Mirrors design's `.act:hover`
/// and `.fbtn:hover` patterns. macOS-only — `.onHover` is the cheap path.
private struct HoverButtonStyle: ButtonStyle {
    var radius: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(radius: radius, isPressed: configuration.isPressed) {
            configuration.label
        }
    }

    private struct HoverButtonBody<Label: View>: View {
        let radius: CGFloat
        let isPressed: Bool
        @ViewBuilder let content: () -> Label

        @State private var hovering = false

        var body: some View {
            content()
                .background(
                    Group {
                        if hovering || isPressed {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(Color.white.opacity(isPressed ? 0.10 : 0.06))
                        } else {
                            Color.clear
                        }
                    }
                )
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Audio Level Bar (legacy, kept for compatibility)

struct AudioLevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: MW.spaceXs)
                .fill(MW.accent)
                .frame(width: geometry.size.width * CGFloat(min(level * 10, 1.0)))
                .animation(.linear(duration: 0.1), value: level)
        }
        .background(Color.white.opacity(0.1))
        .cornerRadius(MW.spaceXs)
    }
}

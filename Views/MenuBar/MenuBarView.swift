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
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(MW.border, lineWidth: MW.hairline)
        )
        .animation(.easeInOut(duration: 0.25), value: coordinator.stage)
        .frame(width: 300)
    }

    // MARK: - Status Strip

    private var statusStrip: some View {
        HStack(spacing: 6) {
            stageIcon
            Text(statusLabel.uppercased())
                .font(MW.label).tracking(1.5).lineLimit(1)
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

    @ViewBuilder
    private var stageIcon: some View {
        switch coordinator.stage {
        case .idle:
            EmptyView()
        case .recording:
            Circle().fill(MW.live).frame(width: 5, height: 5)
                .shadow(color: .red.opacity(0.5), radius: 3)
        case .processing:
            Image(systemName: "brain")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
        case .postProcessing:
            Image(systemName: "globe")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var stageTrailing: some View {
        switch coordinator.stage {
        case .idle:
            Text("v0.0.1").font(MW.monoSm).foregroundStyle(MW.textMuted)
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
                        MeetingTimer()
                        Button {
                            onMeetingToggle()
                        } label: {
                            Text("STOP")
                                .font(MW.label).tracking(0.5)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(Rectangle().stroke(Color.white.opacity(0.3), lineWidth: MW.hairline))
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
                                .font(MW.label).tracking(0.5)
                                .foregroundStyle(MW.textPrimary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .overlay(Rectangle().stroke(MW.borderLight, lineWidth: MW.hairline))
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
            .buttonStyle(.plain)
            .disabled(coordinator.stage == .processing || coordinator.stage == .postProcessing)

            Rectangle().fill(MW.border).frame(width: MW.hairline)

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
            .buttonStyle(.plain)
            .disabled(coordinator.stage == .processing || coordinator.stage == .postProcessing)
        }
        .frame(height: 48)
        .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)
    }

    private func controlBtn(icon: String, label: String, hint: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(label).font(MW.label).tracking(0.5).lineLimit(1).fixedSize()
            Spacer()
            Keycap(text: hint).layoutPriority(1)
        }
        .foregroundStyle(active ? .white : MW.textSecondary)
        .padding(.horizontal, MW.sp8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .background(active ? Color.white.opacity(0.04) : .clear)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button { openMainWindow() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gear").font(.system(size: 9))
                    Text("SETTINGS").font(MW.label).tracking(1)
                }
                .foregroundStyle(MW.textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button { NSApplication.shared.terminate(nil) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power").font(.system(size: 9))
                    Text("QUIT").font(MW.label).tracking(1)
                }
                .foregroundStyle(MW.textMuted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MW.sp16)
        .padding(.vertical, MW.sp8)
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
        .background(MW.surface)
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

/// Timer based on a fixed start date + TimelineView for tick updates.
/// Using a start date + TimelineView survives frequent parent re-renders
/// (the meeting strip rebuilds on every audio sample — Timer.publish inside
/// a @State-based view gets its subscription torn down each render).
private struct MeetingTimer: View {
    @State private var startDate = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(formatted(context.date.timeIntervalSince(startDate)))
                .font(MW.mono).foregroundStyle(MW.live)
        }
    }

    private func formatted(_ elapsed: TimeInterval) -> String {
        let total = max(0, Int(elapsed))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
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

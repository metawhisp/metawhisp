import AppKit
import Combine
import SwiftUI

// MARK: - Observable state for the pill (avoids recreating NSHostingView)

@MainActor
final class PillState: ObservableObject {
    @Published var stage: TranscriptionCoordinator.Stage = .idle
    @Published var isTranslating: Bool = false
    @Published var audioLevel: Float = 0
    @Published var bars: [Float] = Array(repeating: 0, count: 8)
    @Published var style: String = "capsule"
}

/// Floating pill overlay that shows recording/transcribing state.
/// Uses NSPanel (level = .floating) so it appears above all windows.
@MainActor
final class RecordingOverlayController {
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var hideTimer: DispatchWorkItem?
    let pillState = PillState()
    private var lastStage: TranscriptionCoordinator.Stage = .idle
    private var isSelectionTranslating = false
    private var isPreviewing = false
    private var previewWork: [DispatchWorkItem] = []
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private let show: @MainActor (NSPanel) -> Void
    private let hide: @MainActor (NSPanel) -> Void
    private let isVoiceQuestionVisible: @MainActor () -> Bool

    /// The scheduler stage updates arrive on (`RunLoop.main`, default mode), so a hide never runs while
    /// an update that would keep the indicator still waits (e.g. during a window drag).
    nonisolated static let defaultSchedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
        RunLoop.main.schedule(after: .init(Date(timeIntervalSinceNow: delay))) { work.perform() }
    }

    init(schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = RecordingOverlayController.defaultSchedule,
         show: @escaping @MainActor (NSPanel) -> Void = { $0.orderFront(nil) },
         hide: @escaping @MainActor (NSPanel) -> Void = { $0.orderOut(nil) },
       isVoiceQuestionVisible: @escaping @MainActor () -> Bool = { VoiceQuestionState.shared.isVisible }) {
        self.schedule = schedule
        self.show = show
        self.hide = hide
        self.isVoiceQuestionVisible = isVoiceQuestionVisible
    }

    func bind(to coordinator: TranscriptionCoordinator, recorder: AudioRecordingService? = nil) {
        pillState.style = AppSettings.shared.pillStyle

        coordinator.$stage
            .receive(on: RunLoop.main)
            .sink { [weak self] stage in self?.handleStageChange(stage) }
            .store(in: &cancellables)

        // The island and the pill share the top centre: when the island opens
        // or closes, the pill follows the stage again (ITER-079 review).
        VoiceQuestionState.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self, weak coordinator] _ in
                guard let coordinator else { return }
                self?.handleStageChange(coordinator.stage)
            }
            .store(in: &cancellables)

        coordinator.$translateNext
            .receive(on: RunLoop.main)
            .sink { [weak self] val in
                self?.pillState.isTranslating = val
            }
            .store(in: &cancellables)

        // Stream audio data into pillState (no view recreation needed)
        if let recorder {
            recorder.$audioLevel
                .receive(on: RunLoop.main)
                .sink { [weak self] level in
                    self?.pillState.audioLevel = level
                }
                .store(in: &cancellables)

            recorder.$audioBars
                .receive(on: RunLoop.main)
                .sink { [weak self] bars in
                    self?.pillState.bars = bars
                }
                .store(in: &cancellables)
        }
    }

    func handleStageChange(_ stage: TranscriptionCoordinator.Stage) {
        lastStage = stage
        let voiceQuestionVisible = isVoiceQuestionVisible()
        if isPreviewing {
            if stage == .idle && !voiceQuestionVisible { return }
            endPreview()
        }
        hideTimer?.cancel()
        hideTimer = nil

        // Voice question (Phase 6) has its own floating panel — suppress the dictation pill
        // so they don't stack in top-center. spec://BACKLOG#Phase6
        if voiceQuestionVisible {
            if panel != nil { hidePanel() }
            pillState.stage = .idle
            return
        }

        switch stage {
        case .idle:
            pillState.stage = .idle
            if panel != nil {
                scheduleHide()
            }
        case .recording:
            pillState.style = AppSettings.shared.pillStyle
            showPanel()
            pillState.stage = .recording
        case .processing, .postProcessing:
            // Shown again when the island that hid it closes mid-transcription.
            if panel == nil {
                pillState.style = AppSettings.shared.pillStyle
                showPanel()
            }
            pillState.stage = stage
        }
    }

    // MARK: - Style Preview

    func preview(style: String) {
        guard lastStage == .idle, !isSelectionTranslating, !isVoiceQuestionVisible() else { return }
        endPreview()
        hideTimer?.cancel()
        hideTimer = nil
        hidePanel()

        isPreviewing = true
        pillState.style = style
        pillState.stage = .recording
        let voice = Self.previewVoice(at: 0)
        pillState.bars = voice.bars
        pillState.audioLevel = voice.audioLevel
        showPanel()

        for tick in 1..<60 {
            let elapsed = Double(tick) / 30
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let voice = Self.previewVoice(at: elapsed)
                self.pillState.bars = voice.bars
                self.pillState.audioLevel = voice.audioLevel
            }
            previewWork.append(work)
            schedule(elapsed, work)
        }
        let finish = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stopPreviewVoice()
            self.pillState.stage = .idle
            self.scheduleHide()
        }
        previewWork.append(finish)
        schedule(2.0, finish)
    }

    static func previewVoice(at elapsed: TimeInterval) -> (bars: [Float], audioLevel: Float) {
        let envelope = 0.2 + 0.6 * (sin(elapsed * 2 * .pi * 2.1) + 1) / 2
        let bars: [Float] = (0..<8).map { index in
            let phase = elapsed * (9 + Double(index)) + Double(index)
            let wave = (sin(phase) + 1) / 2
            return Float(0.08 + envelope * wave)
        }
        return (bars, bars.reduce(0, +) / Float(bars.count))
    }

    private func stopPreviewVoice() {
        previewWork.forEach { $0.cancel() }
        previewWork.removeAll()
        pillState.bars = Array(repeating: 0, count: 8)
        pillState.audioLevel = 0
    }

    private func endPreview() {
        guard isPreviewing else { return }
        stopPreviewVoice()
        hideTimer?.cancel()
        hideTimer = nil
        pillState.stage = .idle
        hidePanel()
        isPreviewing = false
    }

    private func scheduleHide() {
        hideTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hidePanel()
            self.isPreviewing = false
            self.hideTimer = nil
        }
        hideTimer = work
        schedule(0.8, work)
    }

    // MARK: - Panel Management

    private var pillStyle: String { AppSettings.shared.pillStyle }

    static func panelSize(for style: String, screenWidth: CGFloat) -> CGSize {
        switch style {
        case "dotglow": return CGSize(width: 1200, height: 800)  // Island Aura — notch + 2-layer aura bloom
        case "island":  return CGSize(width: 720, height: 240)   // Island Expand — notch + aura, window roomy enough so aura fades smoothly without clipping at panel edges
        case "glow":    return CGSize(width: screenWidth, height: 240) // Edge Glow — full width + falloff depth + voice-reactive headroom
        case "shrek":   return CGSize(width: 220, height: 220)   // Dancing-Shrek video — tight square around 200pt content + small breathing room
        // Capsule default: 360×120 — wider so the 28px state-coloured halo + 24px raised shadow
        // sit fully inside panel bounds. Previous 280×54 clipped the glow on top/bottom.
        default:        return CGSize(width: 360, height: 120)
        }
    }

    static func makePanel(style: String, screen: NSScreen?) -> NSPanel {
        let size = panelSize(for: style, screenWidth: screen?.frame.width ?? 1440)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Island + glow variants need to be ABOVE menu bar to sit flush at screen edge
        let isEdgeVariant = style == "island" || style == "dotglow" || style == "glow"
        panel.level = isEdgeVariant ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1) : .floating
        // Views draw their own shadows; a system shadow on a transparent panel traces their glow.
        panel.hasShadow = false
        // `.fullScreenAuxiliary` is critical: without it, when user is in
        // another app's fullscreen Space (e.g. Claude fullscreen) and starts
        // recording, macOS kicks them out to a neighboring Space to render
        // the pill. `MWWindowBehavior` is the single source of truth.
        panel.collectionBehavior = MWWindowBehavior.overlay
        panel.isMovableByWindowBackground = style != "glow" && style != "island" && style != "dotglow"
        panel.ignoresMouseEvents = isEdgeVariant
        panel.hidesOnDeactivate = false

        if let screen {
            let screenFrame = screen.frame
            let x: CGFloat
            let y: CGFloat

            switch style {
            case "glow":
                x = screenFrame.minX
                y = screenFrame.maxY - size.height
            case "island", "dotglow":
                x = screenFrame.midX - size.width / 2
                y = screenFrame.maxY - size.height  // From pixel 0 — extends the notch down
            default:
                x = screenFrame.midX - size.width / 2
                y = screen.visibleFrame.maxY - 70
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        return panel
    }

    private func showPanel() {
        guard panel == nil else { return }

        let panel = Self.makePanel(style: pillState.style, screen: NSScreen.main)
        let size = panel.frame.size

        // Create hosting view ONCE with observable pillState
        // Use .ignoresSafeArea to prevent SwiftUI from insetting content
        let rootView = PillRouterView(state: pillState).ignoresSafeArea()
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
        show(panel)
    }

    private func hidePanel() {
        if let panel { hide(panel) }
        panel = nil
    }

    // MARK: - Selection Translation Overlay

    func showTranslating() {
        endPreview()
        isSelectionTranslating = true
        pillState.style = pillStyle
        pillState.isTranslating = true
        pillState.stage = .postProcessing
        showPanel()
    }

    func hideTranslating() {
        isSelectionTranslating = false
        guard panel != nil else { return }
        pillState.stage = .idle
        scheduleHide()
    }
}

// MARK: - Pill Router View (observes PillState, never recreated)

struct PillRouterView: View {
    @ObservedObject var state: PillState

    var body: some View {
        switch state.style {
        case "dotglow":
            IslandAuraPillView(stage: state.stage, isTranslating: state.isTranslating, audioLevel: state.audioLevel, bars: state.bars)
        case "island":
            IslandPillView(stage: state.stage, isTranslating: state.isTranslating, audioLevel: state.audioLevel, bars: state.bars)
        case "glow":
            GlowStripPillView(stage: state.stage, audioLevel: state.audioLevel)
        case "shrek":
            ShrekPillView(stage: state.stage, isTranslating: state.isTranslating)
        default:
            CapsulePillView(stage: state.stage, isTranslating: state.isTranslating, audioLevel: state.audioLevel, bars: state.bars)
        }
    }
}

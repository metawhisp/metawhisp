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
    private var hideTimer: Timer?
    private let pillState = PillState()

    func bind(to coordinator: TranscriptionCoordinator, recorder: AudioRecordingService? = nil) {
        pillState.style = AppSettings.shared.pillStyle

        coordinator.$stage
            .receive(on: RunLoop.main)
            .sink { [weak self] stage in self?.handleStageChange(stage) }
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

    private func handleStageChange(_ stage: TranscriptionCoordinator.Stage) {
        hideTimer?.invalidate()
        hideTimer = nil

        // Voice question (Phase 6) has its own floating panel — suppress the dictation pill
        // so they don't stack in top-center. spec://BACKLOG#Phase6
        if VoiceQuestionState.shared.isVisible {
            if panel != nil { hidePanel() }
            pillState.stage = .idle
            return
        }

        switch stage {
        case .idle:
            pillState.stage = .idle
            if panel != nil {
                hideTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.hidePanel() }
                }
            }
        case .recording:
            pillState.style = AppSettings.shared.pillStyle
            showPanel()
            pillState.stage = .recording
        case .processing:
            pillState.stage = .processing
        case .postProcessing:
            pillState.stage = .postProcessing
        }
    }

    // MARK: - Panel Management

    private var pillStyle: String { AppSettings.shared.pillStyle }

    private var panelSize: (width: CGFloat, height: CGFloat) {
        let screenW = NSScreen.main?.frame.width ?? 1440
        switch pillStyle {
        case "dotglow": return (1200, 800)  // Island Aura — notch + massive 5x aura glow
        case "island":  return (360, 80)   // Island Expand — wider expanded notch
        case "glow":    return (screenW, 80)
        default:        return (280, 54)
        }
    }

    private func showPanel() {
        guard panel == nil else { return }

        let size = panelSize

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Island + glow variants need to be ABOVE menu bar to sit flush at screen edge
        let isEdgeVariant = pillStyle == "island" || pillStyle == "dotglow" || pillStyle == "glow"
        panel.level = isEdgeVariant ? NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1) : .floating
        panel.hasShadow = pillStyle != "glow" && !isEdgeVariant
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = pillStyle != "glow" && pillStyle != "island" && pillStyle != "dotglow"
        panel.ignoresMouseEvents = isEdgeVariant
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main {
            let screenFrame = screen.frame
            let x: CGFloat
            let y: CGFloat

            switch pillStyle {
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

        // Create hosting view ONCE with observable pillState
        // Use .ignoresSafeArea to prevent SwiftUI from insetting content
        let rootView = PillRouterView(state: pillState).ignoresSafeArea()
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel
        panel.orderFront(nil)
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    // MARK: - Selection Translation Overlay

    func showTranslating() {
        pillState.style = pillStyle
        pillState.isTranslating = true
        pillState.stage = .postProcessing
        showPanel()
    }

    func hideTranslating() {
        guard panel != nil else { return }
        pillState.stage = .idle
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
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
        default:
            CapsulePillView(stage: state.stage, isTranslating: state.isTranslating, audioLevel: state.audioLevel, bars: state.bars)
        }
    }
}

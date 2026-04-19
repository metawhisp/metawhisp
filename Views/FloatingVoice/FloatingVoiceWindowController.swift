import AppKit
import Combine
import SwiftUI

/// Manages the borderless floating window that displays voice-question status.
/// Shows/hides based on `VoiceQuestionState.shared.isVisible`.
///
/// spec://BACKLOG#Phase6
@MainActor
final class FloatingVoiceWindowController {
    private var window: NSPanel?
    private var hostingView: NSHostingView<FloatingVoiceView>?
    private var visibilityCancellable: AnyCancellable?
    private var escMonitor: Any?
    private var autoDismissTask: Task<Void, Never>?

    init() {
        // React to state changes.
        visibilityCancellable = VoiceQuestionState.shared.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                self?.reactToPhaseChange(phase)
            }
    }

    private func reactToPhaseChange(_ phase: VoiceQuestionState.Phase) {
        if case .idle = phase {
            // Ensure any ongoing TTS is silenced when the panel closes — Esc and auto-dismiss paths.
            AppDelegate.shared?.ttsService.stop()
            hideWindow()
        } else {
            showWindow()
            // Auto-dismiss for answered / error states after a delay.
            if case .answered = phase {
                scheduleAutoDismiss(seconds: 6)
            } else if case .error = phase {
                scheduleAutoDismiss(seconds: 4)
            } else {
                autoDismissTask?.cancel()
                autoDismissTask = nil
            }
        }
    }

    private func scheduleAutoDismiss(seconds: Double) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // Don't dismiss while still speaking.
            if VoiceQuestionState.shared.isSpeaking {
                self?.scheduleAutoDismiss(seconds: 2)
                return
            }
            VoiceQuestionState.shared.dismiss()
        }
    }

    private func showWindow() {
        if window == nil { createWindow() }
        guard let window else { return }
        if !window.isVisible {
            positionWindow(window)
            window.orderFrontRegardless()
            installEscMonitor()
        }
    }

    private func hideWindow() {
        removeEscMonitor()
        autoDismissTask?.cancel()
        autoDismissTask = nil
        window?.orderOut(nil)
    }

    private func createWindow() {
        let contentView = FloatingVoiceView(state: VoiceQuestionState.shared)
        let hosting = NSHostingView(rootView: contentView)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 180)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // SwiftUI view casts its own drop shadow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        self.window = panel
        self.hostingView = hosting
    }

    private func positionWindow(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        // Size grows with content — ask host view to size itself first.
        if let host = hostingView {
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            let width = max(420, min(fitting.width, 620))
            let height = max(120, min(fitting.height, 360))
            window.setContentSize(NSSize(width: width, height: height))
        }
        let size = window.frame.size
        // Top-center, 24pt from top for a bit of breathing room.
        let origin = NSPoint(
            x: visible.origin.x + (visible.width - size.width) / 2,
            y: visible.origin.y + visible.height - size.height - 24
        )
        window.setFrameOrigin(origin)
    }

    // MARK: - Esc dismiss

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Esc — dismiss panel (and stop TTS via phase=.idle observer).
            if event.keyCode == 53 {
                Task { @MainActor in
                    VoiceQuestionState.shared.dismiss()
                    self?.removeEscMonitor()
                }
                return nil
            }
            // Space — interrupt ongoing TTS only (keep panel visible so user can still read).
            if event.keyCode == 49, VoiceQuestionState.shared.isSpeaking {
                Task { @MainActor in
                    AppDelegate.shared?.ttsService.stop()
                    VoiceQuestionState.shared.isSpeaking = false
                }
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
    }
}

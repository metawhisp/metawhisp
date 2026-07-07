import AppKit
import Combine
import SwiftUI

/// Manages the borderless floating window that displays voice-question status.
/// Shows/hides based on `VoiceQuestionState.shared.isVisible`.
///
/// **Two-window design (ITER-050 B2.2 — copied from MeetingCoachWindowController).**
/// Click-through is a *structural* property here, not a runtime toggle:
///   - `cardWindow` — sized exactly to the visible pill. Interactive, so the
///     STOP button actually works. `nonactivatingPanel` keeps focus in the
///     user's app.
///   - `shadowWindow` — a child window `shadowPadding` larger per side that
///     renders ONLY the drop shadow and has `ignoresMouseEvents = true`, so
///     clicks around the pill pass straight through to the app beneath.
///
/// Replaces the single-panel `ClickThroughHostingView`, whose
/// ignoresMouseEvents+NSTrackingArea toggle left the panel permanently
/// click-through — user-reported: «не могу нажать в кнопку Stop».
///
/// spec://BACKLOG#Phase6
@MainActor
final class FloatingVoiceWindowController {
    private var cardWindow: NSPanel?
    private var shadowWindow: NSPanel?
    private var shadowView: CardShadowView?
    private var hostingView: SelfSizingHostingView<FloatingVoiceView>?
    private var visibilityCancellable: AnyCancellable?
    private var escMonitor: Any?
    private var globalEscMonitor: Any?
    private var autoDismissTask: Task<Void, Never>?

    /// Shadow breathing room per side: 2·radius 24 + |y| 12 = 60 — the no-clip
    /// rule for a blurred shadow's soft tail (same as MeetingCoach).
    private let shadowPadding: CGFloat = 60

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
        if cardWindow == nil { createWindows() }
        guard let cardWindow, let shadowWindow else { return }
        if !cardWindow.isVisible {
            positionTopCenter(cardWindow)
            // Order ONLY the parent — children come along; explicitly ordering
            // a child window detaches it from its parent (see MeetingCoach).
            cardWindow.orderFrontRegardless()
            if cardWindow.childWindows?.contains(shadowWindow) != true {
                cardWindow.addChildWindow(shadowWindow, ordered: .below)
            }
            updateShadowFrame()
            installEscMonitors()
        }
    }

    private func hideWindow() {
        removeEscMonitors()
        autoDismissTask?.cancel()
        autoDismissTask = nil
        cardWindow?.orderOut(nil)
        // Defensive: if the child relationship broke, hide the shadow directly.
        if let shadowWindow, shadowWindow.isVisible,
           cardWindow?.childWindows?.contains(shadowWindow) != true {
            shadowWindow.orderOut(nil)
        }
    }

    private func createWindows() {
        let hosting = SelfSizingHostingView(rootView: FloatingVoiceView(state: VoiceQuestionState.shared))
        hosting.onContentSizeChange = { [weak self] size in
            self?.updateCardSize(size)
        }
        self.hostingView = hosting

        // Card window — exactly the visible pill. Interactive; non-activating
        // so clicking STOP never steals focus from the app the user is in.
        let card = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        card.level = .floating
        card.isFloatingPanel = true
        card.hidesOnDeactivate = false
        card.becomesKeyOnlyIfNeeded = true
        card.backgroundColor = .clear
        card.isOpaque = false
        card.hasShadow = false  // shadow lives in the child window
        card.collectionBehavior = MWWindowBehavior.overlayFollowing
        card.ignoresMouseEvents = false
        card.contentView = hosting

        // Shadow window — child, below the card, transparent to mouse events.
        let shadowFrame = card.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        let shadow = NSPanel(
            contentRect: shadowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let shadowContent = CardShadowView(
            frame: NSRect(origin: .zero, size: shadowFrame.size),
            inset: shadowPadding,
            cornerRadius: 14,          // pill's clipShape radius
            shadowRadius: 24,
            shadowOpacity: 0.45,
            shadowYOffset: 12
        )
        shadow.isOpaque = false
        shadow.backgroundColor = .clear
        shadow.hasShadow = false
        shadow.level = card.level
        shadow.collectionBehavior = card.collectionBehavior
        shadow.ignoresMouseEvents = true
        shadow.hidesOnDeactivate = false
        shadow.contentView = shadowContent

        card.addChildWindow(shadow, ordered: .below)

        self.cardWindow = card
        self.shadowWindow = shadow
        self.shadowView = shadowContent

        // Force the first measurement so the card matches the content before
        // the window is shown, not on a later async layout pass.
        hosting.layoutSubtreeIfNeeded()
        hosting.reportCurrentSize()
    }

    /// Resize the card window to the measured pill size, keeping the top edge
    /// and horizontal center anchored (the pill grows downward as the answer
    /// streams in), then resync the shadow window.
    private func updateCardSize(_ size: CGSize) {
        guard let cardWindow, size.width > 0, size.height > 0 else { return }
        // Review fix — clamp like MeetingRecap: a degenerate or runaway
        // measurement must not produce a giant (screen-overflowing,
        // click-blocking) or invisible card. Content past the cap scrolls
        // inside the pill (FloatingVoiceView's ScrollView).
        let newSize = NSSize(
            width: ceil(min(max(size.width, 380), 420)),
            height: ceil(min(max(size.height, 56), 520))
        )
        var frame = cardWindow.frame
        guard abs(frame.width - newSize.width) > 0.5 ||
              abs(frame.height - newSize.height) > 0.5 else { return }
        let top = frame.maxY
        frame.origin.x = frame.midX - newSize.width / 2
        frame.origin.y = top - newSize.height
        frame.size = newSize
        cardWindow.setFrame(frame, display: true)
        updateShadowFrame()
    }

    private func updateShadowFrame() {
        guard let cardWindow, let shadowWindow else { return }
        let frame = cardWindow.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        shadowWindow.setFrame(frame, display: true)
        shadowView?.frame = NSRect(origin: .zero, size: frame.size)
        shadowView?.needsLayout = true
    }

    private func positionTopCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        if let host = hostingView {
            host.layoutSubtreeIfNeeded()
            host.reportCurrentSize()
        }
        let size = window.frame.size
        // Pill top sits `shadowPadding` below the visible top — same optics as
        // the old in-window 60pt envelope, and it leaves room for the halo.
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - shadowPadding
        )
        window.setFrameOrigin(origin)
    }

    // MARK: - Esc / Space keyboard handling

    private func installEscMonitors() {
        // Global monitor — the PRIMARY case (ITER-050 B2.4): the voice flow
        // starts while the user's focus is in ANOTHER app (the panel never
        // activates), so a local monitor never sees the keystroke. Global
        // monitors observe without consuming — Esc still reaches the frontmost
        // app, the acceptable trade-off for a passive overlay.
        if globalEscMonitor == nil {
            globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return }
                Task { @MainActor in
                    VoiceQuestionState.shared.dismiss()
                }
            }
        }
        // Local monitor — when MetaWhisp itself is frontmost. Review fix:
        // guard each key separately, not the whole monitor — a blanket
        // `keyWindow == nil` guard killed Esc-dismiss whenever the main
        // window was open at all.
        if escMonitor == nil {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    // The monitor exists ONLY while the voice popup is visible
                    // (installed in showWindow, removed in hideWindow), so Esc
                    // here always means "close the popup" — swallow it and
                    // dismiss, even if a text field is focused.
                    Task { @MainActor in
                        VoiceQuestionState.shared.dismiss()
                    }
                    return nil
                }
                // Space — interrupt ongoing TTS, but never while a MetaWhisp
                // window is key (Space in the MetaChat input used to vanish
                // while TTS was speaking).
                if event.keyCode == 49, VoiceQuestionState.shared.isSpeaking,
                   NSApp.keyWindow == nil {
                    Task { @MainActor in
                        AppDelegate.shared?.ttsService.stop()
                        VoiceQuestionState.shared.isSpeaking = false
                    }
                    return nil
                }
                return event
            }
        }
    }

    private func removeEscMonitors() {
        if let m = escMonitor {
            NSEvent.removeMonitor(m)
            escMonitor = nil
        }
        if let m = globalEscMonitor {
            NSEvent.removeMonitor(m)
            globalEscMonitor = nil
        }
    }
}

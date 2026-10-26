import AppKit
import Combine
import SwiftUI

/// Manages the borderless floating window that displays voice-question status.
/// Shows/hides based on `VoiceQuestionState.shared.isVisible`.
///
/// **The Island (ITER-078).** The window is the island itself: its frame
/// follows `VoiceIslandPresenter.shape`, animated for both windows together,
/// top centre just under the menu bar, and `VoiceIslandView` fills it. The
/// shadow window also draws the island's glow.
///
/// **Two-window design (ITER-050 B2.2 — copied from MeetingCoachWindowController).**
/// Click-through is a *structural* property here, not a runtime toggle:
///   - `cardWindow` — sized exactly to the visible pill. Interactive, so the
///     STOP button actually works. `nonactivatingPanel` keeps focus in the
///     user's app.
///   - `shadowWindow` — a child window `shadowPadding` larger per side that
///     renders only the drop shadow and the glow, and has
///     `ignoresMouseEvents = true`, so clicks around the pill pass straight
///     through to the app beneath.
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
    private var visibilityCancellable: AnyCancellable?
    private var shapeCancellable: AnyCancellable?
    private var stageCancellable: AnyCancellable?
    /// The current error has shaken once already.
    private var errorShaken = false
    /// Counts the island's moves: only the latest one's end may shake it.
    private var placement = 0
    /// Drives the island's stages, shape and characters (ITER-078).
    let presenter = VoiceIslandPresenter(
        phases: VoiceQuestionState.shared.$phase.eraseToAnyPublisher(),
        level: { AppDelegate.shared?.recorder.audioLevel ?? 0 },
        reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    )
    /// The island sits this far under the menu bar.
    private let gapUnderMenuBar: CGFloat = 10
    private var escMonitor: Any?
    private var globalEscMonitor: Any?
    private var autoDismissTask: Task<Void, Never>?

    /// Shadow breathing room per side: at least 2·radius + |y| for the drop
    /// shadow (2·18 + 12 = 48) and 2·radius for the glow (40) — the no-clip
    /// rule for a blurred shadow's soft tail.
    private let shadowPadding: CGFloat = 60

    init() {
        // The island's shape sets the window's frame (ITER-078).
        shapeCancellable = presenter.$shape
            .sink { [weak self] shape in
                MainActor.assumeIsolated {
                    guard let shape else { return }
                    self?.apply(shape)
                }
            }
        // The design's glow: red while it listens, faint red on an error.
        stageCancellable = presenter.$stage
            .sink { [weak self] stage in
                MainActor.assumeIsolated { self?.glow(for: stage) }
            }
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
        guard let question = VoiceQuestionState.shared.question else { return }
        scheduleAutoDismiss(seconds: seconds, question: question)
    }

    /// Closes `question` after `seconds` — only that question: a newer one
    /// that started in the meantime stays open (ITER-079 review). Internal so
    /// a test can fire it for an old question.
    func scheduleAutoDismiss(seconds: Double, question: UUID) {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            // Don't dismiss while still speaking.
            if VoiceQuestionState.shared.isSpeaking {
                self?.scheduleAutoDismiss(seconds: 2, question: question)
                return
            }
            VoiceQuestionState.shared.dismiss(ifStill: question)
        }
    }

    private func showWindow() {
        if cardWindow == nil { createWindows() }
        guard let cardWindow, let shadowWindow else { return }
        if !cardWindow.isVisible {
            placeTopCenter(presenter.shape ?? VoiceIsland.shape(for: .seed), animated: false)
            glow(for: presenter.stage)
            // Order ONLY the parent — children come along; explicitly ordering
            // a child window detaches it from its parent (see MeetingCoach).
            cardWindow.orderFrontRegardless()
            if cardWindow.childWindows?.contains(shadowWindow) != true {
                cardWindow.addChildWindow(shadowWindow, ordered: .below)
            }
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
        let hosting = NSHostingView(rootView: VoiceIslandView(presenter: presenter, state: VoiceQuestionState.shared))
        hosting.sizingOptions = []

        // Card window — exactly the island. Interactive; non-activating so
        // clicking Stop never steals focus from the app the user is in.
        let card = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 44, height: 14),
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
        let shadow = IslandShadowPanel(
            contentRect: shadowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // The island is glass: its shadow and glow are drawn only outside it,
        // or they would tint it from behind.
        let shadowContent = CardShadowView(
            frame: NSRect(origin: .zero, size: shadowFrame.size),
            inset: shadowPadding,
            cornerRadius: 7,
            shadowRadius: 18,
            shadowOpacity: 0.30,
            shadowYOffset: 12,
            cutsOutCard: true
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
    }

    private func glow(for stage: VoiceIsland.Stage?) {
        let red = NSColor(MW.live)
        if stage != .error { errorShaken = false }
        switch stage {
        case .seed, .listening: shadowView?.glow(red, opacity: 0.38)
        case .error: shadowView?.glow(red, opacity: 0.2)
        default: shadowView?.glow(nil, opacity: 0)
        }
    }

    /// An error shakes the whole island once, as in the design, after it has
    /// taken the error's shape — a shake running beside that move would leave
    /// the island where the move began. The shadow window, a child, moves with
    /// it. Not with Reduce Motion.
    private func shake() {
        guard let cardWindow, cardWindow.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let origin = cardWindow.frame.origin
        let shake = CAKeyframeAnimation()
        shake.values = [0, -9, 8, -6, 4, -2, 0].map { NSValue(point: NSPoint(x: origin.x + $0, y: origin.y)) }
        shake.duration = 0.5
        shake.calculationMode = .linear
        cardWindow.animations = ["frameOrigin": shake]
        cardWindow.animator().setFrameOrigin(origin)
        cardWindow.animations = [:]
    }

    /// The island took a new shape: both windows move to it, animated while
    /// it shows (ITER-078).
    private func apply(_ shape: VoiceIsland.Shape) {
        guard let cardWindow, cardWindow.isVisible else { return }
        placeTopCenter(shape, animated: true)
    }

    /// The island's frame on screen now, and its shadow window's (for tests).
    var islandFrame: NSRect? { cardWindow?.frame }
    var shadowFrame: NSRect? { shadowWindow?.frame }

    /// Where `shape` belongs: top centre, just under the menu bar and clear of
    /// the notch, no wider than the screen allows.
    func targetFrame(for shape: VoiceIsland.Shape) -> NSRect? {
        guard let screen = (cardWindow?.isVisible == true ? cardWindow?.screen : nil) ?? NSScreen.main else {
            return nil
        }
        let visible = screen.visibleFrame
        let fitted = shape.fitting(width: visible.width - 40)
        let top = VoiceIsland.top(visibleTop: visible.maxY, screenTop: screen.frame.maxY,
                                  safeAreaTop: screen.safeAreaInsets.top, gap: gapUnderMenuBar)
        return NSRect(x: (visible.midX - fitted.width / 2).rounded(), y: top - fitted.height,
                      width: fitted.width, height: fitted.height)
    }

    /// Moves both windows to `shape`'s frame, animated while the island shows.
    private func placeTopCenter(_ shape: VoiceIsland.Shape, animated: Bool) {
        guard let cardWindow, let shadowWindow, let target = targetFrame(for: shape) else { return }
        let shadowTarget = target.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        shadowView?.cornerRadius = min(shape.cornerRadius, target.height / 2)
        let moves = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        placement += 1
        let thisPlacement = placement
        // A shake still running would put the island back where it began:
        // stop it first.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            cardWindow.animator().setFrameOrigin(cardWindow.frame.origin)
        }
        // Through the animator either way: a frame set directly would not stop
        // a move still running.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = moves ? 0.45 : 0
            // Eases out, as the design's spring settles: a window's frame
            // animation does not go past its target, so there is no bounce.
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.2, 1)
            context.allowsImplicitAnimation = moves
            cardWindow.animator().setFrame(target, display: true)
            shadowWindow.animator().setFrame(shadowTarget, display: true)
        }, completionHandler: { [weak self] in
            // An error shakes once it has settled in its shape, and only after
            // the latest move: an older move can reach its own target before
            // it formally ends, and its end may come just after the error's
            // move has begun.
            MainActor.assumeIsolated {
                guard let self, thisPlacement == self.placement, self.presenter.stage == .error,
                      !self.errorShaken, self.cardWindow?.frame == target else { return }
                self.errorShaken = true
                self.shake()
            }
        })
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

/// The island's shadow window reaches above the menu bar by its padding, and
/// macOS would move it down, so the shadow and the glow fell 50 pt below the
/// island (ITER-078 review). Its frame is taken exactly as given.
final class IslandShadowPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

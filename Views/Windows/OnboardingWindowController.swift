import AppKit
import SwiftUI

/// Manages the onboarding window — shows on first launch, closable, non-resizable.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    var coordinator: TranscriptionCoordinator?
    var modelManager: ModelManagerService?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let coordinator, let modelManager else {
            NSLog("[Onboarding] No coordinator/modelManager — skipping")
            return
        }

        let onboardingView = OnboardingContainer(coordinator: coordinator, modelManager: modelManager) {
            self.complete()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to MetaWhisp"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        // macOS 26 Tahoe — same restoration-crash guard as MainWindowController.
        window.isRestorable = false
        window.level = .floating
        // Same Space-fix as MainWindowController: bring the window TO the user, don't teleport
        // them to a different Space on first launch.
        window.collectionBehavior = MWWindowBehavior.main

        self.window = window

        // Gentle activation only (ITER-050 B2.6): the aggressive
        // ignoring-other-apps form yanks the user across Spaces (see
        // WindowActivationGuardTests). The plain form still activates this
        // LSUIElement app on first launch (user-initiated open), which the
        // window needs to take keyboard focus.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        NSLog("[Onboarding] Showing onboarding window")
    }

    private func complete() {
        AppSettings.shared.hasCompletedOnboarding = true
        NSLog("[Onboarding] finished — engine=%@ model=%@ accessibility=%@", AppSettings.shared.transcriptionEngine, AppSettings.shared.selectedModel, AXIsProcessTrusted() ? "yes" : "no")
        window?.close()
        window = nil
        NSLog("[Onboarding] Completed")
    }
}

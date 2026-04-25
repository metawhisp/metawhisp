import AppKit
import SwiftUI

/// Manages the onboarding window — shows on first launch, closable, non-resizable.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    var coordinator: TranscriptionCoordinator?

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard let coordinator else {
            NSLog("[Onboarding] No coordinator — skipping")
            return
        }

        let onboardingView = OnboardingContainer(coordinator: coordinator) {
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
        window.level = .floating
        // Same Space-fix as MainWindowController: bring the window TO the user, don't teleport
        // them to a different Space on first launch.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        NSLog("[Onboarding] Showing onboarding window")
    }

    private func complete() {
        AppSettings.shared.hasCompletedOnboarding = true
        window?.close()
        window = nil
        NSLog("[Onboarding] Completed")
    }
}

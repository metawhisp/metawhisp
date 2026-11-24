import AppKit
import SwiftUI

/// ITER-085 — the Target window: the onboarding's 720 × 600 window (`OnboardingWindowController.makeWindow`), on the
/// Space the user is on. Shown after the update it comes up without taking the keyboard, so keys typed elsewhere
/// never press its buttons; opened from Settings it is the user's own window and takes it.
@MainActor
final class TargetIntroWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var flow: TargetIntroFlow?

    /// `turningOn`: a Free user tapped Target in Settings — the window opens as Turn on Target would, on the Pro screen.
    /// `takesFocus`: false for the showing after the update.
    func show(turningOn: Bool, takesFocus: Bool) {
        if window == nil || window?.isOnActiveSpace == false {
            window?.close()
            create()
        }
        if turningOn { flow?.turnOn() }
        guard let window else { return }
        if takesFocus { window.makeKeyAndOrderFront(nil) }
        window.orderFrontRegardless()
        NSLog("[TargetIntro] window shown (turningOn=%@, takesFocus=%@)", turningOn ? "yes" : "no", takesFocus ? "yes" : "no")
    }

    private func create() {
        let flow = TargetIntroFlow(close: { [weak self] in self?.window?.close() })
        let window = OnboardingWindowController.makeWindow(rootView: TargetIntroView(flow: flow, license: .shared))
        window.title = "Target"
        window.delegate = self
        window.center()
        self.window = window
        self.flow = flow
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let screen = flow?.screen { NSLog("[TargetIntro] window closed on %@", "\(screen)") }
        flow = nil
        window = nil
    }
}

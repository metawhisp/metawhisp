import AppKit
import SwiftUI

/// Manages the main application window (singleton — only one instance).
@MainActor
final class MainWindowController {
    private var window: NSWindow?

    func open(
        coordinator: TranscriptionCoordinator,
        modelManager: ModelManagerService,
        recorder: AudioRecordingService,
        historyService: HistoryService
    ) {
        // If window already exists, bring it to front
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let contentView = MainWindowView(
            coordinator: coordinator,
            modelManager: modelManager,
            recorder: recorder,
            historyService: historyService
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MetaWhisp"
        window.minSize = NSSize(width: 500, height: 400)
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false

        self.window = window

        // Switch to regular app so we get full keyboard focus (LSUIElement blocks it)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // Watch for window close to switch back to accessory (hide from Dock)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.window = nil
            NSApp.setActivationPolicy(.accessory)
        }

        NSLog("[MainWindow] Opened")
    }

    func close() {
        window?.close()
        window = nil
    }
}

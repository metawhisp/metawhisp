import AppKit
import SwiftUI

extension Notification.Name {
    static let switchMainTab = Notification.Name("MetaWhisp.switchMainTab")
}

/// Manages the main application window (singleton — only one instance).
@MainActor
final class MainWindowController {
    private var window: NSWindow?

    /// Collection behavior applied to the main window on create / reactivate.
    /// `.moveToActiveSpace` makes macOS pull the window TO the user instead of pulling
    /// the user to a different Space. `.fullScreenAuxiliary` keeps it co-existing over
    /// fullscreen apps so we never trigger a Space swap on activation.
    private static let windowBehavior: NSWindow.CollectionBehavior =
        [.moveToActiveSpace, .fullScreenAuxiliary]

    func open(
        coordinator: TranscriptionCoordinator,
        modelManager: ModelManagerService,
        recorder: AudioRecordingService,
        historyService: HistoryService,
        projectAggregator: ProjectAggregator,
        initialTab: MainWindowView.SidebarTab? = nil
    ) {
        // If window already exists, bring it to front (and switch tab if requested)
        if let window, window.isVisible {
            if let tab = initialTab {
                NotificationCenter.default.post(name: .switchMainTab, object: tab)
            }
            // Re-apply in case macOS reset it (rare, but cheap to be explicit).
            window.collectionBehavior = Self.windowBehavior
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let contentView = MainWindowView(
            coordinator: coordinator,
            modelManager: modelManager,
            recorder: recorder,
            historyService: historyService,
            initialTab: initialTab ?? .dashboard
        )
        .environmentObject(projectAggregator)

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
        // Key fix: `.moveToActiveSpace` tells macOS to move the window to the user's current
        // Space when activating, instead of SWAPPING the user to the Space where the window
        // was last seen. Without this, every relaunch / activate drags the user away from
        // whatever they were doing. `.fullScreenAuxiliary` lets the window co-exist over
        // fullscreen apps rather than forcing a Space switch.
        window.collectionBehavior = Self.windowBehavior

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

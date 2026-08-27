import AppKit
import Foundation

/// ⌘⌥O — open the Screen Agent Inbox from anywhere.
///
/// A comment used to be reachable only while its card was on screen: miss the
/// glance and the only way back was to happen to open the app and find the
/// pane. Every product that shows a transient surface ships a way to summon
/// the last one, because a message you cannot get back to is a message that
/// depends on the user being at the keyboard at the right second.
///
/// Deliberately a plain key monitor rather than a Carbon hot key: the app
/// already runs global monitors for its modifier-tap shortcuts and already
/// holds the Accessibility grant they need, so this costs one more monitor and
/// no new permission prompt.
@MainActor
final class ScreenAgentInboxHotkey {

    /// `kVK_ANSI_O`. Named because the number alone is unreadable.
    private static let keyO: UInt16 = 31

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onFire: () -> Void

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    func register() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.matches(event) else { return }
            self.onFire()
        }
        // The same chord has to work when one of our own windows has focus;
        // a global monitor never sees those events.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, Self.matches(event) else { return event }
            self.onFire()
            return nil  // swallow it, or the key also reaches the focused field
        }
        NSLog("[ScreenAgentInbox] ⌘⌥O registered (global+local)")
    }

    func unregister() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    /// Exact chord, not "contains": ⌘⌥⇧O and ⌘⌃⌥O belong to whatever the user
    /// has bound them to, and quietly stealing a neighbour's shortcut is worse
    /// than not having one.
    static func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == keyO && flags == [.command, .option]
    }
}

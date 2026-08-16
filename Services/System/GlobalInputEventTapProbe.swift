#if DEBUG
import ApplicationServices
import CoreGraphics
import Foundation

/// Debug-only capability probe for the first layout-switcher release gate.
///
/// It observes only that macOS delivers a key event; it never reads, stores,
/// or logs the event's characters, key code, target app, or clipboard content.
final class GlobalInputEventTapProbe {
    enum State: String, Equatable {
        case needsAccessibility
        case unavailable
        case active

        static func resolve(isAccessibilityTrusted: Bool, didCreateEventTap: Bool) -> Self {
            guard isAccessibilityTrusted else { return .needsAccessibility }
            return didCreateEventTap ? .active : .unavailable
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var didObserveInput = false

    deinit {
        stop()
    }

    /// Creates a listen-only key-down tap on the main run loop.
    ///
    /// The caller must use this only for the explicit I0 launch argument.
    @discardableResult
    func start() -> State {
        stop()

        let isAccessibilityTrusted = AXIsProcessTrusted()
        guard isAccessibilityTrusted else {
            return .needsAccessibility
        }

        let keyDownMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: keyDownMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            return .unavailable
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return .active
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }

        runLoopSource = nil
        eventTap = nil
        didObserveInput = false
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let probe = Unmanaged<GlobalInputEventTapProbe>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        probe.handle(type: type)
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                NSLog("[LayoutFixProbe] Event tap was disabled and has been re-enabled")
            }

        default:
            guard !didObserveInput else { return }
            didObserveInput = true
            NSLog("[LayoutFixProbe] Event tap observed input; contents are never logged")
        }
    }
}
#endif

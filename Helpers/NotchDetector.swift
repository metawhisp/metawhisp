import AppKit

/// Detects real notch dimensions using NSScreen APIs (macOS 12+).
/// Falls back to sensible defaults for external displays or older Macs.
@MainActor
final class NotchDetector: ObservableObject {
    static let shared = NotchDetector()

    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    @Published var notchRadius: CGFloat = 10
    @Published var hasNotch: Bool = true

    private init() {
        detect()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.detect() }
        }
    }

    func detect() {
        guard let screen = Self.builtInScreen else {
            // External display — no notch
            hasNotch = false
            notchWidth = 0
            notchHeight = 0
            NSLog("[NotchDetector] No built-in display, no notch")
            return
        }

        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // Real notch detected — calculate dimensions
            notchWidth = right.minX - left.maxX
            notchHeight = screen.frame.maxY - min(left.minY, right.minY)
            notchRadius = min(notchHeight / 3, 12)
            hasNotch = true
            NSLog("[NotchDetector] Real notch: %.0f x %.0f", notchWidth, notchHeight)
        } else {
            // No auxiliaryTopArea — older Mac or no notch
            hasNotch = false
            notchWidth = 185 // fallback
            notchHeight = 32
            notchRadius = 10
            NSLog("[NotchDetector] No notch detected, using defaults")
        }
    }

    /// Find the built-in MacBook display
    private static var builtInScreen: NSScreen? {
        for screen in NSScreen.screens {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               CGDisplayIsBuiltin(id) != 0 {
                return screen
            }
        }
        return NSScreen.main
    }
}

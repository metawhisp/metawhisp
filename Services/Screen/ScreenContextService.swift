import AppKit
import Foundation
import ScreenCaptureKit
import SwiftData
import Vision

/// Captures the active window and extracts text via Apple Vision OCR.
/// All processing is on-device — no data leaves the Mac.
@MainActor
final class ScreenContextService: ObservableObject {
    @Published var isActive = false
    @Published var lastContext: ScreenContextSnapshot?

    /// Recent contexts kept in memory for the advice system.
    private(set) var recentContexts: [ScreenContextSnapshot] = []
    private let maxRecentContexts = 20

    private var monitorTask: Task<Void, Never>?
    private var lastAppName: String?
    private var lastWindowTitle: String?
    private var modelContainer: ModelContainer?

    /// Set the model container for SwiftData persistence.
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// In-memory snapshot (not persisted — used for advice generation).
    struct ScreenContextSnapshot {
        let timestamp: Date
        let appName: String
        let windowTitle: String
        let ocrText: String
    }

    /// Apps that should never be captured (privacy-sensitive).
    private let defaultBlacklist: Set<String> = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "1Password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    /// Start monitoring screen context (captures on window change).
    func startMonitoring(
        interval: TimeInterval = 30,
        blacklist: Set<String> = [],
        whitelist: Set<String>? = nil
    ) {
        guard !isActive else { return }

        let mergedBlacklist = defaultBlacklist.union(blacklist)

        monitorTask = Task { [weak self] in
            guard let self else { return }

            // Pre-flight: ensure Screen Recording permission is granted.
            // Trigger the TCC dialog — but DO NOT force-open System Settings,
            // that steals focus (user can re-enable the toggle to get here again).
            if !CGPreflightScreenCaptureAccess() {
                NSLog("[ScreenContext] No Screen Recording permission — requesting...")
                _ = await PermissionsService.shared.requestScreenRecording()

                if !CGPreflightScreenCaptureAccess() {
                    NSLog("[ScreenContext] ❌ Permission denied — monitor not started")
                    await MainActor.run { self.isActive = false }
                    return
                }
            }

            await MainActor.run { self.isActive = true }
            NSLog("[ScreenContext] ✅ Monitoring started (interval: %.0fs)", interval)

            while !Task.isCancelled {
                await self.captureIfChanged(blacklist: mergedBlacklist, whitelist: whitelist)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
        isActive = false
        NSLog("[ScreenContext] Monitoring stopped")
    }

    /// Force capture current screen context.
    func captureNow() async -> ScreenContextSnapshot? {
        return await captureActiveWindow(blacklist: defaultBlacklist, whitelist: nil)
    }

    // MARK: - Private

    private func captureIfChanged(blacklist: Set<String>, whitelist: Set<String>?) async {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        // Check blacklist
        if blacklist.contains(bundleID) || blacklist.contains(appName) {
            return
        }

        // Check whitelist (if set, only capture listed apps)
        if let whitelist, !whitelist.isEmpty {
            if !whitelist.contains(bundleID) && !whitelist.contains(appName) {
                return
            }
        }

        // Get window title via Accessibility API
        let windowTitle = getActiveWindowTitle(pid: frontApp.processIdentifier) ?? ""

        // Only capture if app or window changed
        guard appName != lastAppName || windowTitle != lastWindowTitle else { return }
        lastAppName = appName
        lastWindowTitle = windowTitle

        if let snapshot = await captureActiveWindow(blacklist: blacklist, whitelist: whitelist) {
            lastContext = snapshot
            recentContexts.append(snapshot)
            if recentContexts.count > maxRecentContexts {
                recentContexts.removeFirst()
            }
            // Persist to SwiftData
            persistContext(snapshot)
        }
    }

    private func captureActiveWindow(
        blacklist: Set<String>,
        whitelist: Set<String>?
    ) async -> ScreenContextSnapshot? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = frontApp.localizedName ?? "Unknown"
        let bundleID = frontApp.bundleIdentifier ?? ""

        // Safety checks
        if blacklist.contains(bundleID) || blacklist.contains(appName) { return nil }
        if let whitelist, !whitelist.isEmpty,
           !whitelist.contains(bundleID) && !whitelist.contains(appName) {
            return nil
        }

        let windowTitle = getActiveWindowTitle(pid: frontApp.processIdentifier) ?? ""

        // Capture screenshot of the active window
        guard let image = await captureScreenshot() else {
            // Fallback: create context with just app/window info (no OCR)
            return ScreenContextSnapshot(
                timestamp: Date(),
                appName: appName,
                windowTitle: windowTitle,
                ocrText: ""
            )
        }

        // Run OCR on the screenshot (on-device via Vision framework)
        let ocrText = await performOCR(on: image)

        let snapshot = ScreenContextSnapshot(
            timestamp: Date(),
            appName: appName,
            windowTitle: windowTitle,
            ocrText: ocrText
        )

        NSLog("[ScreenContext] Captured: %@ — %@ (%d chars OCR)",
              appName, String(windowTitle.prefix(40)), ocrText.count)

        return snapshot
    }

    /// Capture a screenshot of the screen using ScreenCaptureKit.
    private func captureScreenshot() async -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(display.width)
            config.height = Int(display.height)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return image
        } catch {
            NSLog("[ScreenContext] Screenshot failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Perform OCR using Apple Vision framework (fully on-device).
    private func performOCR(on image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            // Support multiple languages
            request.recognitionLanguages = ["en-US", "ru-RU", "de-DE", "fr-FR", "es-ES"]
            request.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                NSLog("[ScreenContext] OCR failed: %@", error.localizedDescription)
                continuation.resume(returning: "")
            }
        }
    }

    private func persistContext(_ snapshot: ScreenContextSnapshot) {
        guard let container = modelContainer else { return }
        let ctx = ModelContext(container)
        let record = ScreenContext(
            appName: snapshot.appName,
            windowTitle: snapshot.windowTitle,
            ocrText: snapshot.ocrText
        )
        ctx.insert(record)
        try? ctx.save()
    }

    /// Get the title of the active window using Accessibility API.
    private func getActiveWindowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let window = focusedWindow else { return nil }

        var titleValue: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        guard titleResult == .success, let title = titleValue as? String else { return nil }

        return title
    }
}

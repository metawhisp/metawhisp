import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Proof that the user just did something that needs a permission — pressed
/// a button, switched a feature on, pressed record. Launch, activation, timers
/// and automatic starts never hold one, so they cannot show a system prompt:
/// they read the permission and wait for the grant (PRD P0 1, step-1 review
/// #1). Every call that can show a prompt takes one;
/// `LaunchPermissionGuardTests` pins where one may be made.
struct PermissionAsk {}

/// Centralized permission management.
/// Handles TCC prompts for Screen Recording, Microphone, and Accessibility.
@MainActor
final class PermissionsService: ObservableObject {
    static let shared = PermissionsService()

    @Published var screenRecordingGranted: Bool = false
    @Published var microphoneGranted: Bool = false
    @Published var accessibilityGranted: Bool = false

    private init() {
        refresh()
    }

    /// Re-check all permissions (call on app activation).
    func refresh() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphoneGranted = checkMicPermission()
        accessibilityGranted = AXIsProcessTrusted()
        NSLog("[Permissions] state: screen=%@ mic=%@ accessibility=%@", screenRecordingGranted ? "yes" : "no", microphoneGranted ? "yes" : "no", accessibilityGranted ? "yes" : "no")
    }

    // MARK: - Screen Recording

    /// Check if screen recording is granted via preflight API.
    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Request Screen Recording permission. Triggers the system dialog.
    /// Returns true if already granted, false if dialog was shown (user must respond).
    @discardableResult
    func requestScreenRecording(_ ask: PermissionAsk) async -> Bool {
    NSLog("[Permissions] screen-recording request entered — preflight=%@", CGPreflightScreenCaptureAccess() ? "granted" : "denied")
        // 1. Classic TCC dialog — triggers "Screen Recording" prompt
        if !CGPreflightScreenCaptureAccess() {
            NSLog("[Permissions] Requesting Screen Recording via CGRequestScreenCaptureAccess")
            CGRequestScreenCaptureAccess()
        }

        // 2. ScreenCaptureKit dialog (macOS 14+) — separate TCC entry
        if #available(macOS 14.0, *) {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                NSLog("[Permissions] ScreenCaptureKit: granted")
            } catch {
                NSLog("[Permissions] ScreenCaptureKit: %@", error.localizedDescription)
            }
        }

        refresh()
        return screenRecordingGranted
    }

    /// Open System Settings → Privacy → Screen Recording.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Microphone

    private func checkMicPermission() -> Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Request microphone permission.
    @discardableResult
    func requestMicrophone(_ ask: PermissionAsk) async -> Bool {
        if #available(macOS 14.0, *) {
            let status = AVAudioApplication.shared.recordPermission
            if status == .granted { return true }
            if status == .undetermined {
                let granted = (try? await AVAudioApplication.requestRecordPermission()) ?? false
                refresh()
                return granted
            }
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized { return true }
        if status == .notDetermined {
            let granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
            refresh()
            return granted
        }
        return false
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility

    /// The Accessibility button. Launch no longer asks (PRD P0 1), and the
    /// prompting call is what lists MetaWhisp under Privacy → Accessibility, so
    /// the button asks first and then opens the pane.
    static func askForAccessibility(
        _ ask: PermissionAsk,
        prompt: @MainActor (PermissionAsk) -> Void = { PermissionsService.shared.requestAccessibility($0) },
        openPane: () -> Void = {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    ) {
        prompt(ask)
        openPane()
    }

    /// Request Accessibility via prompt. This opens a system dialog.
    func requestAccessibility(_ ask: PermissionAsk) {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        refresh()
    }
}

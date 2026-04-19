import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

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
    }

    // MARK: - Screen Recording

    /// Check if screen recording is granted via preflight API.
    var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Request Screen Recording permission. Triggers the system dialog.
    /// Returns true if already granted, false if dialog was shown (user must respond).
    @discardableResult
    func requestScreenRecording() async -> Bool {
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
    func requestMicrophone() async -> Bool {
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

    /// Request Accessibility via prompt. This opens a system dialog.
    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        refresh()
    }
}

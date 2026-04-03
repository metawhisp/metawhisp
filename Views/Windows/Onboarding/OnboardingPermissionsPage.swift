import SwiftUI
import AVFoundation

/// Screen 3: Request Microphone + Accessibility permissions.
struct OnboardingPermissionsPage: View {
    let appeared: Bool
    @State private var micGranted = false
    @State private var axGranted = false
    @State private var pollTimer: Timer?

    /// Used by container to gate NEXT button.
    static var allGranted: Bool {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        return mic && ax
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            OnboardingHeader(
                label: "PERMISSIONS",
                title: "MetaWhisp needs two things",
                appeared: appeared
            )

            Spacer().frame(height: 8)

            Text("These are required to record your voice and type text.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 32)

            VStack(spacing: 14) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "To hear your voice and transcribe it",
                    granted: micGranted
                ) {
                    requestMic()
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)

                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "To type transcribed text into any app at your cursor",
                    granted: axGranted
                ) {
                    requestAccessibility()
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4), value: appeared)
            }
            .padding(.horizontal, 50)

            Spacer().frame(height: 24)

            if micGranted && axGranted {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MW.idle)
                    Text("All set! Press NEXT to continue.")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(MW.idle)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Spacer()
        }
        .onAppear { startPolling() }
        .onDisappear { pollTimer?.invalidate() }
    }

    // MARK: - Actions

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                withAnimation { micGranted = granted }
            }
        }
    }

    private func requestAccessibility() {
        // Open System Settings → Privacy → Accessibility
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func startPolling() {
        checkPermissions()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            checkPermissions()
        }
    }

    private func checkPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(opts)
        withAnimation {
            micGranted = mic
            axGranted = ax
        }
    }
}

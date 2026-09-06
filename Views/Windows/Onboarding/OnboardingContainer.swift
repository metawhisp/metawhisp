import SwiftUI

/// Main onboarding container — 7 screens with navigation.
struct OnboardingContainer: View {
    @State private var page = 0
    @State private var appeared = false
    @State private var setupDeferred = false
    @ObservedObject var coordinator: TranscriptionCoordinator
    @ObservedObject var modelManager: ModelManagerService
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var license = LicenseService.shared
    var onComplete: () -> Void

    private let totalPages = 8

    /// Order exists to serve the download, not the story: the engine is picked
    /// on screen 2 so ~950 MB lands during the five screens of reading that
    /// follow, and the microphone test waits until screen 7 so the first
    /// sentence anyone dictates comes back from the good model.
    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: OnboardingWelcomePage(appeared: appeared)
                case 1: OnboardingModelPage(appeared: appeared, modelManager: modelManager, coordinator: coordinator)
                case 2: OnboardingPermissionsPage(appeared: appeared)
                case 3: OnboardingFeaturesPage(appeared: appeared)
                case 4: OnboardingTranslatePage(appeared: appeared)
                case 5: OnboardingLayoutFixPage(appeared: appeared)
                case 6: OnboardingTryItPage(appeared: appeared, coordinator: coordinator)
                default: OnboardingDonePage(appeared: appeared)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
        }
        .frame(width: 720, height: 560)
        .background(MW.bg)
        .onAppear { triggerAppear() }
    }

    // MARK: - Navigation

    private func triggerAppear() {
        appeared = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
        }
    }

    /// FREE-1/2: gate on a working transcription engine. A path counts as ready
    /// only when it can actually transcribe (see `OnboardingReadiness`).
    private var setupReady: Bool {
        let path: OnboardingReadiness.Path = settings.transcriptionEngine == "cloud" ? .cloud : .local
        return OnboardingReadiness.isReady(
            path: path,
            localModelReady: coordinator.loadedWhisperModelId == settings.selectedModel,
            cloudKeyValidated: coordinator.cloudKeyValidated,
            isPro: license.isPro
        )
    }

    /// Block only the final step. The engine page used to block too, which
    /// meant staring at a progress bar; now the whole point of putting it early
    /// is that the user keeps moving while the model downloads behind them.
    private var nextBlocked: Bool {
        // FREE-9: "Set up later" lets the user finish without an engine; the
        // first dictation then shows the existing "set up transcription" error.
        page == totalPages - 1 && !setupReady && !setupDeferred
    }

    private func goNext() {
        guard !nextBlocked else { return }
        if page < totalPages - 1 {
            appeared = false
            withAnimation(.easeInOut(duration: 0.2)) { page += 1 }
            NSLog("[Onboarding] step %d of %d", page + 1, totalPages)
            triggerAppear()
        } else {
            onComplete()
        }
    }

    private func goBack() {
        appeared = false
        withAnimation(.easeInOut(duration: 0.2)) { page -= 1 }
        triggerAppear()
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            HStack {
                OnboardingDots(total: totalPages, current: page)
                if nextBlocked {
                    Text("Set up a working engine, or")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MW.textMuted)
                        .padding(.leading, MW.sp8)
                    Button { setupDeferred = true } label: {
                        Text("set up later")
                            .font(.system(size: 9, design: .monospaced))
                            .underline()
                            .foregroundStyle(MW.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()

                if page > 0 {
                    Button(action: goBack) {
                        Text("BACK")
                            .font(MW.label).tracking(1)
                            .foregroundStyle(MW.textMuted)
                            .padding(.horizontal, MW.sp16)
                            .padding(.vertical, MW.sp8)
                    }
                    .buttonStyle(.plain)
                }

                Button(action: goNext) {
                    Text(buttonLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5)
                        .foregroundStyle(.black)
                        .padding(.horizontal, MW.sp24)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .opacity(nextBlocked ? 0.4 : 1)
                }
                .buttonStyle(.plain)
                .disabled(nextBlocked)
            }
            .padding(.horizontal, MW.sp24)
            .padding(.vertical, MW.sp16)
        }
    }

    private var buttonLabel: String {
        switch page {
        case 0: return "GET STARTED"
        case totalPages - 1: return "START"
        default: return "NEXT"
        }
    }
}

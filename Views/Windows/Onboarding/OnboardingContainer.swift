import SwiftUI

/// Main onboarding container — 7 screens with navigation.
struct OnboardingContainer: View {
    @State private var page = 0
    @State private var appeared = false
    @ObservedObject var coordinator: TranscriptionCoordinator
    var onComplete: () -> Void

    private let totalPages = 7

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: OnboardingWelcomePage(appeared: appeared)
                case 1: OnboardingFeaturesPage(appeared: appeared)
                case 2: OnboardingModelPage(appeared: appeared)
                case 3: OnboardingPermissionsPage(appeared: appeared)
                case 4: OnboardingTryItPage(appeared: appeared, coordinator: coordinator)
                case 5: OnboardingMenuBarPage(appeared: appeared)
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

    private func goNext() {
        if page < totalPages - 1 {
            appeared = false
            withAnimation(.easeInOut(duration: 0.2)) { page += 1 }
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
                }
                .buttonStyle(.plain)
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

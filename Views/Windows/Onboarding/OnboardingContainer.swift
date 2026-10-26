import SwiftUI

/// D1 — the four screens in one window: the step above, the screen the flow is on, its buttons below.
/// Screens slide in; with Reduce Motion they only fade.
struct OnboardingContainer: View {
    @ObservedObject var flow: OnboardingFlow
    let preparer: ModelPreparer
    /// The practice's microphone.
    let microphone: AudioRecordingService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            screen
                .id(flow.screen)
                .transition(.asymmetric(
                    insertion: .offset(x: OnboardingMotion.offset(16, reduceMotion: reduceMotion)).combined(with: .opacity),
                    removal: .offset(x: OnboardingMotion.offset(-16, reduceMotion: reduceMotion)).combined(with: .opacity)))
            Text(flow.screen.step)
                .font(OnboardingStyle.step)
                .monospacedDigit()
                .foregroundStyle(MW.textMuted)
                .padding(.top, 14)
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        // The window's content runs under its transparent title bar: the step sits beside the traffic lights.
        .ignoresSafeArea()
        .background(OnboardingBackground())
        .animation(.easeOut(duration: 0.24), value: flow.screen)
    }

    @ViewBuilder
    private var screen: some View {
        switch flow.screen {
        case .welcome: WelcomeScreen(flow: flow)
        case .enable: EnableDictationScreen(flow: flow)
        case .practice:
            if let practice = flow.practice {
                TryVoiceScreen(flow: flow, practice: practice, preparer: preparer, microphone: microphone)
            }
        case .pro: ProScreen(flow: flow, license: .shared)
        }
    }
}

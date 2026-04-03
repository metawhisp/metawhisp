import SwiftUI

/// Animated glow effect around the recording pill.
/// Inspired by Claude Code's green glow — we use state-dependent colors.
struct GlowOverlay: View {
    let stage: TranscriptionCoordinator.Stage
    @State private var glowPhase: CGFloat = 0

    var body: some View {
        Capsule()
            .fill(.clear)
            .shadow(color: glowColor.opacity(glowOpacity), radius: glowRadius)
            .shadow(color: glowColor.opacity(glowOpacity * 0.6), radius: glowRadius * 1.8)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: glowPhase)
            .onAppear { glowPhase = 1 }
    }

    private var glowColor: Color {
        switch stage {
        case .idle: MW.idle
        case .recording: MW.recording
        case .processing: MW.processing
        case .postProcessing: MW.postProcess
        }
    }

    private var glowOpacity: Double {
        switch stage {
        case .idle: 0.7
        case .recording: 0.5 + glowPhase * 0.4
        case .processing: 0.4 + glowPhase * 0.3
        case .postProcessing: 0.4 + glowPhase * 0.3
        }
    }

    private var glowRadius: CGFloat {
        switch stage {
        case .idle: 8
        case .recording: 14 + glowPhase * 8
        case .processing: 12 + glowPhase * 6
        case .postProcessing: 12 + glowPhase * 6
        }
    }
}

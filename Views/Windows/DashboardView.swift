import SwiftUI

/// Dashboard — BLOCKS-styled status strip + full statistics below.
struct DashboardView: View {
    @ObservedObject var coordinator: TranscriptionCoordinator

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("METAWHISP").font(MW.monoLg).foregroundStyle(MW.textPrimary).tracking(2)
                Spacer()
                Text("DASHBOARD").mwBadge()
            }
            .padding(MW.sp16)
            .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)

            // Status strip (compact, BLOCKS-style)
            statusStrip
                .overlay(Rectangle().fill(MW.border).frame(height: MW.hairline), alignment: .bottom)

            // Statistics (SwiftData-powered)
            StatisticsView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MW.bg)
    }

    // MARK: - Status Strip

    private var statusStrip: some View {
        HStack(spacing: MW.sp12) {
            Circle()
                .fill(MW.stateColor(coordinator.stage.rawValue))
                .frame(width: 6, height: 6)
                .shadow(color: MW.stateColor(coordinator.stage.rawValue).opacity(0.5), radius: 4)

            Text(statusLabel.uppercased())
                .font(MW.label).tracking(1.5)
                .foregroundStyle(coordinator.stage == .idle ? MW.textSecondary : MW.textPrimary)

            Spacer()

            Button {
                coordinator.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: coordinator.stage == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 9, weight: .medium))
                    Text(coordinator.stage == .recording ? "STOP" : "RECORD")
                        .font(MW.label).tracking(0.5)
                }
                .foregroundStyle(coordinator.stage == .recording ? (MW.isDark ? .white : .white) : MW.textSecondary)
                .padding(.horizontal, MW.sp12).padding(.vertical, MW.sp8)
                .background(coordinator.stage == .recording ? Color.red.opacity(0.85) : .clear)
                .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
            }
            .buttonStyle(.plain)
            .disabled(coordinator.stage == .processing || coordinator.stage == .postProcessing)
        }
        .padding(.horizontal, MW.sp16).padding(.vertical, MW.sp8)
    }

    private var statusLabel: String {
        switch coordinator.stage {
        case .recording: "Recording"
        case .processing: "Transcribing"
        case .postProcessing: coordinator.translateNext ? "Translating" : "Processing"
        case .idle: "Ready"
        }
    }
}

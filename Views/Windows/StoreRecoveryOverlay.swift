import AppKit
import SwiftUI

/// Full-window blocking overlay shown when the persistent store could not be
/// opened (AUD-007 / ITER-049 A1). Replaces the old SILENT in-memory fallback:
/// the user is told their data couldn't be loaded, that the original file was
/// preserved (not deleted), and that this session won't be saved.
struct StoreRecoveryOverlay: View {
    let reason: String
    let backupPath: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(MW.recording)

                Text("Couldn't open your data")
                    .font(MW.monoLg).foregroundStyle(MW.textPrimary)

                Text("MetaWhisp couldn't open your saved history, so it's running in a temporary session — changes now WON'T be saved. Your original data file was not deleted.")
                    .font(MW.mono).foregroundStyle(MW.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)

                if let backupPath {
                    Text("A copy was preserved at:\n\(backupPath)")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                        .textSelection(.enabled)
                }

                Text(reason)
                    .font(MW.monoSm).foregroundStyle(MW.textDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 420)
                    .lineLimit(3)

                HStack(spacing: 12) {
                    if let backupPath {
                        Button("Reveal in Finder") { reveal(backupPath) }
                    }
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 500)
            .background(MW.elevated)
            .clipShape(RoundedRectangle(cornerRadius: MW.rMedium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MW.rMedium, style: .continuous)
                    .stroke(MW.border, lineWidth: MW.hairline)
            )
        }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

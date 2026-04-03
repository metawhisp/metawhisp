import SwiftUI

/// Screen 2: Choose transcription model — Local / Cloud / Pro.
struct OnboardingModelPage: View {
    let appeared: Bool
    @State private var selected: Tab = .local
    @State private var downloadProgress: Double? = nil
    @State private var downloadDone = false

    enum Tab: String { case local, cloud, pro }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            OnboardingHeader(
                label: "SETUP",
                title: "Choose how to transcribe",
                appeared: appeared
            )

            Spacer().frame(height: 6)

            Text("You can change this anytime in Settings.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 20)

            // Tab selector
            HStack(spacing: 0) {
                tabButton("🖥  Local", tab: .local, desc: "Free")
                tabButton("☁️  Cloud", tab: .cloud, desc: "API Key")
                tabButton("⭐️  Pro", tab: .pro, desc: "$7.77/mo")
            }
            .padding(.horizontal, 36)
            .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 16)

            // Content
            Group {
                switch selected {
                case .local: localContent
                case .cloud: cloudContent
                case .pro: proContent
                }
            }
            .padding(.horizontal, 36)
            .transition(.opacity)

            Spacer()
        }
    }

    // MARK: - Tab Button

    private func tabButton(_ title: String, tab: Tab, desc: String) -> some View {
        let active = selected == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { selected = tab }
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(active ? MW.textPrimary : MW.textMuted)
                Text(desc)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(MW.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(active ? MW.surface : .clear)
            .overlay(Rectangle().stroke(active ? MW.border : MW.border.opacity(0.3), lineWidth: MW.hairline))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Local

    private var localContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("100% private — audio never leaves your Mac")
                .font(MW.monoSm).foregroundStyle(MW.textSecondary)

            modelCard(
                name: "Large V3 Turbo",
                size: "~950 MB",
                badge: "RECOMMENDED",
                badgeColor: MW.idle
            )

            modelCard(
                name: "Tiny",
                size: "~40 MB",
                badge: "FAST",
                badgeColor: MW.textMuted
            )

            if let progress = downloadProgress {
                VStack(spacing: 6) {
                    ProgressView(value: progress)
                        .tint(MW.idle)
                    Text(downloadDone ? "✓ Ready" : "Downloading model...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(downloadDone ? MW.idle : MW.textMuted)
                }
            }
        }
    }

    private func modelCard(name: String, size: String, badge: String, badgeColor: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(MW.textPrimary)
                    Text(badge).font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(badgeColor.opacity(0.1))
                }
                Text(size).font(.system(size: 10, design: .monospaced)).foregroundStyle(MW.textMuted)
            }
            Spacer()
            Button {
                startDownload()
            } label: {
                Text(downloadDone ? "✓" : "DOWNLOAD")
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.5)
                    .foregroundStyle(downloadDone ? MW.idle : .black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(downloadDone ? .clear : Color.white)
                    .overlay(downloadDone ? Rectangle().stroke(MW.idle, lineWidth: MW.hairline) : nil)
            }
            .buttonStyle(.plain)
            .disabled(downloadDone)
        }
        .padding(12)
        .background(MW.surface)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
    }

    private func startDownload() {
        downloadProgress = 0
        // TODO: wire up real ModelManagerService.download()
        // For now simulate progress
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            if let p = downloadProgress, p < 1.0 {
                downloadProgress = min(1.0, p + 0.02)
            } else {
                t.invalidate()
                downloadDone = true
                AppSettings.shared.transcriptionEngine = "ondevice"
            }
        }
    }

    // MARK: - Cloud

    private var cloudContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use your own OpenAI-compatible API key")
                .font(MW.monoSm).foregroundStyle(MW.textSecondary)

            HStack(spacing: 8) {
                TextField("API Key", text: .constant(""))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .background(MW.surface)
                    .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))

                Button {
                    AppSettings.shared.transcriptionEngine = "cloud"
                } label: {
                    Text("VERIFY")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.5)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Pro

    private var proContent: some View {
        VStack(spacing: 14) {
            Text("Fastest transcription. Highest accuracy. No setup needed.")
                .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                HStack(spacing: 6) { dot; Text("2× faster than on-device").font(MW.monoSm).foregroundStyle(MW.textMuted) }
                HStack(spacing: 6) { dot; Text("60 cloud minutes/day (accumulate up to 600)").font(MW.monoSm).foregroundStyle(MW.textMuted) }
                HStack(spacing: 6) { dot; Text("Smart text processing (rewrite, structure)").font(MW.monoSm).foregroundStyle(MW.textMuted) }
            }

            Button {
                NSWorkspace.shared.open(URL(string: "https://metawhisp.com/account/")!)
            } label: {
                Text("GET PRO — $7.77/mo")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Color(red: 0.78, green: 0.71, blue: 0.55))
            }
            .buttonStyle(.plain)

            Text("Already Pro? It will activate automatically.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(MW.textMuted)
        }
    }

    private var dot: some View {
        Circle().fill(MW.textMuted).frame(width: 3, height: 3)
    }
}

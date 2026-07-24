import SwiftUI

/// Screen 2: Choose transcription model — Local / Cloud / Pro.
struct OnboardingModelPage: View {
    let appeared: Bool
    @ObservedObject var modelManager: ModelManagerService
    @ObservedObject var coordinator: TranscriptionCoordinator
    @State private var selected: Tab = .local
    @State private var cloudKey = ""
    @State private var validating = false
    @State private var validationError: String?
    /// ITER-058.3 — set when quick-start can't run (low disk); silent no-op
    /// next to "downloads now" copy was a review finding.
    @State private var quickStartNote: String?

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
            // ITER-058.3 — quick start: Base auto-downloads the moment this page
            // appears; the best model installs silently in the background later.
            Text("Quick model downloads now — the best model auto-installs in the background. 100% private, audio never leaves your Mac.")
                .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let quickStartNote {
                Text("⚠️ " + quickStartNote)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MW.recording)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modelCard(modelId: ModelBootstrap.quickModelId, name: "Base", size: "~80 MB",
                      badge: "QUICK START", badgeColor: MW.idle)
            modelCard(modelId: ModelBootstrap.bestModelId, name: "Large V3 Turbo", size: "~950 MB",
                      badge: "BEST · AUTO-INSTALLS", badgeColor: MW.textMuted)

            // Live state from the real downloader.
            if modelManager.isDownloading || modelManager.phase == .verifying {
                VStack(spacing: 6) {
                    ProgressView(value: modelManager.downloadProgress).tint(MW.idle)
                    Text(progressLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MW.textMuted)
                }
            } else if case .failed(let msg) = modelManager.phase {
                Text("Download failed — tap DOWNLOAD to retry.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MW.recording)
                    .help(msg)
            }
        }
        .onAppear { maybeQuickStart() }
        .onChange(of: appeared) { _, isShown in
            if isShown { maybeQuickStart() }
        }
    }

    /// ITER-058.3 — auto-start the Base download so the user never stares at a
    /// dead NEXT button. Idempotent: no-ops once anything is downloaded or in
    /// flight, for Pro users, and on a nearly-full disk (with a visible note —
    /// a silent no-op next to "downloads now" copy was a review finding).
    private func maybeQuickStart() {
        guard selected == .local else { return }
        let anyDownloaded = ModelManagerService.models.contains { modelManager.isDownloaded($0.id) }
        let freeBytes = ModelBootstrap.freeDiskBytes()
        if !anyDownloaded, !modelManager.isDownloading,
           freeBytes < ModelBootstrap.minFreeBytesForQuick {
            quickStartNote = "Not enough free disk space (~500 MB needed). Free up space, or use Cloud / Pro."
            return
        }
        guard ModelBootstrap.shouldQuickStart(
            anyModelDownloaded: anyDownloaded,
            isDownloading: modelManager.isDownloading,
            isPro: LicenseService.shared.isPro,
            freeBytes: freeBytes
        ) else { return }
        quickStartNote = nil
        AppSettings.shared.selectedModel = ModelBootstrap.quickModelId
        AppSettings.shared.transcriptionEngine = "ondevice"
        AppSettings.shared.pendingBestModelUpgrade = true
        modelManager.startDownload(ModelBootstrap.quickModelId)
        NSLog("[ModelBootstrap] ⚡️ Quick start: Base downloading, best model queued for background install")
    }

    private var progressLabel: String {
        if modelManager.phase == .verifying { return "Verifying model…" }
        let pct = Int((modelManager.downloadProgress * 100).rounded())
        let speed = modelManager.downloadSpeed.isEmpty ? "" : " · \(modelManager.downloadSpeed)"
        return "Downloading model… \(pct)%\(speed)"
    }

    private func modelCard(modelId: String, name: String, size: String, badge: String, badgeColor: Color) -> some View {
        let isDone = modelManager.isDownloaded(modelId)
        let isThis = modelManager.isDownloading && modelManager.currentDownloadModel == modelId
        // ITER-058.3 review fix — a downloaded model that FAILED TO LOAD must be
        // retryable; the old `.disabled(isDone)` made "tap to retry" unreachable.
        // Retry re-runs startDownload: cached files fast-path in seconds → .done
        // → the auto-loader re-attempts the load.
        // Keyed on the per-model marker, so a background DOWNLOAD failure of
        // another model never paints RETRY on a working Base card, and a
        // concurrent download never hides a real load failure (Codex).
        let loadFailed = isDone && modelManager.failedToLoadModelId == modelId
        return HStack {
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
                startLocalModel(modelId)
            } label: {
                Text(loadFailed ? "RETRY" : (isDone ? "✓" : (isThis ? "…" : "DOWNLOAD")))
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.5)
                    .foregroundStyle(isDone && !loadFailed ? MW.idle : .black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(isDone && !loadFailed ? .clear : Color.white)
                    .overlay(isDone && !loadFailed ? Rectangle().stroke(MW.idle, lineWidth: MW.hairline) : nil)
            }
            .buttonStyle(.plain)
            .disabled((isDone && !loadFailed) || modelManager.isDownloading)
        }
        .padding(12)
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    /// FREE-1: real on-device model download (replaces a fake `Timer`). Pins the
    /// model + on-device engine so the onboarding readiness gate only goes ready
    /// once the model is actually on disk.
    /// ITER-058.3 — an EXPLICIT pick of a DIFFERENT model disables the silent
    /// background upgrade (the user chose, we obey). Retrying the quick model
    /// itself is NOT a pick — the promised upgrade stays on (review fix).
    private func startLocalModel(_ modelId: String) {
        if modelId != ModelBootstrap.quickModelId {
            AppSettings.shared.pendingBestModelUpgrade = false
        }
        AppSettings.shared.selectedModel = modelId
        AppSettings.shared.transcriptionEngine = "ondevice"
        modelManager.startDownload(modelId)
    }

    // MARK: - Cloud

    private var cloudContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use your own OpenAI-compatible API key")
                .font(MW.monoSm).foregroundStyle(MW.textSecondary)

            HStack(spacing: 8) {
                SecureField("API Key", text: $cloudKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .mwCard(radius: MW.rSmall, elevation: .flat)
                    .disabled(validating)
                    .onChange(of: cloudKey) { _, _ in
                        // FREE-10: editing the key invalidates a prior ✓.
                        coordinator.cloudKeyValidated = false
                        validationError = nil
                    }

                Button {
                    verifyCloudKey()
                } label: {
                    Text(coordinator.cloudKeyValidated ? "✓" : (validating ? "…" : "VERIFY"))
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(0.5)
                        .foregroundStyle(coordinator.cloudKeyValidated ? MW.idle : .black)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(coordinator.cloudKeyValidated ? .clear : Color.white)
                        .overlay(coordinator.cloudKeyValidated ? Rectangle().stroke(MW.idle, lineWidth: MW.hairline) : nil)
                }
                .buttonStyle(.plain)
                .disabled(validating || cloudKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let err = validationError {
                Text(err).font(.system(size: 10, design: .monospaced)).foregroundStyle(MW.recording)
            }
        }
    }

    /// FREE-2: actually validate the key against the provider before counting
    /// cloud as ready (was a no-op that just flipped the engine to "cloud").
    private func verifyCloudKey() {
        // FREE-6: pick the provider from the key prefix so an OpenAI sk-… key
        // isn't validated against Groq (and vice versa), and align the app's
        // transcription provider to it.
        let provider = CloudKeyValidator.detectProvider(key: cloudKey)
        AppSettings.shared.cloudTranscriptionProvider = provider
        validating = true
        validationError = nil
        coordinator.cloudKeyValidated = false
        Task { @MainActor in
            let ok = await CloudKeyValidator.validate(key: cloudKey, provider: provider)
            validating = false
            if ok {
                if provider == "openai" {
                    AppSettings.shared.openaiKey = cloudKey
                } else {
                    AppSettings.shared.groqKey = cloudKey
                }
                AppSettings.shared.transcriptionEngine = "cloud"
                // ITER-058.3 — the user went cloud: cancel the quick-start's
                // background plan AND any in-flight download right here (Codex:
                // clearing the flag alone let a running 950 MB finish; the
                // engine-switch observer also cancels, this is belt+braces for
                // the case where the engine was already "cloud").
                let quickStartOwned = AppSettings.shared.pendingBestModelUpgrade
                AppSettings.shared.pendingBestModelUpgrade = false
                if ModelBootstrap.shouldCancelDownload(
                    currentDownloadModel: modelManager.currentDownloadModel,
                    quickStartOwned: quickStartOwned) {
                    modelManager.cancelDownload()
                }
                coordinator.cloudKeyValidated = true
            } else {
                validationError = "Key didn't validate — check it and try again."
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
                HStack(spacing: 6) { dot; Text("5400 cloud minutes/month (~90 hours)").font(MW.monoSm).foregroundStyle(MW.textMuted) }
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

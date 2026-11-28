import SwiftData
import SwiftUI

struct MainSettingsView: View {
    @ObservedObject var modelManager: ModelManagerService
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var license = LicenseService.shared
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    /// ITER-039 — local-LLM download progress + downloaded set. Drives the
    /// Download/Make-active state machine inside `aiModelCard`.
    @ObservedObject private var mlxManager = MLXModelManager.shared
    /// ITER-051 F1.4 — live isReady/isLoading for the model cards (they used
    /// to read `LocalLLMService.shared` without observation, so load state
    /// changes never refreshed the UI).
    @ObservedObject private var localLLM = LocalLLMService.shared

    // Screen Context app picker sheet
    @State private var showAppPicker = false
    @State private var appCache: [String: AppInfo] = [:]  // bundleID → AppInfo for rendering
    // ITER-053.1 — delete-screen-history confirm + inline result
    @State private var confirmDeleteScreenHistory = false
    @State private var screenHistoryDeleteResult: String?
    /// The browser did not open the account page: the link is shown, with Copy.
    @State private var accountLinkShown = false
    /// ITER-076 P5 — the shortcut recorder. It owns the key monitor while it
    /// records, and gives the monitor back when it is done.
    @StateObject private var helpShortcutRecorder = MeetingHelpShortcutRecorder()
    /// FEAT-0006 §8 — Connect Claude Code / Codex.
    @StateObject private var agentConnector = AgentConnector()
    /// The Carbon shortcut — the row shows why it could not be registered.
    @ObservedObject private var meetingHelpHotkey = MeetingHelpHotkey.shared

    // Tab selection — single column scroll per tab beats the previous two-column wall
    // (1500-line settings was hard to scan).
    @State private var selectedTab: SettingsTab

    init(modelManager: ModelManagerService, initialTab: SettingsTab = .general) {
        self.modelManager = modelManager
        _selectedTab = State(initialValue: initialTab)
    }

    /// ITER-056 — 5 tabs, one product vertical each (founder-approved mockup
    /// 2026-07-15): a key lives next to the feature it powers; Integrations
    /// holds external services only. ITER-076 stage 8b (owner decision 8.3):
    /// a 6th, Agent — the browser agent's switch, what it sends and where,
    /// and the browser it uses.
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case dictation = "Dictation"
        case meetings = "Meetings"
        case brain = "Second Brain"
        case integrations = "Integrations"
        case agent = "Agent"
        var id: String { rawValue }

        /// The tabs Settings shows (U1): Agent only with the Ultra switch on.
        static func shown(ultra: Bool) -> [SettingsTab] { ultra ? allCases : allCases.filter { $0 != .agent } }
    }

    /// Max width of the content + tab column — native-app pattern (System Settings,
    /// Raycast, Linear). Wide enough for two-column rows, narrow enough to stay
    /// readable on ultrawide screens.
    private let contentMaxWidth: CGFloat = 640

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
            divider
            tabPicker
            divider

            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 0) {
                        tabContent(for: selectedTab)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: contentMaxWidth, alignment: .top)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, MW.sp16)
            }
            // Paired sections sit side by side only while each keeps a usable width.
            .onGeometryChange(for: Bool.self) { $0.size.width >= Self.pairsBesideFrom } action: { beside in
                if beside != pairsBeside { pairsBeside = beside }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @State private var pairsBeside = true
    /// The settings area's width from which `twoColumn` pairs stand side by side; one under the other below it.
    private static let pairsBesideFrom: CGFloat = 560

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            // The row while it fits; a narrower window gets one chip with a menu of the tabs.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 2) {
                    ForEach(SettingsTab.shown(ultra: UltraFeatures.isOn())) { tab in
                        tabButton(tab)
                    }
                }
                .mwSegmentTrack()
                SegmentMenu(options: SettingsTab.shown(ultra: UltraFeatures.isOn()), selection: $selectedTab) { $0.rawValue }
            }
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MW.sp16)
        .padding(.vertical, MW.sp8)
    }

    private func tabButton(_ tab: SettingsTab) -> some View {
        let isSelected = selectedTab == tab
        return Text(tab.rawValue)
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(isSelected ? MW.textPrimary : MW.textSecondary)
            .padding(.horizontal, MW.sp12)
            .padding(.vertical, 5)
            .mwSelectable(isSelected, radius: 999, resting: .none)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.12)) { selectedTab = tab }
            }
    }

    // MARK: - Tab content

    @ViewBuilder
    private func tabContent(for tab: SettingsTab) -> some View {
        // Each section is now a self-contained glass card with its own header/toggle,
        // so we can lay them out with real spacing (no more hairline dividers) and
        // group semantically-related ones into 2-column rows to avoid stretching
        // narrow controls across the whole column.
        switch tab {
        case .general:
            VStack(spacing: MW.sp12) {
                accountSection            // + minutes meter + star promo (ITER-056)
                aiModelsSection           // AI ENGINE — app-wide text intelligence
                cloudSection              // CLOUD LLM (Pro included / BYOK)
                twoColumn(hotkeySection, overlaySection)
                optionsSection
                noticesLink               // the licence notices (§5)
            }
        case .dictation:
            VStack(spacing: MW.sp12) {
                modelSection              // engine + Whisper models + cloud provider key
                microphoneSection
                twoColumn(languageSection, processingSection)
                twoColumn(translationSection, textStyleSection)
            }
        case .meetings:
            VStack(spacing: MW.sp12) {
                meetingSection            // recording + Deepgram + limits + recap + live advice
            }
        case .brain:
            VStack(spacing: MW.sp12) {
                screenContextSection      // Screen Intelligence
                if UltraFeatures.isOn() {
                    twoColumn(memoriesSection, adviceSection)   // U1b — AI Advice
                } else {
                    memoriesSection
                }
                if UltraFeatures.isOn() { proactiveSection }   // U1 — the screen hints
                dailySummarySection
                weeklyPatternsSection
                voiceQuestionSection
            }
        case .integrations:
            VStack(spacing: MW.sp12) {
                twoColumn(fileIndexingSection, appleNotesSection)
                calendarSection
                obsidianSyncSection
                agentConnectSection
            }
        case .agent:
            VStack(spacing: MW.sp12) {
                agentSection
            }
        }
    }

    /// Two-column row — pairs two small sections so neither stretches across the
    /// whole 640-pt content column. Equal widths, glass gap between.
    @ViewBuilder
    private func twoColumn<L: View, R: View>(_ left: L, _ right: R) -> some View {
        let layout = pairsBeside ? AnyLayout(HStackLayout(alignment: .top, spacing: MW.sp12))
                                 : AnyLayout(VStackLayout(spacing: MW.sp12))
        layout {
            left.frame(maxWidth: .infinity, alignment: .topLeading)
            right.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// A setting's name with its control at the right; in a narrow window the control goes under the name.
    private func labeledRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        let control = control()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                Text(label).font(MW.mono).foregroundStyle(MW.textSecondary).lineLimit(1).fixedSize()
                Spacer()
                control
            }
            VStack(alignment: .leading, spacing: MW.sp8) {
                Text(label).font(MW.mono).foregroundStyle(MW.textSecondary)
                control
            }
        }
    }

    // MARK: - Shared Dividers

    private var divider: some View {
        Rectangle().fill(MW.border).frame(height: MW.hairline)
    }

    private var verticalDivider: some View {
        Rectangle().fill(MW.border).frame(width: MW.hairline)
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack {
            Text("Settings")
                .font(MW.monoTitle)
                .foregroundStyle(MW.textPrimary)
            Spacer()
        }
        .padding(.horizontal, MW.sp16)
        .padding(.top, MW.sp8)
        .padding(.bottom, MW.sp4)
    }

    // MARK: - Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("TRANSCRIPTION").blocksLabel()

            // Engine picker: On-device / Cloud
            HStack(spacing: MW.sp4) {
                engineButton("On-device", value: "ondevice", subtitle: "WhisperKit · Metal GPU")
                engineButton("Cloud", value: "cloud", subtitle: license.isPro ? "Pro · Groq Whisper" : "API · OpenAI or Groq")
            }
            if let note = Self.engineNote(onDeviceStandsInForCloud:
                                            AppDelegate.shared?.coordinator.onDeviceStandsInForCloud == true) {
                Text(note).font(MW.monoSm).foregroundStyle(MW.textMuted)
            }

            if settings.transcriptionEngine == "ondevice" {
                Text("Model").mwBadge().padding(.top, MW.sp4)
                ForEach(ModelManagerService.models) { info in
                    modelRow(info)
                }
                if case .failed(let error) = modelManager.phase {
                    Text(error).font(MW.monoSm).foregroundStyle(MW.recording).lineLimit(3)
                }
                Text("Runs locally on your Mac via Metal GPU.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            } else {
                if license.isPro {
                    HStack(spacing: MW.sp4) {
                        Circle().fill(MW.ok).frame(width: 6, height: 6)
                        Text("Included with Pro")
                            .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    }
                    .padding(.top, MW.sp4)
                }
                cloudTranscriptionSection
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// A4 — cloud chosen but out of reach: the one quiet line under the picker. No control is added.
    static func engineNote(onDeviceStandsInForCloud: Bool) -> String? {
        onDeviceStandsInForCloud ? "On-device is used until Pro or your own key is set." : nil
    }

    private func engineButton(_ label: String, value: String, subtitle: String) -> some View {
        let isActive = settings.transcriptionEngine == value
        return VStack(spacing: 2) {
            Text(label)
                .font(MW.mono)
                .foregroundStyle(isActive ? MW.textPrimary : MW.textMuted)
            Text(subtitle)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(MW.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, MW.sp8)
        .padding(.vertical, MW.sp4)
        .frame(maxWidth: .infinity)
        .mwSelectable(isActive, radius: MW.rSmall, resting: .surface)
        .contentShape(Rectangle())
        .onTapGesture { settings.transcriptionEngine = value }
    }

    private var cloudTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("Provider").mwBadge().padding(.top, MW.sp4)

            HStack(spacing: MW.sp4) {
                ForEach(CloudTranscriptionProvider.allCases) { prov in
                    cloudProviderButton(prov)
                }
            }

            // Groq API key field
            let activeProvider = CloudTranscriptionProvider(rawValue: settings.cloudTranscriptionProvider) ?? .groq
            if activeProvider == .groq {
                groqKeyField
            } else {
                // OpenAI key already handled in LLM section — show hint
                if settings.openaiKey.isEmpty {
                    Text("Set your OpenAI key in the LLM Provider section below.")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                } else {
                    HStack(spacing: MW.sp4) {
                        Circle().fill(MW.ok).frame(width: 6, height: 6)
                        Text("Using OpenAI key from LLM settings")
                            .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    }
                }
            }

        }
    }

    private func cloudProviderButton(_ prov: CloudTranscriptionProvider) -> some View {
        let isActive = settings.cloudTranscriptionProvider == prov.rawValue
        return VStack(spacing: 2) {
            Text(prov.displayName)
                .font(MW.mono)
                .foregroundStyle(isActive ? MW.textPrimary : MW.textMuted)
            Text(prov.subtitle)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(MW.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, MW.sp8)
        .padding(.vertical, MW.sp4)
        .frame(maxWidth: .infinity)
        .mwSelectable(isActive, radius: MW.rSmall, resting: .surface)
        .contentShape(Rectangle())
        .onTapGesture { settings.cloudTranscriptionProvider = prov.rawValue }
    }

    @ViewBuilder
    private var groqKeyField: some View {
        APIKeyField("Groq API Key", key: \.groqKey)
        Text("Get a free key at console.groq.com")
            .font(MW.monoSm).foregroundStyle(MW.textMuted)
    }

    /// ITER-054 — optional BYOK Deepgram for MEETING diarization. Works on any
    /// tier: with a key set, meetings transcribe in one diarized pass on the
    /// user's own Deepgram account (real speaker labels); dictations unaffected.
    @ViewBuilder
    private var deepgramKeyField: some View {
        GlassDivider()
        Text("Meeting diarization (optional)")
            .font(MW.mono).foregroundStyle(MW.textSecondary)
        APIKeyField("Deepgram API Key", key: \.deepgramKey)
        Text("With a key set, meetings are transcribed on YOUR Deepgram account with real speaker labels (who said what) in one pass. Voice dictations are unaffected. console.deepgram.com")
            .font(MW.monoSm).foregroundStyle(MW.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The same optional BYOK deal on a second provider. Tried after Deepgram:
    /// that one is generally available, this model is in public preview, and a
    /// preview model is what took the vision path down this month.
    @ViewBuilder
    private var geminiKeyField: some View {
        APIKeyField("Gemini API Key", key: \.geminiKey)
        Text("Alternative to the above, on YOUR Google account. Speaker labels for up to 8 voices; long meetings are sent in 25-minute pieces because diarization is capped at 30 minutes per request. Used only if the Deepgram field is empty or fails. aistudio.google.com")
            .font(MW.monoSm).foregroundStyle(MW.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modelRow(_ info: ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: MW.spaceXs) {
                Text(info.displayName)
                    .font(MW.mono)
                    .foregroundStyle(settings.selectedModel == info.id ? MW.textPrimary : MW.textSecondary)
                Text("\(info.description) (\(info.size))")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
            Spacer()
            modelAction(info)
        }
        .padding(.vertical, MW.sp4)
        .padding(.horizontal, MW.sp8)
        .mwSelectable(settings.selectedModel == info.id, radius: MW.rTiny, resting: .none)
    }

    /// True when THIS model is on disk but its load into the engine failed
    /// (ITER-058.3). Keyed on the dedicated marker, not the download `phase`:
    /// an unrelated download running (or finishing) must neither hide nor erase
    /// a load failure (Codex).
    private func isLoadFailure(_ modelId: String) -> Bool {
        modelManager.failedToLoadModelId == modelId && modelManager.isDownloaded(modelId)
    }

    @ViewBuilder
    private func modelAction(_ info: ModelInfo) -> some View {
        if modelManager.isDownloaded(info.id) {
            if settings.selectedModel == info.id {
                // ITER-058.3 (Codex) — a downloaded-but-broken ACTIVE model had
                // no retry in Settings (only onboarding did). Re-running the
                // download fast-paths cached files and re-triggers the load.
                if isLoadFailure(info.id) {
                    BlocksButton(label: "Retry") {
                        modelManager.startDownload(info.id)
                    }
                } else {
                    Text("Active")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.ok)
                }
            } else {
                BlocksButton(label: "Use") {
                    // ITER-058.3 — an explicit pick anywhere cancels the
                    // quick-start background upgrade: the user chose, we obey.
                    settings.pendingBestModelUpgrade = false
                    settings.selectedModel = info.id
                }
            }
        } else if modelManager.isDownloading, modelManager.currentDownloadModel == info.id {
            // `isDownloading` too, not just the id: a FAILED download keeps
            // currentDownloadModel set so the error text stays visible, and the
            // row used to freeze on stale progress with no way to retry (Codex).
            downloadProgress
        } else {
            BlocksButton(label: "Download") {
                // ITER-058.3 — same explicit-pick rule as USE (a Settings
                // download must not later trigger a surprise 950 MB upgrade).
                settings.pendingBestModelUpgrade = false
                modelManager.startDownload(info.id)
            }
            .opacity(modelManager.isDownloading ? 0.4 : 1.0)
            .allowsHitTesting(!modelManager.isDownloading)
        }
    }

    private var downloadProgress: some View {
        VStack(spacing: MW.spaceXs) {
            if modelManager.phase == .verifying {
                ProgressView().controlSize(.small)
                Text("Verifying…").font(MW.monoSm).foregroundStyle(MW.textMuted)
            } else {
                ProgressView(value: modelManager.downloadProgress)
                    .frame(width: 80)
                    .tint(MW.textSecondary)
                Text(progressText).font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
    }

    private var progressText: String {
        let pct = Int(modelManager.downloadProgress * 100)
        return modelManager.downloadSpeed.isEmpty ? "\(pct)%" : "\(pct)% \(modelManager.downloadSpeed)"
    }

    // MARK: - Microphone

    /// User-picked input device. Empty preferredInputDeviceUID = follow macOS
    /// default. List is enumerated on view appear; the refresh button re-pulls
    /// for newly-plugged devices.
    @State private var availableInputs: [AudioInputDevice] = []
    @State private var loadingInputs = false

    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            Text("MICROPHONE").blocksLabel()

            HStack(spacing: MW.sp12) {
                Image(systemName: "mic")
                    .font(.system(size: 13))
                    .foregroundStyle(MW.textSecondary)
                Picker("", selection: $settings.preferredInputDeviceUID) {
                    Text("System default").tag("")
                    if !availableInputs.isEmpty {
                        Divider()
                        ForEach(availableInputs) { dev in
                            Text(dev.name).tag(dev.uid)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    loadInputs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(MW.textMuted)
                        .padding(6)
                }
                .buttonStyle(.plain)
                .help("Refresh the device list")
            }

            Text("Pick which mic the app records from. Leave \"System default\" to follow macOS — switches automatically when you plug in AirPods or unplug a USB mic.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
        .onAppear {
            loadInputs()
        }
    }

    /// The device list is read off the main thread, one read at a time and with a deadline: a call into the audio
    /// system can wait on coreaudiod (ITER-086). A read that does not answer keeps the list as it was and frees the
    /// refresh button; its late answer is dropped (Kimi review, P3).
    private func loadInputs() {
        guard !loadingInputs else { return }
        loadingInputs = true
        MicHardware().run({ AudioInputCatalog.availableInputDevices() }, done: { result in
            loadingInputs = false
            if case .success(let devices) = result { availableInputs = devices }
        }, late: { _ in })
    }

    // MARK: - Language

    private let languages: [(String, String)] = [
        ("RU", "ru"), ("EN", "en"), ("ES", "es"), ("FR", "fr"),
        ("DE", "de"), ("ZH", "zh"), ("JA", "ja"), ("KO", "ko"),
        ("PT", "pt"), ("IT", "it"), ("UK", "uk")
    ]

    private let translateLanguages: [(String, String)] = [
        ("RU", "ru"), ("EN", "en"), ("ES", "es"), ("FR", "fr"),
        ("DE", "de"), ("ZH", "zh"), ("JA", "ja"), ("KO", "ko"),
        ("PT", "pt"), ("IT", "it"), ("UK", "uk"), ("Z", "genz")
    ]

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("LANGUAGE").blocksLabel()

            WrappingHStack(items: languages, spacing: MW.sp4) { lang in
                Text(lang.0)
                    .font(MW.monoSm)
                    .foregroundStyle(settings.transcriptionLanguage == lang.1 ? MW.textPrimary : MW.textSecondary)
                    .padding(.horizontal, MW.sp8)
                    .padding(.vertical, MW.sp4)
                    .mwSelectable(settings.transcriptionLanguage == lang.1, radius: MW.rTiny)
                    .onTapGesture { settings.transcriptionLanguage = lang.1 }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    // MARK: - Processing

    private var processingSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("TEXT PROCESSING").blocksLabel()

            ForEach(ProcessingMode.allCases) { mode in
                HStack {
                    Text(mode.displayName)
                        .font(MW.mono)
                        .foregroundStyle(settings.processingMode == mode.rawValue ? MW.textPrimary : MW.textSecondary)
                    if mode.needsPro && !license.isPro {
                        Text("PRO").font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(MW.accent)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(MW.accent.opacity(0.12))
                    }
                    Spacer()
                    if settings.processingMode == mode.rawValue {
                        Text("\u{25CF}").font(.system(size: 8)).foregroundStyle(MW.textPrimary)
                    } else {
                        Text("\u{25CB}").font(.system(size: 8)).foregroundStyle(MW.textMuted)
                    }
                }
                .padding(.vertical, MW.sp8)
                .padding(.horizontal, MW.sp8)
                .mwSelectable(settings.processingMode == mode.rawValue, radius: MW.rTiny, resting: .none)
                .contentShape(Rectangle())
                .onTapGesture { pickProcessingMode(mode) }
            }

            let desc = (ProcessingMode(rawValue: settings.processingMode) ?? .raw).description
            Text(desc).font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// A tap on a mode. Target without Pro opens the Target window on its Pro screen instead (ITER-085); any choice
    /// here ends a "turn Target on once Pro is active" press.
    private func pickProcessingMode(_ mode: ProcessingMode) {
        TargetIntro.forgetWanted()
        switch ProcessingModePick.tap(mode, isPro: license.isPro) {
        case .select: settings.processingMode = mode.rawValue
        case .showPro: AppDelegate.shared?.showTargetIntro(turningOn: true, takesFocus: true)
        }
    }

    // MARK: - Translation

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("TRANSLATION").blocksLabel()

            WrappingHStack(items: translateLanguages, spacing: MW.sp4) { lang in
                Text(lang.0)
                    .font(MW.monoSm)
                    .foregroundStyle(settings.translateTo == lang.1 ? MW.textPrimary : MW.textSecondary)
                    .padding(.horizontal, MW.sp8)
                    .padding(.vertical, MW.sp4)
                    .mwSelectable(settings.translateTo == lang.1, radius: MW.rTiny)
                    .onTapGesture { settings.translateTo = lang.1 }
            }

            Text("Press Right \u{2325} to record + translate.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    // MARK: - Text Style

    private var textStyleSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            HStack {
                Text("TEXT STYLE").blocksLabel()
                Text("PRO").font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(MW.accent)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(MW.accent.opacity(0.12))
            }

            Toggle(isOn: $settings.textStyleLowercaseStart) {
                Text("Start with lowercase").font(MW.mono).foregroundStyle(MW.textSecondary)
            }
            .toggleStyle(.switch)
            .disabled(!license.isPro)

            Toggle(isOn: $settings.textStyleNoPeriod) {
                Text("No period at end").font(MW.mono).foregroundStyle(MW.textSecondary)
            }
            .toggleStyle(.switch)
            .disabled(!license.isPro)

            Toggle(isOn: $settings.textStyleNoCapitalization) {
                Text("No auto-capitalization").font(MW.mono).foregroundStyle(MW.textSecondary)
            }
            .toggleStyle(.switch)
            .disabled(!license.isPro)

            if !license.isPro {
                Text("Upgrade to Pro to customize text style.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    // MARK: - Account

    /// D6 — Free: Get Pro opens the site's account page (sign in or create the account, then the plans); the
    /// link is shown when the browser does not open.
    private var getProButton: some View {
        HStack(spacing: MW.sp8) {
            Button {
                accountLinkShown = !AccountPage.open()
            } label: {
                Text("Get Pro")
                    .font(MW.mono)
                    .foregroundStyle(MW.onAccent)
                    .padding(.horizontal, MW.sp16)
                    .padding(.vertical, MW.sp4)
                    .background(Capsule(style: .continuous).fill(MW.ok))
            }
            .buttonStyle(.plain)
            Text("$30 a year").font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("ACCOUNT").blocksLabel()

            if license.isPro {
                // Signed in + Pro
                HStack(spacing: MW.sp8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: MW.sp4) {
                            Text(license.email ?? "Pro")
                                .font(MW.mono)
                                .foregroundStyle(MW.textPrimary)
                                .lineLimit(1)
                            Text("PRO")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(MW.onAccent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MW.ok)
                        }
                        // A2 — the billing period from the session answer; none known, no line.
                        if let plan = LicenseService.planLabel(interval: license.billingInterval) {
                            Text(plan).font(MW.monoSm).foregroundStyle(MW.textMuted)
                        }
                        if let date = license.renewalDate {
                            let formatter = { () -> DateFormatter in let f = DateFormatter(); f.dateStyle = .medium; return f }()
                            if license.cancelAtPeriodEnd {
                                Text("Expires \(formatter.string(from: date))")
                                    .font(MW.monoSm).foregroundStyle(MW.recording)
                            } else {
                                Text("Renews \(formatter.string(from: date))")
                                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                            }
                        }
                    }
                    Spacer()
                    Button("Sign out") {
                        license.signOut()
                    }
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
                    .buttonStyle(.plain)
                }
            } else if let email = license.email {
                // Signed in but no Pro
                VStack(alignment: .leading, spacing: MW.sp4) {
                    Text(email).font(MW.mono).foregroundStyle(MW.textPrimary)
                    Text("Free plan")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)

                    getProButton.padding(.top, MW.sp4)

                    Button("Sign out") { license.signOut() }
                        .font(MW.monoSm).foregroundStyle(MW.textMuted).buttonStyle(.plain)
                }
            } else {
                // Not signed in: buy on the site, or sign in to the Pro bought there.
                VStack(alignment: .leading, spacing: MW.sp4) {
                    Text("Free plan")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    getProButton.padding(.top, MW.sp4)
                    // In Settings' own type, as "Show onboarding" below it — the onboarding's link is set in SF Pro.
                    Button { accountLinkShown = !AccountPage.open() } label: {
                        Text("Already have Pro? Sign in").font(MW.monoSm).foregroundStyle(MW.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if accountLinkShown {
                AccountLinkFallback()
            }

            if license.isActivating {
                HStack(spacing: MW.sp4) {
                    ProgressView().controlSize(.small)
                    Text("Activating...").font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
            }

            if let error = license.lastError {
                Text(error).font(MW.monoSm).foregroundStyle(MW.recording)
            }

            Button {
                AppDelegate.shared?.showOnboarding()
            } label: {
                Text("Show onboarding")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
            .buttonStyle(.plain)

            // ITER-056 — meeting-minutes meter. Meetings-only quota; dictations
            // never blocked. Fetched from the worker on section appear.
            if license.isPro, let u = license.usage {
                GlassDivider()
                HStack {
                    Text("MEETING MINUTES").blocksLabel()
                    Spacer()
                    Text("\(Int(u.balance)) of \(Int(u.limit)) left\(resetDaySuffix(u.periodStart))")
                        .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(MW.border)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(u.balance / max(u.limit, 1) < 0.1 ? MW.processing : MW.ok)
                            .frame(width: geo.size.width * min(1, max(0, u.balance / max(u.limit, 1))))
                    }
                }
                .frame(height: 7)
                Text("Only meetings consume minutes. Voice dictations are never blocked.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }

            // ITER-056 — GitHub star promo (3-stage lifecycle, see GitHubStarPromo).
            if GitHubStarPromo.isVisible(stage: settings.githubStarStage) {
                HStack(spacing: MW.sp8) {
                    Text("⭐").font(.system(size: 13))
                    Text("Enjoying MetaWhisp? Star it on GitHub — it helps the project.")
                        .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: MW.sp8)
                    Button("Star") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/metawhisp/metawhisp")!)
                        settings.githubStarStage = GitHubStarPromo.afterStarClick(stage: settings.githubStarStage)
                    }
                    .buttonStyle(.plain)
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textPrimary)
                    .padding(.horizontal, MW.sp8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    if GitHubStarPromo.showsClose(stage: settings.githubStarStage) {
                        Button {
                            settings.githubStarStage = GitHubStarPromo.afterCloseClick(stage: settings.githubStarStage)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(MW.textMuted)
                        }
                        .buttonStyle(.plain)
                        .help("Hide")
                    }
                }
                .padding(MW.sp8)
                .overlay(RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
        // Codex review — id-bound so signing in WHILE Settings is open
        // re-fetches (a bare .task runs once per view identity).
        .task(id: license.licenseKey) { await license.fetchUsage() }
    }

    /// «· resets on the 25th» from the worker's period_start (day-of-month).
    private func resetDaySuffix(_ periodStart: String?) -> String {
        guard let p = periodStart, p.count >= 10,
              let day = Int(p.suffix(2)) else { return "" }
        let suffix: String
        switch day % 10 {
        case 1 where day != 11: suffix = "st"
        case 2 where day != 12: suffix = "nd"
        case 3 where day != 13: suffix = "rd"
        default: suffix = "th"
        }
        return " · resets on the \(day)\(suffix)"
    }

    // MARK: - Hotkeys

    private var hotkeySection: some View {
        Self.hotkeyControls(
            transcribe: $settings.transcribeHotkeyEnabled,
            translate: $settings.translateHotkeyEnabled,
            voiceQuestion: $settings.voiceQuestionHotkeyEnabled,
            autoTranslate: $settings.autoTranslateHotkeyEnabled,
            mode: $settings.hotkeyMode
        )
    }

    /// The settings controls can be hosted without starting unrelated account services.
    static func hotkeyControls(transcribe: Binding<Bool>, translate: Binding<Bool>,
                               voiceQuestion: Binding<Bool>, autoTranslate: Binding<Bool>,
                               mode: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            Text("HOTKEYS").blocksLabel()

            hotkeyRow(
                "Transcribe", desc: "Right ⌘ — short tap. Result auto-pasted to active app.",
                badge: "Tap", keys: ["right", "\u{2318}"],
                isOn: transcribe
            )
            hotkeyRow(
                "Translate", desc: "Right ⌥ — short tap. Translates to your preferred target language.",
                badge: "Tap", keys: ["right", "\u{2325}"],
                isOn: translate
            )
            hotkeyRow(
                "Voice question", desc: "Hold Right ⌘ ≥ 0.5s — speak, release. Reply spoken aloud.",
                badge: "Hold", keys: ["right", "\u{2318}"],
                isOn: voiceQuestion
            )
            hotkeyRow(
                "Auto-translate (input)", desc: "Hold Right ⌥ ≥ 1.5s — translates live mic input as you speak.",
                badge: "Hold", keys: ["right", "\u{2325}"],
                isOn: autoTranslate
            )

            Rectangle().fill(MW.border).frame(height: MW.hairline)

            Text("MODE").blocksLabel()

            HStack(spacing: MW.sp4) {
                modeButton("Toggle", value: "toggle",
                           desc: "press to start/stop", selection: mode)
                modeButton("Push-to-talk", value: "pushToTalk",
                           desc: "hold to record", selection: mode)
            }

            Text("Toggle: tap for dictation, hold for voice questions. Push-to-Talk: hold for dictation. Each action has its own switch.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// One fixed hotkey: what it does, its keys, and the switch that turns
    /// just this action off. An off row dims its keys — the panel shows what
    /// the app will answer.
    private static func hotkeyRow(_ action: String, desc: String, badge: String, keys: [String],
                           isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: MW.sp12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(MW.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(desc).font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                hotkeyBadge(badge)
                    .opacity(isOn.wrappedValue ? 1 : 0.35)
                ForEach(keys, id: \.self) { key in
                    Keycap(text: key)
                        .opacity(isOn.wrappedValue ? 1 : 0.35)
                }
                onOffChip(action, isOn: isOn)
            }
            .layoutPriority(1)
        }
    }

    /// Small badge — Tap / Hold — distinguishes press-and-release
    /// from press-and-hold actions in the hotkey panel.
    private static func hotkeyBadge(_ text: String) -> some View {
        let hold = text == "Hold"
        return Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(hold ? MW.accent : MW.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(hold ? MW.accent.opacity(0.14) : MW.palette.rest.color))
    }

    private static func modeButton(_ label: String, value: String, desc: String,
                                   selection: Binding<String>) -> some View {
        let isSelected = selection.wrappedValue == value
        return VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? MW.textPrimary : MW.textSecondary)
            Text(desc)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(isSelected ? MW.textSecondary : MW.textMuted)
        }
        .padding(.horizontal, MW.sp12)
        .padding(.vertical, MW.sp10)
        .frame(maxWidth: .infinity)
        .mwSelectable(isSelected, radius: MW.rSmall, resting: .surface)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.12)) { selection.wrappedValue = value }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("OPTIONS").blocksLabel()

            // Theme
            labeledRow("Theme") {
                HStack(spacing: 2) {
                    themeButton("Dark", value: "dark")
                    themeButton("Light", value: "light")
                    themeButton("Auto", value: "auto")
                }
                .mwSegmentTrack()
            }

            // Accent — 5 swatches per Liquid Glass design spec § 10 Step 1.
            // Live-updates `MW.accent` everywhere. Default `mono` keeps current
            // monochrome look; user opts into a colored preset here.
            // Each swatch wraps a fixed-width slot so circles + labels of
            // different lengths ("Mono" vs "Electric" vs "Warm Orange") stay
            // visually equidistant.
            labeledRow("Accent") {
                HStack(spacing: 0) {
                    ForEach(MW.accentPresets, id: \.id) { preset in
                        AccentSwatch(
                            presetID: preset.id,
                            label: preset.label,
                            isSelected: settings.accentColor == preset.id,
                            onTap: { settings.accentColor = preset.id }
                        )
                        .frame(width: 56)
                    }
                }
            }

            toggleRow("Sound effects", isOn: $settings.soundEnabled)
            toggleRow("Auto-paste", isOn: $settings.autoSubmit)

            // Launch-at-login. Source of truth = SMAppService.mainApp registration,
            // NOT @AppStorage — system can flip it from System Settings → Login
            // Items, and a local mirror would silently drift. We bind the toggle
            // through LaunchAtLoginManager.shared, which round-trips register/
            // unregister + re-reads status so UI stays consistent with the OS.
            toggleRow("Launch at login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { _ = launchAtLogin.setEnabled($0) }
            ))
            Text(launchAtLogin.statusDescription)
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)

            labeledRow("Week starts") {
                HStack(spacing: 2) {
                    weekDayButton("Mon", value: 2)
                    weekDayButton("Sun", value: 1)
                }
                .mwSegmentTrack()
            }

            if settings.soundEnabled {
                labeledRow("Sound style") {
                    HStack(spacing: 2) {
                        soundPresetButton("Default", value: "default")
                        soundPresetButton("Bass", value: "bass")
                        soundPresetButton("Signature", value: "signature")
                        soundPresetButton("Custom", value: "custom")
                    }
                    .mwSegmentTrack()
                }

                if settings.soundPreset == "custom" {
                    soundPickerRow("Start recording", role: "start")
                    soundPickerRow("Stop recording", role: "stop")
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private func soundPresetButton(_ label: String, value: String) -> some View {
        let isSelected = settings.soundPreset == value
        return Text(label)
            .font(MW.monoSm)
            .foregroundStyle(isSelected ? MW.textPrimary : MW.textMuted)
            .padding(.horizontal, MW.sp8)
            .padding(.vertical, 2)
            .mwSelectable(isSelected, radius: 999, resting: .none)
            .onTapGesture {
                settings.soundPreset = value
                NotificationCenter.default.post(name: .init("ReloadSounds"), object: nil)
            }
    }

    private func themeButton(_ label: String, value: String) -> some View {
        let isSelected = settings.appTheme == value
        return Text(label)
            .font(MW.monoSm)
            .foregroundStyle(isSelected ? MW.textPrimary : MW.textMuted)
            .padding(.horizontal, MW.sp8)
            .padding(.vertical, 2)
            .mwSelectable(isSelected, radius: 999, resting: .none)
            .onTapGesture {
                settings.appTheme = value
                MW.applyTheme(value)
            }
    }

    private func soundPickerRow(_ label: String, role: String) -> some View {
        HStack {
            Text(label).font(MW.monoSm).foregroundStyle(MW.textSecondary)
            Spacer()
            if let path = settings.customSound(for: role) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(MW.monoSm).foregroundStyle(MW.textPrimary)
                    .lineLimit(1)
                Button {
                    settings.setCustomSound(for: role, path: nil)
                    reloadSounds()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .medium)).foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
            } else {
                Text("Default").font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
            Button {
                pickSoundFile(for: role)
            } label: {
                Text("Choose").font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MW.textSecondary)
                    .padding(.horizontal, MW.sp8).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private func pickSoundFile(for role: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sound file for \(role)"
        // NO NSApp.activate(ignoringOtherApps:) — its aggressive form throws the
        // user to the main window's bound Space (see MainWindowController). The
        // panel keys itself from the already-foreground window — same as the
        // Obsidian-vault picker below, which has no activate and works fine.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // Copy to App Support so file persists
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let soundsDir = AppIdentity.current.supportDirectory(applicationSupport: appSupport)
                .appendingPathComponent("Sounds", isDirectory: true)
            try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            let dest = soundsDir.appendingPathComponent("\(role)_\(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
            settings.setCustomSound(for: role, path: dest.path)
            reloadSounds()
        }
    }

    private func reloadSounds() {
        // Notify SoundService to reload — it's accessed via coordinator
        NotificationCenter.default.post(name: .init("ReloadSounds"), object: nil)
    }

    private func weekDayButton(_ label: String, value: Int) -> some View {
        let isSelected = settings.weekStartsOn == value
        return Text(label)
            .font(MW.monoSm)
            .foregroundStyle(isSelected ? MW.textPrimary : MW.textMuted)
            .padding(.horizontal, MW.sp8)
            .padding(.vertical, 2)
            .mwSelectable(isSelected, radius: 999, resting: .none)
            .onTapGesture { settings.weekStartsOn = value }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(MW.mono).foregroundStyle(MW.textSecondary)
            Spacer()
            Self.onOffChip(label, isOn: isOn)
        }
    }

    /// The panel's on/off switch, drawn the same everywhere it appears (ITER-087: a switch in the user's accent,
    /// no longer an "ON"/"OFF" text box). The knob has a hairline ring so it shows on any accent, Mono included.
    static func onOffChip(_ label: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule(style: .continuous)
                    .fill(isOn.wrappedValue ? MW.controlTint : Color.primary.opacity(0.16))
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 1.5, x: 0, y: 1)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    // MARK: - Recording Overlay

    private let pillStyles: [(label: String, value: String, desc: String)] = [
        ("Capsule", "capsule", "Floating pill indicator"),
        ("Island Aura", "dotglow", "Notch aura glow"),
        ("Island Expand", "island", "Expanding notch"),
        ("Edge Glow", "glow", "Top edge light strip"),
        ("Shrek", "shrek", "Dancing avatar — tints red while transcribing"),
    ]

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("RECORDING OVERLAY").blocksLabel()

            VStack(spacing: MW.sp4) {
                ForEach(pillStyles, id: \.value) { style in
                    pillStyleRow(style)
                }
            }

            Text("Visual indicator shown while recording.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// Community CTA tucked into the otherwise-empty right-column space under the
    /// overlay card. Header + button only — no card border, no section label, no
    /// star count (per design). Uses the shared `GlassChipButton(accent:)` so the
    /// button follows the user's selected accent preset (mono / orange / electric
    /// / mint / violet) instead of any hardcoded colour.
    // (githubStarSection removed — ITER-056: the star promo lives in
    // accountSection with the 3-stage lifecycle, see GitHubStarPromo.)

    private func pillStyleRow(_ style: (label: String, value: String, desc: String)) -> some View {
        let isSelected = settings.pillStyle == style.value
        return HStack {
            VStack(alignment: .leading, spacing: MW.spaceXs) {
                Text(style.label)
                    .font(MW.mono)
                    .foregroundStyle(isSelected ? MW.textPrimary : MW.textSecondary)
                Text(style.desc)
                    .font(MW.monoSm)
                    .foregroundStyle(isSelected ? MW.textSecondary : MW.textMuted)
            }
            Spacer()
            if isSelected {
                Text("\u{25CF}").font(.system(size: 8)).foregroundStyle(MW.textPrimary)
            } else {
                Text("\u{25CB}").font(.system(size: 8)).foregroundStyle(MW.textMuted)
            }
        }
        .padding(.vertical, MW.sp8)
        .padding(.horizontal, MW.sp8)
        .mwSelectable(isSelected, radius: MW.rTiny, resting: .none)
        .contentShape(Rectangle())
        .onTapGesture {
            settings.pillStyle = style.value
            AppDelegate.shared?.overlay.preview(style: style.value)
        }
    }

    // MARK: - Cloud API

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("CLOUD LLM").blocksLabel()

            if license.isPro {
                HStack(spacing: MW.sp4) {
                    Circle().fill(MW.ok).frame(width: 6, height: 6)
                    Text("Included with Pro (Cerebras Qwen 3 235B)")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
            }

            // Provider selector — always visible
            HStack(spacing: MW.sp4) {
                ForEach(LLMProvider.allCases) { prov in
                    providerButton(prov)
                }
            }

            // API key field for active provider; switching provider starts a fresh draft.
            APIKeyField("\(activeProviderName) API Key", key: \.activeAPIKey)
                .id(settings.llmProvider)

            Text(cloudFooter)
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private func providerButton(_ prov: LLMProvider) -> some View {
        let isActive = settings.llmProvider == prov.rawValue
        return VStack(spacing: 2) {
            Text(prov.displayName)
                .font(MW.mono)
                .foregroundStyle(isActive ? MW.textPrimary : MW.textMuted)
            Text(prov.subtitle)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(MW.textMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, MW.sp8)
        .padding(.vertical, MW.sp4)
        .frame(maxWidth: .infinity)
        .mwSelectable(isActive, radius: MW.rSmall, resting: .surface)
        .contentShape(Rectangle())
        .onTapGesture { settings.llmProvider = prov.rawValue }
    }

    private var activeProviderName: String {
        (LLMProvider(rawValue: settings.llmProvider) ?? .openai).displayName
    }

    private var cloudFooter: String {
        let prov = (LLMProvider(rawValue: settings.llmProvider) ?? .openai).displayName
        let needsKey = ProcessingMode(rawValue: settings.processingMode)?.needsAPIKey == true
        return needsKey
            ? "Required for Structured mode and translation (Right \u{2325})."
            : "\(prov) key needed for Structured mode and translation. Raw/Clean work offline."
    }

    // MARK: - Integrations tab sections
    // (Meeting Recording, Screen Context, File Indexing, Apple Notes, Calendar
    //  — all external-data / capture integrations, previously in `intelligenceSection`.)

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Meeting Recording", isOn: $settings.meetingRecordingEnabled)
            if settings.meetingRecordingEnabled {
                Text("Records system audio from Zoom, Meet, Teams.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                // ITER-054 — BYOK Deepgram diarization. Lives HERE (not in the
                // cloud-dictation section, hidden for on-device users — Codex
                // review): the key affects MEETINGS regardless of the dictation
                // engine, on any tier.
                deepgramKeyField
                geminiKeyField
                GlassDivider()
                toggleRow("Auto-detect calls", isOn: $settings.autoDetectCalls)
                if settings.autoDetectCalls {
                    GlassDivider()
                    toggleRow("Auto-start (5s)", isOn: $settings.callsAutoStartEnabled)
                    Text(settings.callsAutoStartEnabled
                         ? "Recording starts automatically 5 seconds after a Zoom / Meet / Teams window is detected."
                         : "Only posts a notification. Click the menu bar to start recording manually.")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // ITER-012: layered defense against zombie recordings + per-meeting recap.
                GlassDivider()
                HStack {
                    Text("Stop on silence").font(MW.mono).foregroundStyle(MW.textSecondary)
                    Spacer()
                    Text("\(Int(settings.meetingSilenceStopMinutes)) min")
                        .font(MW.monoSm).foregroundStyle(MW.textPrimary)
                        .frame(width: 60, alignment: .trailing)
                }
                Slider(value: $settings.meetingSilenceStopMinutes, in: 1...15, step: 1)
                    .controlSize(.small)
                Text("Auto-stops recording after this many minutes of silence. Default 3 min.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                GlassDivider()
                HStack {
                    Text("Max duration").font(MW.mono).foregroundStyle(MW.textSecondary)
                    Spacer()
                    Text("\(Int(settings.meetingMaxDurationMinutes / 60))h")
                        .font(MW.monoSm).foregroundStyle(MW.textPrimary)
                        .frame(width: 60, alignment: .trailing)
                }
                Slider(value: $settings.meetingMaxDurationMinutes, in: 30...480, step: 30)
                    .controlSize(.small)
                Text("Hard cap. Recording always stops after this duration regardless of silence. Default 4h.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                GlassDivider()
                toggleRow("Recap notifications", isOn: $settings.meetingRecapNotifications)
                Text(settings.meetingRecapNotifications
                     ? "After each meeting: notification with title + extracted tasks/memories. Click → Library."
                     : "No post-meeting notification. View meetings in Library → Conversations.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                GlassDivider()
                toggleRow("In-app Recap popup", isOn: $settings.meetingRecapPopupEnabled)
                Text(settings.meetingRecapPopupEnabled
                     ? "After each meeting: floating card with summary + action items + memories. Copy / Open in Library / Dismiss buttons."
                     : "No post-meeting popup. Recap still saved to Conversations.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                // ITER-076 — the live hints. One answer at a time: on the
                // shortcut, or by itself when the other side asks a question.
                GlassDivider()
                toggleRow("Live hints during calls", isOn: $settings.liveMeetingAdviceEnabled)
                Text("During a recorded call, MetaWhisp shows what to say — on your shortcut, or by itself when asked a question.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.liveMeetingAdviceEnabled {
                    GlassDivider()
                    toggleRow("Answer questions automatically", isOn: $settings.meetingAutoAnswer)
                    Text("When the other side asks you something, MetaWhisp shows an answer. Small talk shows nothing.")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    GlassDivider()
                    helpShortcutRow
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// ITER-076 P5 — the help shortcut: the combo, the recorder that changes
    /// it, and the reason it was refused or could not be registered.
    private var helpShortcutRow: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            HStack {
                Text("Help shortcut").font(MW.mono).foregroundStyle(MW.textSecondary)
                Spacer()
                if helpShortcutRecorder.isRecording {
                    Text("Press a shortcut…").font(MW.monoSm).foregroundStyle(MW.textMuted)
                } else {
                    HStack(spacing: 4) {
                        ForEach(Array(MeetingHelpLabel.parts(keyCode: settings.meetingHelpKeyCode,
                                                           modifiers: settings.meetingHelpModifiers).enumerated()),
                                id: \.offset) { _, part in
                            Keycap(text: part)
                        }
                    }
                    Button("Change") { startHelpShortcutRecording() }
                        .buttonStyle(.plain)
                        .font(MW.label).tracking(0.8)
                        .foregroundStyle(MW.textSecondary)
                        .padding(.horizontal, MW.sp8).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                            .stroke(MW.border, lineWidth: 0.5))
                }
            }
            if let refusal = helpShortcutRecorder.refusal {
                Text(refusal).font(MW.monoSm).foregroundStyle(.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = meetingHelpHotkey.registrationError {
                Text(failure).font(MW.monoSm).foregroundStyle(.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if helpShortcutRecorder.isRecording {
                Text("Esc cancels.").font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
        .onDisappear { helpShortcutRecorder.stop() }
    }

    /// Starts the recorder: the next key the Settings window sees is the
    /// shortcut.
    private func startHelpShortcutRecording() {
        helpShortcutRecorder.onAccepted = { combo in
            settings.meetingHelpKeyCode = combo.keyCode
            settings.meetingHelpModifiers = combo.modifiers
        }
        helpShortcutRecorder.start()
    }

    /// ITER-015 — Proactive chip that surfaces relevant memories/past decisions/waiting-on
    /// tasks while the user is composing a reply in Slack/Mail/etc. Opt-in. Requires
    /// Screen Context on (feeds on its ScreenContext pipeline) + Pro (needs embeddings).
    private var proactiveSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Screen Agent", isOn: $settings.proactiveEnabled)
            if settings.proactiveEnabled {
                // ITER-070 — the old copy promised a peripheral chip showing
                // 2-3 memories and "never a notification". The app has not
                // behaved that way for a long time, and copy describing a
                // feature that no longer exists is worse than none.
                Text("MetaWhisp watches the apps you allow and occasionally says one specific thing — a deadline someone is waiting on, a mistake on screen, a conflict with something you decided earlier. Most of the time it says nothing, which is the point. Comments collect in MetaChat → Inbox, including the ones it held back.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                GlassDivider()

                // One choice, in plain language, instead of intervals in three
                // different places.
                Text("How often").font(MW.mono).foregroundStyle(MW.textSecondary)
                Picker("", selection: $settings.screenAgentPacing) {
                    ForEach(ScreenAgentPacing.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text((ScreenAgentPacing(rawValue: settings.screenAgentPacing) ?? .balanced).explanation)
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                GlassDivider()

                // ITER-069 — its own consent, never bundled. Agreeing to cloud
                // text is not agreeing to screenshots.
                toggleRow("Visual mode", isOn: $settings.screenAgentVisualConsent)
                Text(settings.screenAgentVisualConsent
                     ? "Visual enabled — one downscaled image of the allowed, focused window may be sent to the cloud vision model when text alone cannot answer. Never stored, never logged."
                     : "Text only — MetaWhisp reads recognized text and will not claim things only eyes can verify (a disabled button, a highlighted field).")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                toggleRow("Pause for now", isOn: $settings.screenAgentPaused)
                Text("Stops the interruptions without turning the feature off — held comments still collect in the Inbox.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if !settings.screenContextEnabled {
                    Text("⚠️ Requires Screen Context — turn that on above.")
                        .font(MW.monoSm).foregroundStyle(.orange.opacity(0.85))
                }
                GlassDivider()
                HStack {
                    Text("Cooldown").font(MW.mono).foregroundStyle(MW.textSecondary)
                    Spacer()
                    Text("\(Int(settings.proactiveCooldownMinutes)) min")
                        .font(MW.monoSm).foregroundStyle(MW.textPrimary)
                        .frame(width: 60, alignment: .trailing)
                }
                Slider(value: $settings.proactiveCooldownMinutes, in: 1...30, step: 1)
                    .controlSize(.small)
                Text("Minimum gap between chip surfaces. Default 10 min.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)

                GlassDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blacklist (comma-separated app names)").font(MW.mono).foregroundStyle(MW.textSecondary)
                    TextField("1Password, Keychain, Terminal…", text: $settings.proactiveBlacklist, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textPrimary)
                        .lineLimit(1...3)
                        .padding(8)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    Text("Substring match on app name. Sensitive apps stay silent.")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var screenContextSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Screen Context", isOn: $settings.screenContextEnabled)
            if settings.screenContextEnabled {
                Text("OCR via Apple Vision — fully on-device. Screenshots are never saved.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                GlassDivider()
                HStack {
                    Text("Mode").font(MW.mono).foregroundStyle(MW.textSecondary)
                    Spacer()
                    HStack(spacing: 2) {
                        contextModeButton("Blacklist", value: "blacklist")
                        contextModeButton("Whitelist", value: "whitelist")
                    }
                    .mwSegmentTrack()
                }
                // App list with picker — implements spec://intelligence/FEAT-0002#app-picker
                screenContextAppList

                GlassDivider()
                if UltraFeatures.isOn() { realtimeTaskDetectionRow }   // U1
                // ITER-057.1 — promotion loop opt-in (default off, like the
                // rest of proactive notifications).
                toggleRow("Notify when a task is promoted", isOn: $settings.taskPromotionNotificationsEnabled)
                Text("Screen-found task candidates auto-promote to My Tasks as slots free up (≈5 active). On = one notification per promoted task.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // ITER-053.1 — retention + one-click delete. Codex review: OUTSIDE
            // the `if screenContextEnabled` — the privacy escape hatch must
            // stay reachable after the user turns capture off (their existing
            // history doesn't vanish with the toggle).
            GlassDivider()
            HStack {
                Text("Keep history").font(MW.mono).foregroundStyle(MW.textSecondary)
                Spacer()
                Picker("", selection: $settings.screenRetentionDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .labelsHidden()
                .frame(width: 120)
                .onChange(of: settings.screenRetentionDays) { _, _ in
                    AppDelegate.shared?.pruneScreenHistory()
                }
            }
            Text("Raw screen text older than this is deleted automatically. Activity timeline entries are kept longer (\(settings.observationRetentionDays) days).")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Delete screen history…") {
                confirmDeleteScreenHistory = true
            }
            .buttonStyle(.plain)
            .font(MW.label).tracking(0.6)
            .foregroundStyle(MW.recording)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                        .stroke(MW.recording.opacity(0.4), lineWidth: 0.5))
            .confirmationDialog(
                "Delete ALL screen history?",
                isPresented: $confirmDeleteScreenHistory
            ) {
                Button("Delete everything", role: .destructive) {
                    deleteAllScreenHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every captured screen text, timeline entry, and everything derived from your screen: unconfirmed task candidates and screen memories (including their Obsidian copies). Tasks you promoted stay. This cannot be undone.")
            }
            if let result = screenHistoryDeleteResult {
                Text(result)
                    .font(MW.monoSm).foregroundStyle(MW.ok)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// Realtime task detection (ITER-006): the reactor's switch and what it does — built only with the Ultra switch on
    /// (U1), as the reactor runs only then.
    @ViewBuilder
    private var realtimeTaskDetectionRow: some View {
        toggleRow("Realtime task detection", isOn: $settings.realtimeScreenReactionEnabled)
        if settings.realtimeScreenReactionEnabled {
            Text("Catches commitments in your chats (\"I'll send it tomorrow\") and auto-completes tasks it sees you finish. Messengers, mail and work browser tabs only. Max 30 checks/hour. Needs Pro, a local model, or your API key.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ITER-053.1 — the one-click promise. Runs on the main actor against the
    /// shared container; result surfaced inline (no silent destructive ops).
    private func deleteAllScreenHistory() {
        guard let container = AppDelegate.shared?.historyService.modelContainer else { return }
        do {
            // Fence FIRST: extractor batches / realtime reactions awaiting
            // their LLM response were built from rows we're about to delete —
            // make them discard themselves instead of re-inserting.
            AppDelegate.shared?.screenExtractor.invalidatePendingWork()
            AppDelegate.shared?.realtimeScreenReactor.invalidatePendingWork()
            AppDelegate.shared?.proactiveContextService.invalidatePendingWork()
            let ctx = ModelContext(container)
            let deleted = try ScreenRetention.deleteAll(in: ctx, keeping: TrackerService.shared?.recordedTaskIds())
            // The destructive privacy action covers the in-session buffers
            // too — otherwise Advice keeps quoting "deleted" OCR for a while.
            AppDelegate.shared?.screenContext.clearInMemory()
            // External copies (Codex review): a batch delete bypasses the
            // MutationService hooks, so remove the Obsidian vault files for
            // the deleted artifacts explicitly.
            // Best-effort, like all post-commit hooks.
            let taskIds = deleted.taskIds
            let memoryIds = deleted.memoryIds
            Task { @MainActor in
                if let exporter = AppDelegate.shared?.obsidianExporter {
                    for id in taskIds { await exporter.deleteTaskFile(id) }
                    for id in memoryIds { await exporter.deleteMemoryFile(id) }
                }
            }
            screenHistoryDeleteResult = "Deleted \(deleted.contexts) captures, \(deleted.observations) timeline entries, \(deleted.tasks) unconfirmed tasks, \(deleted.memories) screen memories."
            NSLog("[ScreenRetention] ✅ delete-all: %d contexts, %d observations, %d tasks, %d memories",
                  deleted.contexts, deleted.observations, deleted.tasks, deleted.memories)
        } catch {
            screenHistoryDeleteResult = "Delete failed: \(error.localizedDescription)"
            NSLog("[ScreenRetention] ⚠️ delete-all failed: %@", error.localizedDescription)
        }
    }

    private var fileIndexingSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("File Indexing", isOn: $settings.fileIndexingEnabled)
            if settings.fileIndexingEnabled {
                Text("Scan local folders (e.g. your Obsidian vault) for .md/.txt files. MetaWhisp extracts durable facts about you and your projects into Memories.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                fileIndexingFolderList
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var appleNotesSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Apple Notes", isOn: $settings.appleNotesEnabled)
            if settings.appleNotesEnabled {
                Text("Reads recent Apple Notes via AppleScript. First run will prompt for Automation permission.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                scanNowButton { await AppDelegate.shared?.appleNotesReader.scanNow(ask: PermissionAsk()) }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var obsidianSyncSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Obsidian Sync", isOn: $settings.obsidianSyncEnabled)
            if settings.obsidianSyncEnabled {
                Text("Writes voices, meetings, tasks, memories and insights as Markdown files in your Obsidian vault. Date-first folders for time-bound entities, project-first for memories. Tasks support two-way delete.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(settings.obsidianVaultPath.isEmpty ? "(no vault picked)" : settings.obsidianVaultPath)
                        .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Pick Obsidian Vault"
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.obsidianVaultPath = url.path
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 10))
                            Text("Pick vault").font(MW.label).tracking(0.6)
                        }
                        .foregroundStyle(MW.textSecondary)
                        .glassChip(selected: false, radius: MW.rTiny)
                    }
                    .buttonStyle(.plain)
                }
                // ITER-035 v2 — manual bulk export. Rerenders every entity
                // in SwiftData → markdown. Idempotent (overwrites by id-path),
                // safe to run repeatedly.
                Button {
                    Task { @MainActor in
                        if let exp = AppDelegate.shared?.obsidianExporter {
                            _ = await exp.bulkExportAll()
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .font(.system(size: 10))
                        Text("Export everything to vault").font(MW.label).tracking(0.6)
                    }
                    .foregroundStyle(MW.textPrimary)
                    .glassChip(selected: false, radius: MW.rTiny)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// FEAT-0006 §8 (D3) — Claude Code and Codex keep the tasks of the folder they work in inside MetaWhisp.
    /// Connect registers MetaWhisp's MCP server with the agent and adds one rule to its global instructions;
    /// Disconnect removes both. Replaces the snapshot toggle and the setup-doc buttons.
    private var agentConnectSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            Text("AI agents").mwBadge()
            Text("Claude Code and Codex keep the tasks of the project you work in here.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ConnectableAgent.allCases) { agent in
                agentRow(agent)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
        .onAppear { agentConnector.refresh() }
    }

    private func agentRow(_ agent: ConnectableAgent) -> some View {
        let state = agentConnector.state(agent)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(agent.displayName).font(MW.mono).foregroundStyle(MW.textSecondary)
                if state == .connected {
                    Text("Connected").font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
                Spacer()
                if state == .working {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task {
                            if state == .connected {
                                await agentConnector.disconnect(agent)
                            } else {
                                await agentConnector.connect(agent)
                            }
                        }
                    } label: {
                        Text(state == .connected ? "Disconnect" : "Connect")
                            .font(MW.label).tracking(0.6)
                            .foregroundStyle(MW.textPrimary)
                            .glassChip(selected: false, radius: MW.rTiny)
                    }
                    .buttonStyle(.plain)
                }
            }
            if case .failed(let why) = state {
                Text(why).font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - AI Models (ITER-039 local LLM catalog)

    /// Section shown in the AI tab. Collapsed by default — `localLLMEnabled`
    /// toggle controls whether the model catalog is expanded. Keeps the
    /// section minimal for users who haven't opted in.
    private var aiModelsSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            Text("AI ENGINE").blocksLabel()
                // ITER-056 — cross-hint: this is TEXT intelligence (cleanup,
                // recaps, memories, chat); speech-to-text lives in Dictation.
                // ITER-044 — Foundation Models is a real backend now, so we only
                // clear a persisted FM selection when THIS Mac can't run it
                // (< macOS 26 → verdict .incompatible). On Tahoe+ the selection
                // is honoured and the auto-loader brings the on-device model up.
                .onAppear {
                    if let spec = ModelRegistry.model(byID: settings.localLLMActiveModelID),
                       spec.isFoundationModels,
                       !ModelCompatibility.verdict(for: spec).isDownloadable {
                        settings.localLLMActiveModelID = ""
                    }
                }

            // ALWAYS-VISIBLE routing indicator — TEMPORARILY DISABLED
            // 2026-05-19 on macOS 26 Tahoe. The view triggered NSISEngine
            // constraint-solver recursion (stack overflow) when the AI tab
            // is rendered. Suspect: HStack with mixed `.frame(maxWidth: .infinity)`
            // + `.lineLimit(1)` + nested `.background/.overlay` shapes confuses
            // macOS 26's stricter SwiftUI→AppKit autoresizing bridge.
            // Reintroduce after standalone repro + Layout Instruments trace.
            // currentAIRoutingIndicator

            // Master toggle — collapsed/expanded state driver.
            // ITER-051 F1.4 — the toggle now has the side effect it always
            // implied: OFF unloads the model (frees ~3 GB RAM and, since every
            // service gates on `isReady`, actually stops local routing); ON
            // with a persisted selection reloads it.
            toggleRow("Use local model for AI features",
                      isOn: $settings.localLLMEnabled)
                .onChange(of: settings.localLLMEnabled) { _, enabled in
                NSLog("[ITER-039] Settings toggle: local model %@", enabled ? "ON" : "OFF")
                    if enabled {
                        let id = settings.localLLMActiveModelID
                        guard !id.isEmpty else { return }
                        Task { @MainActor in
                            try? await LocalLLMService.shared.loadModel(id: id)
                        }
                    } else {
                        LocalLLMService.shared.unloadModel()
                    }
                }

            if !settings.localLLMEnabled {
                // Collapsed — one-line summary so user knows the section exists
                // and what it does. Tapping the toggle expands it.
                Text("Run AI features (structured text, memory, tasks, chat) on-device for free instead of through Pro proxy / API key. Toggle on to pick a model.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Expanded — system summary + cards.
                HStack(spacing: 6) {
                    Image(systemName: "cpu").font(.system(size: 10))
                    Text("Your Mac: \(SystemSpecs.summary)")
                        .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                }
                .padding(.bottom, 2)

                ForEach(ModelRegistry.allModels) { spec in
                    aiModelCard(spec)
                }

                if !ModelRegistry.allModels.contains(where: { $0.id == settings.localLLMActiveModelID }) {
                    Text("No active model yet. App keeps using Pro proxy / your API key for AI features in the meantime.")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .padding(.top, 4)
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// Compact 2-column model card. LEFT = identity + tagline + compat badge.
    /// RIGHT = stats + action button (right-aligned). Significantly shorter
    /// than the previous all-left-stacked layout — fits 5 cards in roughly
    /// the same vertical space as 2 cards before.
    private func aiModelCard(_ spec: ModelSpec) -> some View {
        let verdict = ModelCompatibility.verdict(for: spec)
        let isActive = settings.localLLMActiveModelID == spec.id

        return HStack(alignment: .top, spacing: 16) {
            // ── LEFT column ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                // Title row
                HStack(spacing: 6) {
                    Text(spec.displayName)
                        .font(MW.mono).fontWeight(.semibold)
                        .foregroundStyle(MW.textPrimary)
                    if isActive {
                        Text("Active")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(MW.onAccent)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(MW.ok)
                            .cornerRadius(2)
                    }
                }
                // Vendor + params
                Text("\(spec.vendor) · \(spec.paramsDisplay) · \(spec.quantization)")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                // Tagline
                Text(spec.bestForTagline)
                    .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Compatibility badge
                compatBadge(verdict)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── RIGHT column ──────────────────────────────────────────────
            VStack(alignment: .trailing, spacing: 3) {
                // Stars
                Text(String(repeating: "★", count: spec.quality) +
                     String(repeating: "☆", count: 5 - spec.quality))
                    .font(MW.monoSm).foregroundStyle(MW.textSecondary)
                // Speed + RAM packed
                if spec.isFoundationModels {
                    Text("native · ~\(spec.ramPeakGB) GB RAM")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                } else {
                    Text("\(spec.speedM1TokPerSec) tok/s · \(spec.ramPeakGB) GB RAM")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                }
                // Languages
                Text(spec.languages.joined(separator: " · "))
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                // Action button (always rendered, may be disabled)
                actionButton(for: spec, verdict: verdict, isActive: isActive)
                    .padding(.top, 2)
            }
            .frame(width: 180, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // macOS 26 fix: dropped outer `.frame(maxWidth: .infinity)` on
        // the HStack — collision with inner `.frame(maxWidth: .infinity)`
        // (LEFT) + `.frame(width: 180)` (RIGHT) caused NSISEngine to
        // recurse forever during constraint solve (crash 2026-05-19
        // 20:48 / 20:52 / 20:54). The HStack now sizes to the parent
        // section's padding container naturally.
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .mwSelectable(isActive, radius: MW.rSmall, resting: .outline)
    }

    /// Tiny always-visible status row that tells the user where their AI
    /// is running RIGHT NOW. Computed from `localLLMActiveModelID` +
    /// `LocalLLMService.isReady` + license + API-key state. Three flavors:
    ///   - **LOCAL** (green): a downloaded MLX model is loaded and ready,
    ///     OR Foundation Models is selected on Tahoe.
    ///   - **CLOUD** (blue): no local model active; Pro proxy or user's
    ///     own API key is the active LLM path.
    ///   - **INACTIVE** (dim): no API key, no Pro, no local — AI features
    ///     are silently no-op for this user.
    /// The row also names the specific provider/model so the user doesn't
    /// have to play detective: «Cerebras Qwen 3 235B (Pro)» vs
    /// «Phi-4 Mini Instruct (on M4 Max)».
    @ViewBuilder
    private var currentAIRoutingIndicator: some View {
        let (label, detail, color) = aiRoutingState()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(color)
            Text(detail)
                .font(MW.monoSm)
                .foregroundStyle(MW.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        // macOS 26 layout-engine workaround: pinning vertical sizing breaks
        // the NSISEngine constraint cycle this view contributed to (crash
        // 2026-05-19 NSISEngine excessive recursion).
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MW.rTiny, style: .continuous)
                .stroke(color.opacity(0.25), lineWidth: 0.5)
        )
    }

    /// Pure resolver — derive the (label, detail, color) tuple from current
    /// settings/license/local-model state. Kept separate from the View so
    /// the same routing logic can be re-used later (Dashboard widget,
    /// telemetry, status menu, etc.) without UI baggage.
    private func aiRoutingState() -> (label: String, detail: String, color: Color) {
        // Local path takes priority — if user activated a local model,
        // that's what's running (or about to run after warm-up).
        if !settings.localLLMActiveModelID.isEmpty,
           let spec = ModelRegistry.model(byID: settings.localLLMActiveModelID) {
            let chipBit = SystemSpecs.chipName  // e.g. "M4 Max"
            if spec.isFoundationModels {
                return (
                    "Local",
                    "\(spec.displayName) (\(chipBit) Neural Engine)",
                    MW.ok
                )
            }
            // MLX model. `isReady` reflects whether weights are loaded
            // into RAM; until that's true we're technically still on
            // cloud for this tick (Phase 4 will flip isReady to true).
            if LocalLLMService.shared.isReady {
                return (
                    "Local",
                    "\(spec.displayName) on \(chipBit)",
                    MW.ok
                )
            } else {
                return (
                    "Loading",
                    "\(spec.displayName) — warming up…",
                    MW.processing
                )
            }
        }

        // No local model — figure out which cloud path is active.
        if license.isPro {
            let providerLabel = settings.llmProvider == "cerebras"
                ? "Cerebras Qwen 3 235B"
                : "OpenAI GPT-4o-mini"
            return (
                "Cloud",
                "\(providerLabel) via Pro proxy",
                MW.ok
            )
        }

        // Non-Pro: check user-supplied API key (BYOK path).
        if !settings.activeAPIKey.isEmpty {
            let providerLabel = settings.llmProvider == "cerebras"
                ? "Cerebras (your key)"
                : "OpenAI (your key)"
            return ("Cloud", providerLabel, MW.ok)
        }

        // Nothing wired — AI features no-op for this user.
        return (
            "Inactive",
            "No API key, no Pro, no local model — AI features silently disabled",
            MW.textDim
        )
    }

    @ViewBuilder
    private func compatBadge(_ verdict: CompatibilityVerdict) -> some View {
        HStack(spacing: 4) {
            switch verdict {
            case .recommended:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                    .foregroundStyle(MW.ok)
                Text("Recommended for your Mac")
                    .font(MW.monoSm).foregroundStyle(MW.ok)
            case .slow(let reason):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                    .foregroundStyle(MW.processing)
                Text(reason)
                    .font(MW.monoSm).foregroundStyle(MW.processing)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            case .incompatible(let reason):
                Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                    .foregroundStyle(MW.recording)
                Text(reason)
                    .font(MW.monoSm).foregroundStyle(MW.recording)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for spec: ModelSpec, verdict: CompatibilityVerdict, isActive: Bool) -> some View {
        if spec.isFoundationModels {
            // ITER-044 — Foundation Models is a real on-device backend now. On
            // macOS 26+ (verdict .recommended) it's activatable; below 26 the
            // verdict is .incompatible and the compat badge already explains
            // why, so we render no button.
            if verdict.isDownloadable {
                foundationModelsActiveButton(spec: spec, isActive: isActive)
            }
        } else if verdict.isDownloadable {
            // MLX model. v1.3.5 ships the download path for Phi-4 Mini only
            // — other model architectures land in v1.4.0 with the full MLX
            // inference loop. So we render two flavors of "Download":
            //   - phi-4-mini → live button calling MLXModelManager
            //   - everything else → disabled with a "shipping later" tooltip
            mlxDownloadButton(spec: spec)
        } else {
            // Incompatible — show size as plain label, no button.
            Text(spec.downloadSizeDisplay)
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textDim)
                .padding(.horizontal, 8).padding(.vertical, 3)
        }
    }

    /// ITER-044 — Make-active control for the Apple Foundation Models card.
    /// No download / no weights / no trash: the model is built into macOS 26+.
    /// Three states mirror the MLX toggle:
    ///   • not selected          → «Make active» (sets ID + loads on-device)
    ///   • selected + loaded      → «Active» (click deactivates + unloads)
    ///   • selected + not loaded  → «Load now» (retry, e.g. after enabling
    ///     Apple Intelligence). A failed load (AI off / device ineligible /
    ///     model downloading) surfaces its reason inline via `localLLM.lastError`.
    @ViewBuilder
    private func foundationModelsActiveButton(spec: ModelSpec, isActive: Bool) -> some View {
        let isReady = LocalLLMService.shared.isReady && LocalLLMService.shared.currentModelID == spec.id
        let isLoadingThis = localLLM.isLoading && settings.localLLMActiveModelID == spec.id
        let label: String = {
            if isLoadingThis { return "Loading…" }
            if isActive && isReady { return "Active" }
            if isActive && !isReady { return "Load now" }
            return "Make active"
        }()
        VStack(alignment: .trailing, spacing: 2) {
            Button(label) {
                if isActive && isReady {
                    settings.localLLMActiveModelID = ""
                    Task { @MainActor in LocalLLMService.shared.unloadModel() }
                } else {
                    settings.localLLMActiveModelID = spec.id
                    Task { @MainActor in
                        try? await LocalLLMService.shared.loadModel(id: spec.id)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(MW.label).tracking(0.6)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle((isActive && isReady) ? MW.onAccent : MW.textPrimary)
            .background((isActive && isReady) ? MW.ok :
                        (isActive ? MW.processing.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                        .stroke(MW.border, lineWidth: 0.5))
            .disabled(localLLM.isLoading)
            // Inline reason when the on-device model refused to load (most
            // commonly: Apple Intelligence is switched off).
            if isActive, !isReady, !isLoadingThis, let err = localLLM.lastError {
                Text(err.errorDescription ?? "Couldn't start Apple Foundation Models")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(MW.recording)
                    .lineLimit(3)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    /// Download/Make-active control for an MLX model card. Three states:
    ///   - downloading (this spec) → progress label "53% · 1.2/2.3 GB"
    ///   - downloaded → "Make active" (or "Active") — once Step 4 wires
    ///     LocalLLMService into hasLLMAccess this actually starts using
    ///     the model
    ///   - not downloaded → "Download · 2.3 GB"
    /// Phi-4 Mini is the only model whose Download is wired in v1.3.5 — the
    /// other 3 MLX cards stay disabled until v1.4.0 ships their architecture
    /// adapters (see specs/iterations/ITER-039-local-llm.md → Step 4).
    @ViewBuilder
    private func mlxDownloadButton(spec: ModelSpec) -> some View {
        let isDownloading = mlxManager.activeDownloadID == spec.id
        let isDownloaded = mlxManager.downloadedIDs.contains(spec.id)
        let anotherDownloading = mlxManager.activeDownloadID != nil && !isDownloading
        // v1.3.5 ships Phi-4 Mini's download flow only. Other MLX models
        // need per-architecture inference code (Step 4) before their
        // weights are useful — until then we leave their Download dimmed.
        let isWiredInV135 = (spec.id == "phi-4-mini")

        if isDownloading {
            // Progress + Cancel pair. Progress label is informational; the
            // small ✕ button beside it cancels and surfaces a confirm-y
            // state via `MLXModelManager.cancelActiveDownload()`. Partial
            // shards stay on disk so the next Download resumes via Hub's
            // ETag check (no re-download of finished shards).
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    let pct = Int((mlxManager.progress * 100).rounded())
                    let mb = Double(mlxManager.bytesCompleted) / 1_048_576
                    Text("\(pct)% · \(String(format: "%.0f", mb)) MB")
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.processing)
                    Button {
                        mlxManager.cancelActiveDownload()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(MW.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download (partial files stay on disk for resume)")
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                            .stroke(MW.processing.opacity(0.4), lineWidth: 0.5))
                if mlxManager.retryAttempt > 1 {
                    Text("Retry \(mlxManager.retryAttempt)/3")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MW.recording)
                }
            }
        } else if isDownloaded {
            let isActive = settings.localLLMActiveModelID == spec.id
            let isReady = LocalLLMService.shared.isReady && LocalLLMService.shared.currentModelID == spec.id
            // Three-state button label:
            //   • selected + loaded   → «Active» (click deactivates + unloads)
            //   • selected + not loaded → «Load now» (click triggers loadModel,
            //     keeps ID. Happens after app restart since auto-load on
            //     launch was disabled to prevent watchdog SIGKILL.)
            //   • not selected         → «Make active» (sets ID + loads)
            let isLoadingThis = localLLM.isLoading && settings.localLLMActiveModelID == spec.id
            let label: String = {
                if isLoadingThis { return "Loading…" }
                if isActive && isReady { return "Active" }
                if isActive && !isReady { return "Load now" }
                return "Make active"
            }()
            HStack(spacing: 4) {
                Button(label) {
                    if isActive && isReady {
                        // Deactivating — also unload from memory.
                        NSLog("[ITER-039] Settings: deactivate %@ (Active clicked)", spec.id)
                        settings.localLLMActiveModelID = ""
                        Task { @MainActor in LocalLLMService.shared.unloadModel() }
                    } else {
                        // Either «Load now» (ID already set, just reload) or
                        // «Make active» (set ID + load). Either way: load.
                        NSLog("[ITER-039] Settings: %@ %@", isActive ? "Load now" : "Make active", spec.id)
                        settings.localLLMActiveModelID = spec.id
                        Task { @MainActor in
                            try? await LocalLLMService.shared.loadModel(id: spec.id)
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(MW.label).tracking(0.6)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle((isActive && isReady) ? MW.onAccent : MW.textPrimary)
                .background((isActive && isReady) ? MW.ok :
                            (isActive ? MW.processing.opacity(0.18) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                            .stroke(MW.border, lineWidth: 0.5))
                .disabled(localLLM.isLoading)   // F1.4 — no double-load
                Button {
                    removeDownloadedModel(spec)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(MW.textMuted)
                }
                .buttonStyle(.plain)
                .help("Delete downloaded weights (\(spec.downloadSizeDisplay)) to free disk space")
            }
        } else if isWiredInV135 {
            VStack(alignment: .trailing, spacing: 2) {
                Button("Download · \(spec.downloadSizeDisplay)") {
                    Task {
                        do {
                            _ = try await mlxManager.download(spec)
                        } catch {
                            NSLog("[ITER-039] download failed for \(spec.id): \(error.localizedDescription)")
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(MW.label).tracking(0.6)
                .foregroundStyle(anotherDownloading ? MW.textDim : MW.textPrimary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                            .stroke(MW.border, lineWidth: 0.5))
                .disabled(anotherDownloading)
                .help(anotherDownloading ? "Another model is downloading — wait for it to finish." :
                      "Downloads ~\(spec.downloadSizeDisplay) from HuggingFace. Resumes if interrupted.")
                // Show last error inline, if any.
                if let err = mlxManager.lastError[spec.id] {
                    Text(err)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MW.recording)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
            }
        } else {
            Button("Download · \(spec.downloadSizeDisplay)") { }
                .buttonStyle(.plain)
                .font(MW.label).tracking(0.6)
                .foregroundStyle(MW.textDim)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                            .stroke(MW.border.opacity(0.5), lineWidth: 0.5))
                .disabled(true)
                .help("Inference for \(spec.displayName) ships in v1.4.0. v1.3.5 enables Phi-4 Mini only.")
        }
    }

    /// Tear-down helper for the trash-icon button on a downloaded model
    /// card. Two-stage: (1) if this model is currently active, deactivate
    /// + unload it; (2) remove the on-disk weight shards via
    /// `MLXModelManager.remove(_:)`. Errors get logged but don't bubble to
    /// the UI — worst case the directory partially survives and the next
    /// download fully overwrites it.
    private func removeDownloadedModel(_ spec: ModelSpec) {
        // ITER-075 step 0 (0.4) — a copy that is not the owner's app never
        // deletes the shared weights, so it doesn't deactivate the model either.
        guard AppIdentity.current.mayDeleteSharedModels else {
            NSLog("[ITER-039] Settings: remove refused — only the main MetaWhisp app deletes shared models")
            return
        }
    NSLog("[ITER-039] Settings: removing weights for %@ (was active: %@)", spec.id, settings.localLLMActiveModelID == spec.id ? "yes" : "no")
        if settings.localLLMActiveModelID == spec.id {
            settings.localLLMActiveModelID = ""
            Task { @MainActor in LocalLLMService.shared.unloadModel() }
        }
        do {
            try mlxManager.remove(spec)
            NSLog("[ITER-039] ✅ removed weights for %@", spec.id)
        } catch {
            NSLog("[ITER-039] failed to remove \(spec.id): \(error.localizedDescription)")
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Calendar", isOn: $settings.calendarReaderEnabled)
            if settings.calendarReaderEnabled {
                Text("Reads your Apple Calendar (iCloud/Google/Exchange). Creates Tasks for upcoming events and extracts routine patterns into Memories.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                scanNowButton { await AppDelegate.shared?.calendarReader.scanNow(ask: PermissionAsk()) }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// Shared SCAN NOW button for readers.
    private func scanNowButton(_ action: @escaping () async -> Void) -> some View {
        Button {
            Task { @MainActor in await action() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise").font(.system(size: 10))
                Text("Scan now").font(MW.label).tracking(0.6)
            }
            .foregroundStyle(MW.textSecondary)
            .glassChip(selected: false, radius: MW.rTiny)
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    // MARK: - AI tab sections

    private var memoriesSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Memories", isOn: $settings.memoriesEnabled)
            if settings.memoriesEnabled {
                Text("Automatically extracts facts about you from screen activity + transcriptions. Used to personalize AI Advice.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var dailySummarySection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Daily Summary", isOn: $settings.dailySummaryEnabled)
            if settings.dailySummaryEnabled {
                Text("Nightly recap of conversations, tasks, memories, and top apps. Delivered via macOS notification and visible on the Dashboard.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                GlassDivider()
                HStack {
                    Text("Scheduled time").font(MW.mono).foregroundStyle(MW.textSecondary)
                    Spacer()
                    DatePicker(
                        "",
                        selection: Binding(
                            get: {
                                Calendar.current.date(
                                    bySettingHour: settings.dailySummaryHour,
                                    minute: settings.dailySummaryMinute,
                                    second: 0,
                                    of: Date()
                                ) ?? Date()
                            },
                            set: { newValue in
                                let comps = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                                settings.dailySummaryHour = comps.hour ?? 22
                                settings.dailySummaryMinute = comps.minute ?? 0
                                AppDelegate.shared?.dailySummaryService.startScheduler()
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// ITER-022 G5 — Weekly cross-conversation pattern digest. Sunday at user-
    /// chosen hour. Reads past 7 days of conversations + memories + tasks, sends
    /// to LLM, returns themes / people / stuck-loops / cross-context insights.
    private var weeklyPatternsSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Weekly Patterns", isOn: $settings.weeklyPatternsEnabled)
            if settings.weeklyPatternsEnabled {
                Text("Every Sunday: cross-conversation recap. Recurring themes, people who keep coming up, stuck loops, insights you can't see in any single meeting.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                GlassDivider()
                HStack {
                    Text("Sunday at").font(MW.mono).foregroundStyle(MW.textSecondary)
                    Spacer()
                    DatePicker(
                        "",
                        selection: Binding(
                            get: {
                                Calendar.current.date(
                                    bySettingHour: settings.weeklyPatternsHour,
                                    minute: 0, second: 0, of: Date()
                                ) ?? Date()
                            },
                            set: { newValue in
                                settings.weeklyPatternsHour = Calendar.current.component(.hour, from: newValue)
                                AppDelegate.shared?.weeklyPatternDetector.startScheduler()
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.compact)
                }
                Text("View past recaps in the Weekly Insights tab.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var adviceSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("AI Advice", isOn: $settings.adviceEnabled)
            if settings.adviceEnabled {
                if license.isPro {
                    Text("Contextual suggestions from screen activity + transcriptions, delivered via macOS notifications. Included with Pro — no API key required.")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Contextual suggestions based on screen activity and transcriptions. Uses your LLM provider (set in General).")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if settings.activeAPIKey.isEmpty {
                        hintRow(color: MW.recording,
                                "Add an \(activeProviderName) API key in General → Cloud API")
                    }
                }
                if !settings.memoriesEnabled {
                    hintRow(color: MW.processing,
                            "Enable Memories above for personalized advice (recommended)")
                }
                // ITER-022 G4 — Coach mode toggle. Opt-in (off by default).
                GlassDivider()
                toggleRow("Coach mode", isOn: $settings.adviceCoachMode)
                Text(settings.adviceCoachMode
                     ? "Direct accountability nudges based on stated commitments and patterns. Still NOT generic wellness or therapy."
                     : "Default: pure insight only — no nudges. Turn on for accountability push (when you slip a stated commitment, distract for too long, miss goal pace).")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private func hintRow(color: Color, _ text: String) -> some View {
        HStack(spacing: MW.sp6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(MW.monoSm).foregroundStyle(MW.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Agent (ITER-076 stage 8b)

    /// Settings → Agent (№ 153, owner decisions 8.1, 8.3, 8.7): the browser agent's switch; with Pro, what it sends
    /// and where — the disclosure's own title and rows — and the browser it uses: MetaWhisp's own Chrome window, or the
    /// user's own Chrome with its one-time setup; without Pro, that it needs Pro. Every word approved on 2026-10-06.
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow(AgentSetup.browserAgent, isOn: $settings.browserAgentOn)
            if license.isPro {
                GlassDivider()
                Text(AgentDisclosure.title).font(MW.mono).foregroundStyle(MW.textSecondary)
                ForEach(AgentDisclosure.rows, id: \.title) { row in
                    HStack(alignment: .top, spacing: MW.sp8) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(MW.textMuted)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(MW.mono).foregroundStyle(MW.textPrimary)
                            Text(row.body).font(MW.monoSm).foregroundStyle(MW.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                GlassDivider()
                toggleRow(AgentSetup.useYourOwnChrome, isOn: usesYourOwnChrome)
                if usesYourOwnChrome.wrappedValue {
                    Text(AgentSetup.oneTimeSetup).font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    setupStep(1) {
                        VStack(alignment: .leading, spacing: MW.sp6) {
                            Text(AgentSetup.openAddress).font(MW.mono).foregroundStyle(MW.textSecondary)
                            HStack(spacing: MW.sp8) {
                                Text(AgentSetup.address).font(MW.monoSm).foregroundStyle(MW.textPrimary)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button(AgentSetup.copyAddress) { AgentSetup.copyAddress(to: .general) }
                                    .font(MW.monoSm)
                            }
                        }
                    }
                    setupStep(2) {
                        Text(AgentSetup.tick).font(MW.mono).foregroundStyle(MW.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    setupStep(3) {
                        Text(AgentSetup.clickAllow).font(MW.mono).foregroundStyle(MW.textSecondary)
                    }
                } else {
                    Text(AgentDisclosure.ownWindow).font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(AgentSetup.needsPro).font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// "Use your own Chrome": the `agentBrowser` setting, on for the user's own Chrome — the next errand runs there.
    private var usesYourOwnChrome: Binding<Bool> {
        Binding(get: { AgentBrowser(setting: settings.agentBrowser) == .usersChrome },
                set: { settings.agentBrowser = ($0 ? AgentBrowser.usersChrome : .ownWindow).rawValue })
    }

    /// One of the second way's numbered steps, as board 4 draws them.
    private func setupStep<Content: View>(_ number: Int, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: MW.sp8) {
            Text("\(number)").font(MW.monoSm).foregroundStyle(MW.textPrimary)
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(MW.border, lineWidth: 1))
            content()
        }
    }

    // MARK: - Voice questions section (Phase 6)
    // MARK: - Voice questions section (Phase 6)

    private var voiceQuestionSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Speak voice question answers", isOn: $settings.ttsVoiceQuestions)
            toggleRow("Speak typed question answers", isOn: $settings.ttsTypedQuestions)

            if settings.ttsVoiceQuestions || settings.ttsTypedQuestions {
                GlassDivider()
                Text("Hold Right ⌘ to ask MetaChat aloud. Short tap still starts dictation as before.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                cloudVoiceSection
                voicePicker
                speedPicker
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private var cloudVoiceSection: some View {
        let isPro = LicenseService.shared.isPro
        return VStack(alignment: .leading, spacing: MW.sp4) {
            HStack {
                Text("Cloud voice (Pro)").mwBadge()
                Spacer()
                Toggle("", isOn: $settings.ttsCloudEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!isPro)
            }
            if !isPro {
                Text("Pro required — natural voices via OpenAI TTS. System voices below stay free.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted).italic()
            } else if settings.ttsCloudEnabled {
                Picker("", selection: $settings.ttsCloudVoice) {
                    ForEach(TTSService.cloudVoices, id: \.self) { v in
                        Text(v.capitalized).tag(v)
                    }
                }
                .labelsHidden()
                .font(MW.mono)
            }
        }
    }

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: MW.sp4) {
            Text(settings.ttsCloudEnabled && LicenseService.shared.isPro
                 ? "System voice (fallback)"
                 : "Voice")
                .mwBadge()
            Picker("", selection: $settings.ttsVoice) {
                Text("System default").tag("")
                ForEach(TTSService.availableVoices(), id: \.identifier) { v in
                    Text("\(v.name) · \(v.language)").tag(v.identifier)
                }
            }
            .labelsHidden()
            .font(MW.mono)
            HStack(spacing: MW.sp8) {
                Button("Preview") {
                    Task { @MainActor in
                        AppDelegate.shared?.ttsService.speak("This is how your assistant will sound.")
                    }
                }
                .font(MW.monoSm)
            }
        }
    }

    private var speedPicker: some View {
        VStack(alignment: .leading, spacing: MW.sp4) {
            HStack {
                Text("Speed").mwBadge()
                Spacer()
                Text(String(format: "%.1fx", settings.ttsSpeed)).font(MW.monoSm).foregroundStyle(MW.textSecondary)
            }
            Slider(value: $settings.ttsSpeed, in: 0.5...2.0, step: 0.1)
        }
    }

    // MARK: - File Indexing folder list

    private var fileIndexingFolderList: some View {
        VStack(alignment: .leading, spacing: MW.sp4) {
            Text("Scanned folders")
                .mwBadge()

            let folders = settings.indexedFolders
            if folders.isEmpty {
                Text("No folders yet. Click Add folder and pick your Obsidian vault or notes directory.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted).italic()
                    .padding(.vertical, MW.sp4)
            } else {
                VStack(spacing: 2) {
                    ForEach(folders, id: \.self) { path in
                        HStack(spacing: MW.sp8) {
                            Image(systemName: "folder")
                                .font(.system(size: 10)).foregroundStyle(MW.textMuted)
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(MW.monoSm).foregroundStyle(MW.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                settings.removeIndexedFolder(path)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 11)).foregroundStyle(MW.textMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    }
                }
            }

            HStack(spacing: MW.sp8) {
                Button(action: pickFolder) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 10))
                        Text("Add folder").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(MW.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                if !settings.indexedFolders.isEmpty,
                   let indexer = AppDelegate.shared?.fileIndexer,
                   let extractor = AppDelegate.shared?.fileMemoryExtractor {
                    FileIndexingScanButton(indexer: indexer, extractor: extractor)
                }
            }

            // Status line — shows "Scanning…" / "287 files · 8 memories · 2m ago" / errors.
            // Without this there's zero feedback on whether SCAN NOW finished successfully.
            if let indexer = AppDelegate.shared?.fileIndexer,
               let extractor = AppDelegate.shared?.fileMemoryExtractor {
                FileIndexingStatusLine(indexer: indexer, extractor: extractor)
                    .padding(.top, MW.sp4)
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.title = "Pick a folder to index"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        // NO NSApp.activate(ignoringOtherApps:) — its aggressive form throws the user
        // to the main window's bound Space (see MainWindowController). Use async .begin()
        // (not .runModal()) so we don't block the main thread; the panel keys itself
        // from the already-foreground window.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in settings.addIndexedFolder(url.path) }
        }
    }

    // MARK: - Screen Context App List

    /// Bundle IDs parsed from comma-separated settings.
    private var selectedBundleIDs: [String] {
        settings.screenContextAppList
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var screenContextAppList: some View {
        VStack(alignment: .leading, spacing: MW.sp4) {
            // Label changes based on mode
            Text(settings.screenContextMode == "whitelist" ? "Included apps" : "Excluded apps")
                .mwBadge()

            // Selected apps as rows
            if selectedBundleIDs.isEmpty {
                Text(settings.screenContextMode == "whitelist"
                     ? "Add apps to capture only their windows"
                     : "Add apps to skip (password managers, banks, etc.)")
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
                    .italic()
                    .padding(.vertical, MW.sp4)
            } else {
                VStack(spacing: 2) {
                    ForEach(selectedBundleIDs, id: \.self) { bundleID in
                        selectedAppRow(bundleID: bundleID)
                    }
                }
            }

            // Add button
            Button {
                showAppPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 9))
                    Text("Add app").font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(MW.textSecondary)
                .padding(.horizontal, MW.sp8).padding(.vertical, MW.sp4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showAppPicker) {
            AppPickerView(
                excludedBundleIDs: Set(selectedBundleIDs),
                onSelect: { app in
                    addApp(app)
                    showAppPicker = false
                },
                onClose: { showAppPicker = false }
            )
        }
    }

    private func selectedAppRow(bundleID: String) -> some View {
        let info = appCache[bundleID] ?? lookupAppInfo(bundleID: bundleID)
        return HStack(spacing: 8) {
            if let icon = info?.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app").font(.system(size: 14)).foregroundStyle(MW.textMuted)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(info?.name ?? bundleID).font(MW.monoSm).foregroundStyle(MW.textPrimary)
                if info != nil {
                    Text(bundleID).font(.system(size: 8, design: .monospaced)).foregroundStyle(MW.textMuted)
                }
            }
            Spacer()
            Button {
                removeApp(bundleID: bundleID)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9)).foregroundStyle(MW.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, MW.sp4).padding(.vertical, 3)
        .background(MW.elevated.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
    }

    private func lookupAppInfo(bundleID: String) -> AppInfo? {
        // Lazy lookup — only scans once when requested, caches in @State
        let info = InstalledApps.list().first { $0.bundleID == bundleID }
        if let info { appCache[bundleID] = info }
        return info
    }

    private func addApp(_ app: AppInfo) {
        appCache[app.bundleID] = app
        var ids = selectedBundleIDs
        guard !ids.contains(app.bundleID) else { return }
        ids.append(app.bundleID)
        settings.screenContextAppList = ids.joined(separator: ",")
    }

    private func removeApp(bundleID: String) {
        let ids = selectedBundleIDs.filter { $0 != bundleID }
        settings.screenContextAppList = ids.joined(separator: ",")
    }

    private func contextModeButton(_ label: String, value: String) -> some View {
        let isSelected = settings.screenContextMode == value
        return Text(label)
            .font(MW.monoSm)
            .foregroundStyle(isSelected ? MW.textPrimary : MW.textMuted)
            .padding(.horizontal, MW.sp8)
            .padding(.vertical, 2)
            .mwSelectable(isSelected, radius: 999, resting: .none)
            .onTapGesture { settings.screenContextMode = value }
    }

    // MARK: - The licence notices (§5)

    /// The link to the notices of the copied sources. The app has no About
    /// tab, so they sit at the bottom of the General one.
    private var noticesLink: some View {
        HStack {
            Button("Open-source notices") { openNotices() }
                .buttonStyle(.plain)
                .font(MW.monoSm)
                .foregroundStyle(MW.textSecondary)
            Spacer(minLength: 0)
        }
    }

    /// Opens the notices: the copy inside the app bundle, or the file in the
    /// repository when the app runs without one (`swift run`).
    private func openNotices() {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            NSWorkspace.shared.open(url)
            return
        }
        guard let url = URL(string: "https://github.com/metawhisp/metawhisp/blob/architecture-phase-1-3/THIRD_PARTY_NOTICES.md") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - WrappingHStack Helper

private struct WrappingHStack<Item, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let content: (Item) -> Content

    @State private var totalHeight: CGFloat = .zero

    var body: some View {
        GeometryReader { geo in
            generateContent(in: geo)
        }
        .frame(height: totalHeight)
    }

    private func generateContent(in geo: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero

        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                content(item)
                    .alignmentGuide(.leading) { d in
                        if abs(width - d.width) > geo.size.width {
                            width = 0
                            height -= d.height + spacing
                        }
                        let result = width
                        if index == items.count - 1 {
                            width = 0
                        } else {
                            width -= d.width + spacing
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = height
                        if index == items.count - 1 {
                            height = 0
                        }
                        return result
                    }
            }
        }
        .background(viewHeightReader($totalHeight))
    }

    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        GeometryReader { geo -> Color in
            DispatchQueue.main.async {
                binding.wrappedValue = geo.size.height
            }
            return Color.clear
        }
    }
}

// MARK: - File Indexing status / button (observers for reactive UI)

/// Scan now button that reflects running state. Disabled + "Scanning…" label
/// while either the file indexer or the memory extractor pass is in flight.
private struct FileIndexingScanButton: View {
    @ObservedObject var indexer: FileIndexerService
    @ObservedObject var extractor: FileMemoryExtractor

    private var isRunning: Bool { indexer.isScanning || extractor.isRunning }

    var body: some View {
        Button {
            guard !isRunning else { return }
            // `scanAll` internally runs `backfillContent` at the end — one call covers metadata
            // discovery AND content storage for chat RAG (ITER-004). Then LLM memory extraction.
            Task { @MainActor in
                await indexer.scanAll()
                await extractor.runPass()
            }
        } label: {
            HStack(spacing: 4) {
                if isRunning {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text("Scanning…").font(.system(size: 11.5, weight: .medium))
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    Text("Scan now").font(.system(size: 11.5, weight: .medium))
                }
            }
            .foregroundStyle(isRunning ? MW.textMuted : MW.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
    }
}

/// One-line status: "Scanning…" / "287 files · 8 memories · 2m ago" / "Error: …".
/// Pulls live state from `FileIndexerService.lastScanSummary` + `FileMemoryExtractor.lastSummary`.
/// Gives the user concrete confirmation that scan finished successfully (was invisible before).
private struct FileIndexingStatusLine: View {
    @ObservedObject var indexer: FileIndexerService
    @ObservedObject var extractor: FileMemoryExtractor

    var body: some View {
        HStack(spacing: 4) {
            statusIcon
            Text(statusText)
                .font(MW.monoSm)
                .foregroundStyle(statusColor)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var statusIcon: some View {
        Group {
            if indexer.isScanning || extractor.isRunning {
                Image(systemName: "clock")
            } else if extractor.lastError != nil {
                Image(systemName: "exclamationmark.triangle")
            } else if indexer.lastRun != nil {
                Image(systemName: "checkmark.circle")
            } else {
                Image(systemName: "circle.dotted")
            }
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(statusColor)
    }

    private var statusText: String {
        if indexer.isScanning { return "Scanning folders…" }
        if extractor.isRunning { return "Extracting memories from files…" }
        if let err = extractor.lastError { return "Extraction error: \(err)" }
        guard let run = indexer.lastRun else {
            return "Not scanned yet. Click Scan now to index."
        }
        // Parse "Added 287, updated 0 across 1 folder(s)" → "287 files"
        // Parse "Processed 15 files, added 8 memories" → "8 memories"
        let filesPart = indexer.lastScanSummary.flatMap(Self.fileCountLabel) ?? "files scanned"
        let memPart = extractor.lastSummary.flatMap(Self.memoryCountLabel) ?? ""
        let ago = Self.relativeAgo(from: run, to: Date())
        return memPart.isEmpty
            ? "\(filesPart) · \(ago)"
            : "\(filesPart) · \(memPart) · \(ago)"
    }

    private var statusColor: Color {
        if indexer.isScanning || extractor.isRunning { return MW.textSecondary }
        if extractor.lastError != nil { return .orange }
        if indexer.lastRun != nil { return MW.textSecondary }
        return MW.textMuted
    }

    /// "Added 287, updated 12 across 2 folder(s)" → "287 new, 12 updated".
    private static func fileCountLabel(_ s: String) -> String? {
        // Lightweight regex via ranges — avoid bringing NSRegularExpression for a 1-liner.
        func num(after marker: String) -> Int? {
            guard let r = s.range(of: marker) else { return nil }
            let rest = s[r.upperBound...]
            let digits = rest.prefix(while: { $0.isWhitespace || $0.isNumber })
                .trimmingCharacters(in: .whitespaces)
            return Int(digits)
        }
        let added = num(after: "Added") ?? 0
        let updated = num(after: "updated") ?? 0
        if added + updated == 0 { return "no new files" }
        if updated == 0 { return "\(added) files" }
        return "\(added) new · \(updated) updated"
    }

    /// "Processed 15 files, added 8 memories" → "8 memories".
    private static func memoryCountLabel(_ s: String) -> String? {
        guard let r = s.range(of: "added ") else { return nil }
        let rest = s[r.upperBound...]
        let digits = rest.prefix(while: { $0.isNumber })
        guard let n = Int(digits), n > 0 else { return nil }
        return "\(n) memories"
    }

    private static func relativeAgo(from: Date, to: Date) -> String {
        let secs = Int(to.timeIntervalSince(from))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        let h = secs / 3600
        return h < 24 ? "\(h)h ago" : "\(h / 24)d ago"
    }
}

/// The recorder for the help shortcut (Settings → Meetings, §3.8).
///
/// A local key monitor, alive only while a combo is being recorded and only
/// inside the Settings window: the recorder must never see the keys the user
/// types in the app they are working in. While it is on, the keyboard of the
/// Settings window belongs to the recorder — everything it sees there is
/// swallowed, so no stray Return presses a button behind it. The keys of
/// another window are not the recorder's: they go on to the app.
final class MeetingHelpShortcutRecorder: ObservableObject {
    /// True while the recorder is listening.
    @Published private(set) var isRecording = false
    /// Why the last combo was refused.
    @Published private(set) var refusal: String?
    /// The combo the recorder accepted.
    var onAccepted: ((MeetingHelpCombo) -> Void)?

    private var monitor: Any?
    private var window: NSWindow?

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Starts recording. Nothing happens until a key arrives.
    ///
    /// The window that records the combo is the Settings window — the app
    /// leaves it out and the focused window is taken.
    @MainActor
    func start(window: NSWindow? = nil) {
        stop()
        refusal = nil
        isRecording = true
        self.window = window ?? NSApp?.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.monitorHandler(event)
        }
    }

    /// Stops recording and takes the monitor down.
    @MainActor
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
        isRecording = false
    }

    /// The monitor's answer to a press: nil swallows the press, the event
    /// goes on to the app.
    @MainActor
    func monitorHandler(_ event: NSEvent) -> NSEvent? {
        handle(event) ? nil : event
    }

    /// One key. Esc cancels; the rest is measured against the rules.
    ///
    /// Answers whether the recorder owns the press: a press of another
    /// window is not the recorder's.
    @MainActor
    private func handle(_ event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mask = MeetingHelpModifiers.carbonMask(for: flags)
        // Only the Settings window's keys are ours.
        let isOwnWindow = !(window != nil && event.window != nil && event.window !== window)
        switch MeetingHelpRecorderRules.action(keyCode: keyCode,
                                               modifiers: mask,
                                               isOwnWindow: isOwnWindow) {
        case .pass:
            return false
        case .cancelled:
            stop()
            return true
        case .accepted(let combo):
            refusal = nil
            stop()
            onAccepted?(combo)
            return true
        case .refused(let reason):
            refusal = reason.message
            return true
        }
    }
}

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
    // ITER-054 — Deepgram key draft (commit on ⏎/Save, not per keystroke)
    @State private var deepgramKeyDraft = ""

    // Tab selection — single column scroll per tab beats the previous two-column wall
    // (1500-line settings was hard to scan).
    @State private var selectedTab: SettingsTab = .general

    /// ITER-056 — 5 tabs, one product vertical each (founder-approved mockup
    /// 2026-07-15): a key lives next to the feature it powers; Integrations
    /// holds external services only.
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case dictation = "Dictation"
        case meetings = "Meetings"
        case brain = "Second Brain"
        case integrations = "Integrations"
        var id: String { rawValue }
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
        }
        // Sane minimum — below this tab labels / section headers start to clip.
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MW.bg)
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { tab in
                    tabButton(tab)
                }
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
            .glassChip(selected: isSelected, radius: MW.rTiny)
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
                twoColumn(memoriesSection, adviceSection)
                proactiveSection
                dailySummarySection
                weeklyPatternsSection
                voiceQuestionSection
            }
        case .integrations:
            VStack(spacing: MW.sp12) {
                twoColumn(fileIndexingSection, appleNotesSection)
                calendarSection
                obsidianSyncSection
                mcpSection
            }
        }
    }

    /// Two-column row — pairs two small sections so neither stretches across the
    /// whole 640-pt content column. Equal widths, glass gap between.
    @ViewBuilder
    private func twoColumn<L: View, R: View>(_ left: L, _ right: R) -> some View {
        HStack(alignment: .top, spacing: MW.sp12) {
            left.frame(maxWidth: .infinity, alignment: .topLeading)
            right.frame(maxWidth: .infinity, alignment: .topLeading)
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

            if settings.transcriptionEngine == "ondevice" {
                Text("MODEL").font(MW.monoSm).foregroundStyle(MW.textMuted).padding(.top, MW.sp4)
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
                        Circle().fill(MW.idle).frame(width: 6, height: 6)
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
        .contentShape(Rectangle())
        .overlay(Rectangle().stroke(isActive ? MW.idle : MW.border, lineWidth: isActive ? 1.5 : MW.hairline))
        .onTapGesture { settings.transcriptionEngine = value }
    }

    private var cloudTranscriptionSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("PROVIDER").font(MW.monoSm).foregroundStyle(MW.textMuted).padding(.top, MW.sp4)

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
                        Circle().fill(MW.idle).frame(width: 6, height: 6)
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
        .contentShape(Rectangle())
        .overlay(Rectangle().stroke(isActive ? MW.idle : MW.border, lineWidth: isActive ? 1.5 : MW.hairline))
        .onTapGesture { settings.cloudTranscriptionProvider = prov.rawValue }
    }

    @ViewBuilder
    private var groqKeyField: some View {
        let key = settings.groqKey
        HStack(spacing: MW.sp8) {
            if key.isEmpty {
                TextField("", text: Binding(
                    get: { settings.groqKey },
                    set: { settings.groqKey = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                ), prompt: Text("Groq API Key").foregroundStyle(MW.textMuted))
                    .font(MW.mono)
                    .textFieldStyle(.plain)
                    .foregroundStyle(MW.textPrimary)
                    .padding(.horizontal, MW.sp8)
                    .padding(.vertical, MW.sp4)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            } else {
                HStack(spacing: MW.sp8) {
                    let masked = String(repeating: "\u{2022}", count: min(20, key.count - 4)) + String(key.suffix(4))
                    Text(masked)
                        .font(MW.mono)
                        .foregroundStyle(MW.textSecondary)
                    Spacer()
                    Circle().fill(MW.idle).frame(width: 6, height: 6)
                    Button { settings.groqKey = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MW.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, MW.sp8)
                .padding(.vertical, MW.sp4)
                .overlay(Rectangle().stroke(MW.borderLight, lineWidth: MW.hairline))
            }
        }
        Text("Get a free key at console.groq.com")
            .font(MW.monoSm).foregroundStyle(MW.textMuted)
    }

    /// ITER-054 — optional BYOK Deepgram for MEETING diarization. Works on any
    /// tier: with a key set, meetings transcribe in one diarized pass on the
    /// user's own Deepgram account (real speaker labels); dictations unaffected.
    @ViewBuilder
    private var deepgramKeyField: some View {
        let key = settings.deepgramKey
        GlassDivider()
        Text("Meeting diarization (optional)")
            .font(MW.mono).foregroundStyle(MW.textSecondary)
        HStack(spacing: MW.sp8) {
            if key.isEmpty {
                // Codex review — a live binding saved the FIRST keystroke,
                // key.isEmpty flipped, and the field collapsed to the masked
                // view with a 1-char «key». Type/paste into a DRAFT, commit on
                // ⏎ or Save.
                TextField("", text: $deepgramKeyDraft,
                          prompt: Text("Deepgram API Key").foregroundStyle(MW.textMuted))
                    .font(MW.mono)
                    .textFieldStyle(.plain)
                    .foregroundStyle(MW.textPrimary)
                    .padding(.horizontal, MW.sp8)
                    .padding(.vertical, MW.sp4)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    .onSubmit { commitDeepgramKeyDraft() }
                if !deepgramKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Save") { commitDeepgramKeyDraft() }
                        .buttonStyle(.plain)
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.idle)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                                    .stroke(MW.idle.opacity(0.4), lineWidth: 0.5))
                }
            } else {
                HStack(spacing: MW.sp8) {
                    let masked = String(repeating: "\u{2022}", count: min(20, max(0, key.count - 4))) + String(key.suffix(4))
                    Text(masked)
                        .font(MW.mono)
                        .foregroundStyle(MW.textSecondary)
                    Spacer()
                    Circle().fill(MW.idle).frame(width: 6, height: 6)
                    Button { settings.deepgramKey = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MW.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, MW.sp8)
                .padding(.vertical, MW.sp4)
                .overlay(Rectangle().stroke(MW.borderLight, lineWidth: MW.hairline))
            }
        }
        Text("With a key set, meetings are transcribed on YOUR Deepgram account with real speaker labels (who said what) in one pass. Voice dictations are unaffected. console.deepgram.com")
            .font(MW.monoSm).foregroundStyle(MW.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// ITER-054 — commit the Deepgram key draft into the keychain-backed setting.
    private func commitDeepgramKeyDraft() {
        let trimmed = deepgramKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.deepgramKey = trimmed
        deepgramKeyDraft = ""
    }

    private func modelRow(_ info: ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: MW.spaceXs) {
                Text(info.displayName.uppercased())
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
        .background(settings.selectedModel == info.id ? MW.elevated : .clear)
        .overlay(Rectangle().stroke(
            settings.selectedModel == info.id ? MW.borderLight : .clear,
            lineWidth: MW.hairline
        ))
    }

    @ViewBuilder
    private func modelAction(_ info: ModelInfo) -> some View {
        if modelManager.isDownloaded(info.id) {
            if settings.selectedModel == info.id {
                Text("ACTIVE")
                    .font(MW.monoSm)
                    .foregroundStyle(MW.idle)
            } else {
                BlocksButton(label: "USE") {
                    settings.selectedModel = info.id
                }
            }
        } else if modelManager.currentDownloadModel == info.id {
            downloadProgress
        } else {
            BlocksButton(label: "DOWNLOAD") {
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
                Text("VERIFYING").font(MW.monoSm).foregroundStyle(MW.textMuted)
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
                    availableInputs = AudioInputCatalog.availableInputDevices()
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
            availableInputs = AudioInputCatalog.availableInputDevices()
        }
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
                    .foregroundStyle(settings.transcriptionLanguage == lang.1 ? Color.black : MW.textSecondary)
                    .padding(.horizontal, MW.sp8)
                    .padding(.vertical, MW.sp4)
                    .background(settings.transcriptionLanguage == lang.1 ? MW.elevated : .clear)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
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
                    Text(mode.displayName.uppercased())
                        .font(MW.mono)
                        .foregroundStyle(settings.processingMode == mode.rawValue ? MW.textPrimary : MW.textSecondary)
                    Spacer()
                    if settings.processingMode == mode.rawValue {
                        Text("\u{25CF}").font(.system(size: 8)).foregroundStyle(MW.textPrimary)
                    } else {
                        Text("\u{25CB}").font(.system(size: 8)).foregroundStyle(MW.textMuted)
                    }
                }
                .padding(.vertical, MW.sp8)
                .padding(.horizontal, MW.sp8)
                .background(settings.processingMode == mode.rawValue ? MW.elevated : .clear)
                .overlay(Rectangle().stroke(
                    settings.processingMode == mode.rawValue ? MW.borderLight : .clear,
                    lineWidth: MW.hairline
                ))
                .contentShape(Rectangle())
                .onTapGesture { settings.processingMode = mode.rawValue }
            }

            let desc = (ProcessingMode(rawValue: settings.processingMode) ?? .raw).description
            Text(desc).font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    // MARK: - Translation

    private var translationSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("TRANSLATION").blocksLabel()

            WrappingHStack(items: translateLanguages, spacing: MW.sp4) { lang in
                Text(lang.0)
                    .font(MW.monoSm)
                    .foregroundStyle(settings.translateTo == lang.1 ? Color.black : MW.textSecondary)
                    .padding(.horizontal, MW.sp8)
                    .padding(.vertical, MW.sp4)
                    .background(settings.translateTo == lang.1 ? MW.elevated : .clear)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    .onTapGesture { settings.translateTo = lang.1 }
            }

            Text("Press Right \u{2325} to record + translate. Requires OpenAI API key.")
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
                    .foregroundStyle(Color(red: 0.78, green: 0.71, blue: 0.55))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(red: 0.78, green: 0.71, blue: 0.55).opacity(0.1))
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
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(MW.idle)
                        }
                        Text(license.plan == "annual" ? "Annual plan" : "Monthly plan")
                            .font(MW.monoSm).foregroundStyle(MW.textMuted)
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

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://metawhisp.com/account/")!)
                    } label: {
                        Text("UPGRADE TO PRO")
                            .font(MW.mono)
                            .foregroundStyle(.black)
                            .padding(.horizontal, MW.sp16)
                            .padding(.vertical, MW.sp4)
                            .background(MW.idle)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, MW.sp4)

                    Button("Sign out") { license.signOut() }
                        .font(MW.monoSm).foregroundStyle(MW.textMuted).buttonStyle(.plain)
                }
            } else {
                // Not signed in
                VStack(alignment: .leading, spacing: MW.sp4) {
                    Text("Sign in to activate Pro features.")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://metawhisp.com/account/")!)
                    } label: {
                        Text("SIGN IN")
                            .font(MW.mono)
                            .foregroundStyle(MW.textPrimary)
                            .padding(.horizontal, MW.sp16)
                            .padding(.vertical, MW.sp4)
                            .frame(maxWidth: .infinity)
                            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
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
                OnboardingWindowController().show()
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
                            .fill(u.balance / max(u.limit, 1) < 0.1 ? MW.processing : MW.idle)
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
        VStack(alignment: .leading, spacing: MW.sp12) {
            Text("HOTKEYS").blocksLabel()

            hotkeyRow(
                "TRANSCRIBE", desc: "Right ⌘ — short tap. Result auto-pasted to active app.",
                badge: "TAP", keys: ["RIGHT", "\u{2318}"]
            )
            hotkeyRow(
                "TRANSLATE", desc: "Right ⌥ — short tap. Translates to your preferred target language.",
                badge: "TAP", keys: ["RIGHT", "\u{2325}"]
            )
            hotkeyRow(
                "VOICE QUESTION", desc: "Hold Right ⌘ ≥ 0.5s — speak, release. Reply spoken aloud.",
                badge: "HOLD", keys: ["RIGHT", "\u{2318}"]
            )
            hotkeyRow(
                "AUTO-TRANSLATE (INPUT)", desc: "Hold Right ⌥ ≥ 1.5s — translates live mic input as you speak.",
                badge: "HOLD", keys: ["RIGHT", "\u{2325}"]
            )

            Rectangle().fill(MW.border).frame(height: MW.hairline)

            Text("MODE").blocksLabel()

            HStack(spacing: MW.sp4) {
                modeButton("TOGGLE", value: "toggle",
                           desc: "press to start/stop")
                modeButton("PUSH-TO-TALK", value: "pushToTalk",
                           desc: "hold to record")
            }

            Text("Tap the key from any app to start/stop recording.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    private func hotkeyRow(_ action: String, desc: String, badge: String, keys: [String]) -> some View {
        HStack(alignment: .center, spacing: MW.sp12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action).font(MW.mono).foregroundStyle(MW.textPrimary)
                Text(desc).font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                hotkeyBadge(badge)
                ForEach(keys, id: \.self) { key in
                    Keycap(text: key)
                }
            }
        }
    }

    /// Small uppercase badge — TAP / HOLD — distinguishes press-and-release
    /// from press-and-hold actions in the hotkey panel.
    private func hotkeyBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .default))
            .tracking(0.6)
            .foregroundStyle(text == "HOLD" ? MW.accent : MW.textMuted)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(text == "HOLD" ? MW.accent.opacity(0.45) : MW.border, lineWidth: 0.5)
            }
    }

    private func modeButton(_ label: String, value: String, desc: String) -> some View {
        let isSelected = settings.hotkeyMode == value
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
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                    .fill(.ultraThinMaterial)
                if isSelected {
                    RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                }
                RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.20 : 0.08), lineWidth: 0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.12)) { settings.hotkeyMode = value }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("OPTIONS").blocksLabel()

            // Theme
            HStack {
                Text("THEME").font(MW.mono).foregroundStyle(MW.textSecondary)
                Spacer()
                HStack(spacing: 0) {
                    themeButton("DARK", value: "dark")
                    themeButton("LIGHT", value: "light")
                    themeButton("AUTO", value: "auto")
                }
            }

            // Accent — 5 swatches per Liquid Glass design spec § 10 Step 1.
            // Live-updates `MW.accent` everywhere. Default `mono` keeps current
            // monochrome look; user opts into a colored preset here.
            // Each swatch wraps a fixed-width slot so circles + labels of
            // different lengths ("Mono" vs "Electric" vs "Warm Orange") stay
            // visually equidistant.
            HStack(alignment: .center) {
                Text("ACCENT").font(MW.mono).foregroundStyle(MW.textSecondary)
                Spacer()
                HStack(spacing: 0) {
                    ForEach(MW.accentPresets, id: \.id) { preset in
                        AccentSwatch(
                            presetID: preset.id,
                            label: preset.label,
                            isSelected: settings.accentColor == preset.id,
                            onTap: { settings.accentColor = preset.id }
                        )
                        .frame(width: 64)
                    }
                }
            }

            toggleRow("SOUND EFFECTS", isOn: $settings.soundEnabled)
            toggleRow("AUTO-PASTE", isOn: $settings.autoSubmit)

            // Launch-at-login. Source of truth = SMAppService.mainApp registration,
            // NOT @AppStorage — system can flip it from System Settings → Login
            // Items, and a local mirror would silently drift. We bind the toggle
            // through LaunchAtLoginManager.shared, which round-trips register/
            // unregister + re-reads status so UI stays consistent with the OS.
            toggleRow("LAUNCH AT LOGIN", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { _ = launchAtLogin.setEnabled($0) }
            ))
            Text(launchAtLogin.statusDescription)
                .font(MW.monoSm)
                .foregroundStyle(MW.textMuted)

            HStack {
                Text("WEEK STARTS").font(MW.mono).foregroundStyle(MW.textSecondary)
                Spacer()
                HStack(spacing: 0) {
                    weekDayButton("MON", value: 2)
                    weekDayButton("SUN", value: 1)
                }
            }

            if settings.soundEnabled {
                HStack {
                    Text("SOUND STYLE").font(MW.mono).foregroundStyle(MW.textSecondary)
                    Spacer()
                    HStack(spacing: 0) {
                        soundPresetButton("DEFAULT", value: "default")
                        soundPresetButton("BASS", value: "bass")
                        soundPresetButton("SIGNATURE", value: "signature")
                        soundPresetButton("CUSTOM", value: "custom")
                    }
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
            .background(isSelected ? MW.elevated : .clear)
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
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
            .background(isSelected ? MW.elevated : .clear)
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            .onTapGesture {
                settings.appTheme = value
                MW.applyTheme(value)
            }
    }

    private func soundPickerRow(_ label: String, role: String) -> some View {
        HStack {
            Text(label.uppercased()).font(MW.monoSm).foregroundStyle(MW.textSecondary)
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
                Text("DEFAULT").font(MW.monoSm).foregroundStyle(MW.textMuted)
            }
            Button {
                pickSoundFile(for: role)
            } label: {
                Text("CHOOSE").font(MW.label).tracking(0.8)
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
            let soundsDir = appSupport.appendingPathComponent("MetaWhisp/Sounds", isDirectory: true)
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
            .background(isSelected ? MW.elevated : .clear)
            .overlay(Rectangle().stroke(isSelected ? MW.textMuted : MW.border, lineWidth: MW.hairline))
            .onTapGesture { settings.weekStartsOn = value }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(MW.mono).foregroundStyle(MW.textSecondary)
            Spacer()
            Text(isOn.wrappedValue ? "ON" : "OFF")
                .font(MW.monoSm)
                .foregroundStyle(isOn.wrappedValue ? MW.textPrimary : MW.textMuted)
                .padding(.horizontal, MW.sp8)
                .padding(.vertical, 2)
                .background(isOn.wrappedValue ? MW.elevated : .clear)
                .overlay(Rectangle().stroke(isOn.wrappedValue ? MW.textMuted : MW.border, lineWidth: MW.hairline))
                .onTapGesture { isOn.wrappedValue.toggle() }
        }
    }

    // MARK: - Recording Overlay

    private let pillStyles: [(label: String, value: String, desc: String)] = [
        ("CAPSULE", "capsule", "Floating pill indicator"),
        ("ISLAND AURA", "dotglow", "Notch aura glow"),
        ("ISLAND EXPAND", "island", "Expanding notch"),
        ("EDGE GLOW", "glow", "Top edge light strip"),
        ("SHREK", "shrek", "Dancing avatar — tints red while transcribing"),
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
        .background(isSelected ? MW.elevated : .clear)
        .overlay(Rectangle().stroke(
            isSelected ? MW.borderLight : .clear,
            lineWidth: MW.hairline
        ))
        .contentShape(Rectangle())
        .onTapGesture { settings.pillStyle = style.value }
    }

    // MARK: - Cloud API

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: MW.sp8) {
            Text("CLOUD LLM").blocksLabel()

            if license.isPro {
                HStack(spacing: MW.sp4) {
                    Circle().fill(MW.idle).frame(width: 6, height: 6)
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

            // API key field for active provider
            apiKeyField

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
        .contentShape(Rectangle())
        .overlay(Rectangle().stroke(isActive ? MW.idle : MW.border, lineWidth: isActive ? 1.5 : MW.hairline))
        .onTapGesture { settings.llmProvider = prov.rawValue }
    }

    private var activeKeyBinding: Binding<String> {
        switch settings.llmProvider {
        case "cerebras":
            return Binding(
                get: { settings.cerebrasKey },
                set: { settings.cerebrasKey = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
        default:
            return Binding(
                get: { settings.openaiKey },
                set: { settings.openaiKey = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            )
        }
    }

    private var activeKey: String { settings.activeAPIKey }

    private var activeProviderName: String {
        (LLMProvider(rawValue: settings.llmProvider) ?? .openai).displayName
    }

    @ViewBuilder
    private var apiKeyField: some View {
        HStack(spacing: MW.sp8) {
            if activeKey.isEmpty {
                TextField("", text: activeKeyBinding,
                          prompt: Text("\(activeProviderName) API Key").foregroundStyle(MW.textMuted))
                    .font(MW.mono)
                    .textFieldStyle(.plain)
                    .foregroundStyle(MW.textPrimary)
                    .padding(.horizontal, MW.sp8)
                    .padding(.vertical, MW.sp4)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            } else {
                HStack(spacing: MW.sp8) {
                    let masked = String(repeating: "•", count: min(20, activeKey.count - 4)) + String(activeKey.suffix(4))
                    Text(masked)
                        .font(MW.mono)
                        .foregroundStyle(MW.textSecondary)
                    Spacer()
                    Button {
                        activeKeyBinding.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(MW.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, MW.sp8)
                .padding(.vertical, MW.sp4)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            }

            if !activeKey.isEmpty {
                Text("●").font(.system(size: 8)).foregroundStyle(MW.idle)
            }
        }
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
                Text("Records system audio from Zoom, Meet, Teams. Transcribed locally via WhisperKit.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                // ITER-054 — BYOK Deepgram diarization. Lives HERE (not in the
                // cloud-dictation section, hidden for on-device users — Codex
                // review): the key affects MEETINGS regardless of the dictation
                // engine, on any tier.
                deepgramKeyField
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

                // ITER-019 — Live advice during meeting (Pro only).
                GlassDivider()
                toggleRow("Live advice during meeting", isOn: $settings.liveMeetingAdviceEnabled)
                Text(settings.liveMeetingAdviceEnabled
                     ? "Every 30s during a recording: partial transcribe + advice trigger. Catches contradictions and surfaces relevant memories WHILE you're talking. Pro only · ~$0.05 per hour-long meeting."
                     : "Advice fires only after the meeting stops. Turn ON for realtime hints during the call.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// ITER-015 — Proactive chip that surfaces relevant memories/past decisions/waiting-on
    /// tasks while the user is composing a reply in Slack/Mail/etc. Opt-in. Requires
    /// Screen Context on (feeds on its ScreenContext pipeline) + Pro (needs embeddings).
    private var proactiveSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("Proactive Chip", isOn: $settings.proactiveEnabled)
            if settings.proactiveEnabled {
                Text("While you're typing in Slack, Mail, Notion, or similar apps, MetaWhisp silently surfaces 2-3 relevant memories, past decisions, and waiting-on tasks as a peripheral chip. Never a notification — no sound, no interrupt.")
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
                Text("Minimum gap between chip surfaces. Default 5 min.")
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
                    HStack(spacing: 0) {
                        contextModeButton("BLACKLIST", value: "blacklist")
                        contextModeButton("WHITELIST", value: "whitelist")
                    }
                }
                // App list with picker — implements spec://intelligence/FEAT-0002#app-picker
                screenContextAppList

                GlassDivider()
                toggleRow("Realtime task detection", isOn: $settings.realtimeScreenReactionEnabled)
                if settings.realtimeScreenReactionEnabled {
                    Text("LLM checks each new window for actionable tasks. Max 30 checks/hour. Per-app 60s cooldown. Pro only.")
                        .font(MW.monoSm).foregroundStyle(MW.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                    .font(MW.monoSm).foregroundStyle(MW.idle)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
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
            let ctx = ModelContext(container)
            let deleted = try ScreenRetention.deleteAll(in: ctx)
            // The destructive privacy action covers the in-session buffers
            // too — otherwise Advice keeps quoting "deleted" OCR for a while.
            AppDelegate.shared?.screenContext.clearInMemory()
            // External copies (Codex review): a batch delete bypasses the
            // MutationService hooks, so remove the Obsidian vault files for
            // the deleted artifacts and refresh the MCP snapshot explicitly.
            // Best-effort, like all post-commit hooks.
            let taskIds = deleted.taskIds
            let memoryIds = deleted.memoryIds
            Task { @MainActor in
                if let exporter = AppDelegate.shared?.obsidianExporter {
                    for id in taskIds { await exporter.deleteTaskFile(id) }
                    for id in memoryIds { await exporter.deleteMemoryFile(id) }
                }
                MCPSnapshotService.shared.snapshotNow()
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
                scanNowButton { await AppDelegate.shared?.appleNotesReader.scanNow() }
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

                // ITER-037 Option A (2026-05-12) — external LLM access docs.
                // After bulk export, the user can wire Claude Desktop / Cursor /
                // ChatGPT to read the vault as «second memory». No custom code —
                // just MCP filesystem server pointed at the vault path.
                Divider().padding(.vertical, 4)
                Text("EXTERNAL LLM ACCESS")
                    .font(MW.label).tracking(1.0)
                    .foregroundStyle(MW.textMuted)
                Text("Once vault is filled, point Claude Desktop / Cursor / ChatGPT at it. They'll read your voices, meetings, tasks and memories as «second memory».")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    integrationDocButton(label: "Setup Claude Desktop", file: "CLAUDE-DESKTOP-SETUP.md")
                    integrationDocButton(label: "Setup Cursor", file: "CURSOR-SETUP.md")
                    integrationDocButton(label: "Setup ChatGPT", file: "CHATGPT-SETUP.md")
                }
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
    }

    /// AUD-029 — MCP snapshot opt-in. Default OFF: no snapshot of memories/tasks/
    /// conversations is written unless the user enables it here; turning it off
    /// purges the on-disk file via applyEnabledState().
    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: MW.sp10) {
            toggleRow("MCP Server", isOn: $settings.mcpEnabled)
            if settings.mcpEnabled {
                Text("Writes a local snapshot of your memories, tasks and conversation summaries to ~/Library/Application Support/MetaWhisp/mcp-snapshot.json so the standalone metawhisp-mcp tool can answer Claude Desktop / Cursor calls. The file stays on this Mac, owner-only, and is deleted when you turn this off.")
                    .font(MW.monoSm).foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(MW.sp16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .mwCard(radius: MW.rMedium, elevation: .raised)
        .onChange(of: settings.mcpEnabled) { _, _ in
            MCPSnapshotService.shared.applyEnabledState()
        }
    }

    /// ITER-037 Option A — opens the relevant setup doc from `specs/integrations/`
    /// in the user's preferred Markdown viewer (Finder fallback). Bundled into
    /// the .app at `Contents/Resources/integrations/<file>` by build.sh; here
    /// we resolve via Bundle.main + NSWorkspace.open.
    private func integrationDocButton(label: String, file: String) -> some View {
        Button {
            // Prefer bundled doc; if not present (debug builds skip resource
            // copy), open the source spec via filesystem path.
            let bundledURL = Bundle.main.url(forResource: file.replacingOccurrences(of: ".md", with: ""), withExtension: "md", subdirectory: "integrations")
            let fallbackURL = URL(fileURLWithPath: "/Users/\(NSUserName())/Code/MetaWhisp/specs/integrations/\(file)")
            let url = bundledURL ?? (FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil)
            if let url {
                NSWorkspace.shared.open(url)
            } else {
                NSLog("[Settings] Integration doc not found: %@", file)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "book")
                    .font(.system(size: 10))
                Text(label).font(MW.label).tracking(0.6)
            }
            .foregroundStyle(MW.textSecondary)
            .glassChip(selected: false, radius: MW.rTiny)
        }
        .buttonStyle(.plain)
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
                        Text("ACTIVE")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(MW.idle)
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
        .background(
            RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                .fill(isActive ? MW.idle.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                .stroke(isActive ? MW.idle.opacity(0.4) : MW.border, lineWidth: 0.5)
        )
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
                    "LOCAL",
                    "\(spec.displayName) (\(chipBit) Neural Engine)",
                    MW.idle
                )
            }
            // MLX model. `isReady` reflects whether weights are loaded
            // into RAM; until that's true we're technically still on
            // cloud for this tick (Phase 4 will flip isReady to true).
            if LocalLLMService.shared.isReady {
                return (
                    "LOCAL",
                    "\(spec.displayName) on \(chipBit)",
                    MW.idle
                )
            } else {
                return (
                    "LOADING",
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
                "CLOUD",
                "\(providerLabel) via Pro proxy",
                MW.postProcess
            )
        }

        // Non-Pro: check user-supplied API key (BYOK path).
        if !settings.activeAPIKey.isEmpty {
            let providerLabel = settings.llmProvider == "cerebras"
                ? "Cerebras (your key)"
                : "OpenAI (your key)"
            return ("CLOUD", providerLabel, MW.postProcess)
        }

        // Nothing wired — AI features no-op for this user.
        return (
            "INACTIVE",
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
                    .foregroundStyle(MW.idle)
                Text("Recommended for your Mac")
                    .font(MW.monoSm).foregroundStyle(MW.idle)
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
            .foregroundStyle((isActive && isReady) ? .black : MW.textPrimary)
            .background((isActive && isReady) ? MW.idle :
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
                        settings.localLLMActiveModelID = ""
                        Task { @MainActor in LocalLLMService.shared.unloadModel() }
                    } else {
                        // Either «Load now» (ID already set, just reload) or
                        // «Make active» (set ID + load). Either way: load.
                        settings.localLLMActiveModelID = spec.id
                        Task { @MainActor in
                            try? await LocalLLMService.shared.loadModel(id: spec.id)
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(MW.label).tracking(0.6)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle((isActive && isReady) ? .black : MW.textPrimary)
                .background((isActive && isReady) ? MW.idle :
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
        if settings.localLLMActiveModelID == spec.id {
            settings.localLLMActiveModelID = ""
            Task { @MainActor in LocalLLMService.shared.unloadModel() }
        }
        do {
            try mlxManager.remove(spec)
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
                scanNowButton { await AppDelegate.shared?.calendarReader.scanNow() }
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
                     : "Default: pure insight only — no nudges. Turn ON for accountability push (when you slip a stated commitment, distract for too long, miss goal pace).")
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
                Text("CLOUD VOICE (PRO)").font(MW.monoSm).foregroundStyle(MW.textMuted)
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
                 ? "SYSTEM VOICE (FALLBACK)"
                 : "VOICE")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
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
                Text("SPEED").font(MW.monoSm).foregroundStyle(MW.textMuted)
                Spacer()
                Text(String(format: "%.1fx", settings.ttsSpeed)).font(MW.monoSm).foregroundStyle(MW.textSecondary)
            }
            Slider(value: $settings.ttsSpeed, in: 0.5...2.0, step: 0.1)
        }
    }

    // MARK: - File Indexing folder list

    private var fileIndexingFolderList: some View {
        VStack(alignment: .leading, spacing: MW.sp4) {
            Text("SCANNED FOLDERS")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)

            let folders = settings.indexedFolders
            if folders.isEmpty {
                Text("No folders yet. Click ADD FOLDER and pick your Obsidian vault or notes directory.")
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
                        Text("ADD FOLDER").font(MW.label).tracking(0.6)
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
            Text(settings.screenContextMode == "whitelist" ? "INCLUDED APPS" : "EXCLUDED APPS")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)

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
                    Text("ADD APP").font(MW.label).tracking(0.5)
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
            .background(isSelected ? MW.elevated : .clear)
            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
            .onTapGesture { settings.screenContextMode = value }
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

/// SCAN NOW button that reflects running state. Disabled + "SCANNING…" label
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
                    Text("SCANNING…").font(MW.label).tracking(0.6)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    Text("SCAN NOW").font(MW.label).tracking(0.6)
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
            return "Not scanned yet. Click SCAN NOW to index."
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

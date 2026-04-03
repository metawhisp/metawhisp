import SwiftUI

struct MainSettingsView: View {
    @ObservedObject var modelManager: ModelManagerService
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var license = LicenseService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                settingsHeader
                divider

                HStack(alignment: .top, spacing: 0) {
                    // Left column
                    VStack(spacing: 0) {
                        modelSection
                        divider
                        languageSection
                        divider
                        processingSection
                        divider
                        translationSection
                        divider
                        textStyleSection
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 340)

                    verticalDivider

                    // Right column
                    VStack(spacing: 0) {
                        accountSection
                        divider
                        hotkeySection
                        divider
                        optionsSection
                        divider
                        overlaySection
                        divider
                        cloudSection
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 320)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MW.bg)
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
            Text("SETTINGS").font(MW.monoLg).foregroundStyle(MW.textPrimary).tracking(2)
            Spacer()
            Text("CONFIGURATION").blocksLabel()
        }
        .padding(MW.sp16)
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
                    .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
                    .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
                    .onTapGesture { settings.transcriptionLanguage = lang.1 }
            }
        }
        .padding(MW.sp16)
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
                    .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
                    .onTapGesture { settings.translateTo = lang.1 }
            }

            Text("Press Right \u{2325} to record + translate. Requires OpenAI API key.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
        }
        .padding(MW.sp16)
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
                            .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
        }
        .padding(MW.sp16)
    }

    // MARK: - Hotkeys

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: MW.sp12) {
            Text("HOTKEYS").blocksLabel()

            hotkeyRow("TRANSCRIBE", keys: ["RIGHT", "\u{2318}"])
            hotkeyRow("TRANSLATE", keys: ["RIGHT", "\u{2325}"])

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
    }

    private func hotkeyRow(_ action: String, keys: [String]) -> some View {
        HStack {
            Text(action).font(MW.mono).foregroundStyle(MW.textSecondary)
            Spacer()
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Keycap(text: key)
                }
            }
        }
    }

    private func modeButton(_ label: String, value: String, desc: String) -> some View {
        VStack(spacing: MW.spaceXs) {
            Text(label)
                .font(MW.monoSm)
                .foregroundStyle(settings.hotkeyMode == value ? Color.black : MW.textSecondary)
            Text(desc)
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(settings.hotkeyMode == value ? Color.black.opacity(0.6) : MW.textMuted)
        }
        .padding(.horizontal, MW.sp12)
        .padding(.vertical, MW.sp8)
        .frame(maxWidth: .infinity)
        .background(settings.hotkeyMode == value ? MW.elevated : .clear)
        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
        .onTapGesture { settings.hotkeyMode = value }
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

            toggleRow("SOUND EFFECTS", isOn: $settings.soundEnabled)
            toggleRow("AUTO-PASTE", isOn: $settings.autoSubmit)

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
    }

    private func soundPresetButton(_ label: String, value: String) -> some View {
        let isSelected = settings.soundPreset == value
        return Text(label)
            .font(MW.monoSm)
            .foregroundStyle(isSelected ? MW.textPrimary : MW.textMuted)
            .padding(.horizontal, MW.sp8)
            .padding(.vertical, 2)
            .background(isSelected ? MW.elevated : .clear)
            .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
            .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
                    .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
            }
            .buttonStyle(.plain)
        }
    }

    private func pickSoundFile(for role: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a sound file for \(role)"
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
    }

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
            Text("LLM PROVIDER").blocksLabel()

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
                    .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
                .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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

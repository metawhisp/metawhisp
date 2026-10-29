import Foundation
import Security
import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("selectedModel") var selectedModel: String = "large-v3-turbo"
    /// ITER-058.3 — onboarding quick-started on Base; Large V3 Turbo should
    /// install in the background and hot-swap in. Cleared by the swap, an
    /// explicit user model pick, or a low-disk skip.
    @AppStorage("pendingBestModelUpgrade") var pendingBestModelUpgrade: Bool = false
    /// ITER-058.3 — failed swap attempts; at 3 the upgrade gives up for good
    /// (review: without a cap, a deterministic load failure looped
    /// download-950MB → fail → delete → re-download forever).
    @AppStorage("bestModelUpgradeAttempts") var bestModelUpgradeAttempts: Int = 0
    /// Whisper identifies the language itself, so onboarding no longer asks —
    /// see `OnboardingLanguageDefault`. Written only by the user's choice in
    /// Settings and by onboarding's completion; nothing at launch touches it.
    @AppStorage("transcriptionLanguage") var transcriptionLanguage: String = OnboardingLanguageDefault.freshInstallDefault

    /// Audio input device override. Empty string = follow macOS default
    /// (whichever input device the system has selected). Otherwise persists
    /// the device's stable UID — `AudioInputCatalog.device(forUID:)` resolves
    /// it back to a runtime device on each `AudioRecordingService.start()`.
    /// If the picked device was unplugged, falls back to system default.
    @AppStorage("preferredInputDeviceUID") var preferredInputDeviceUID: String = ""
    @AppStorage("hotkeyMode") var hotkeyMode: String = "toggle" // toggle, pushToTalk
    /// ITER-062 — requested ON by default; runtime activation still requires
    /// macOS Accessibility permission and an active event tap.
    @AppStorage("layoutFixEnabled_iter062") var layoutFixEnabled: Bool = true
    @AppStorage("layoutFixAutoEnabled_iter062") var layoutFixAutoEnabled: Bool = true
    @AppStorage("layoutFixDoubleShiftEnabled_iter062") var layoutFixDoubleShiftEnabled: Bool = true
    @AppStorage("layoutFixSwitchInputSource_iter062") var layoutFixSwitchInputSource: Bool = true
    /// ITER-075 step 0 (0.4) — the global hotkeys, ⌘⌥O and the layout fix. On in
    /// the owner's app, off by default in any other copy (the Dev app), so two
    /// copies never answer one key press. No UI:
    /// `defaults write <bundle id> globalInputEnabled -bool true` turns it on.
    @AppStorage("globalInputEnabled") var globalInputEnabled: Bool = AppIdentity.current.globalInputByDefault
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("autoSubmit") var autoSubmit: Bool = true
    @AppStorage("processingMode") var processingMode: String = "raw"
    @AppStorage("translateTo") var translateTo: String = "en"
    @AppStorage("pillStyle") var pillStyle: String = "capsule" // capsule, dotglow, island, glow
    @AppStorage("llmProvider") var llmProvider: String = "openai" // openai, cerebras
    @AppStorage("transcriptionEngine") var transcriptionEngine: String = "ondevice" // ondevice, cloud
    /// A1 — Pro was activated on this Mac, so its one automatic switch to cloud is spent (`ProCloudDefault`).
    @AppStorage(ProCloudDefault.key) var proCloudDefaultApplied: Bool = false
    @AppStorage("cloudTranscriptionProvider") var cloudTranscriptionProvider: String = "groq" // groq, openai
    /// LIC-1 — feature flag (default OFF). When ON, a cached Pro state expires after
    /// `LicenseEntitlement.defaultGraceTTL` (72h) without a fresh server verify, so a
    /// stale/planted Keychain key can't unlock Pro indefinitely offline. Ships dormant
    /// so legit offline Pro users aren't locked out at release; enable consciously.
    @AppStorage("enforceProEntitlementTTL") var enforceProEntitlementTTL: Bool = false
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false

    /// ITER-056 — GitHub star promo lifecycle stage (see `GitHubStarPromo`):
    /// 0 = never clicked (visible, no ✕) · 1 = starred (visible with ✕) ·
    /// 2 = dismissed forever.
    @AppStorage("githubStarStage") var githubStarStage: Int = 0

    /// One-time migration flag (ITER-026): on first launch after the unified
    /// notification work, dismiss every TaskItem still flagged
    /// `sourceApp == "Calendar"`. Those rows came from the old bulk pipeline
    /// in `CalendarReaderService.scanNow` — calendar event titles posing as
    /// action items. The pipeline is gone; this flag ensures the existing
    /// rows don't keep haunting the chat context.
    @AppStorage("didMigrateCalendarTasks_iter026") var didMigrateCalendarTasks: Bool = false

    /// One-time migration: lower stale `meetingSilenceStopMinutes` (default
    /// was 10 in 2026-04-30 build, now 3 in ITER-026 v2 — see field doc).
    /// Without this, users who launched the older build retain the 10 min
    /// stale default in their UserDefaults and back-to-back calls keep
    /// merging into one recording.
    @AppStorage("didMigrateSilenceStop_iter026") var didMigrateSilenceStop: Bool = false

    /// One-time auto-promotion (ITER-034.3, 2026-05-11): Pro subscribers
    /// whose `processingMode` is still on the global default `"raw"` get
    /// promoted to `"structured"` on the first launch after install of this
    /// build. Reason: user report «у меня никогда метависп не структурирует
    /// текст и не добавляет буллеты хотя должен» — Pro user expecting AI
    /// cleanup-with-bullets, but the default was raw and they never knew to
    /// flip it in Settings → Processing Mode. The flag-gating means we
    /// promote ONCE; if the user later moves themselves back to raw, the
    /// flag is already set and we don't overwrite. Mirrors the existing
    /// `transcriptionEngine` auto-switch to `cloud` for Pro.
    @AppStorage("didAutoPromoteProcessingMode_iter034") var didAutoPromoteProcessingMode: Bool = false

    /// ITER-039 — local LLM for Free tier. When `localLLMEnabled` is true AND
    /// `localLLMActiveModelID` resolves to a downloaded model (or
    /// «apple-foundation-models» on macOS 26+), the existing
    /// `hasLLMAccess`-gated services route through `LocalLLMService` instead
    /// of silently no-op'ing for Free users without a BYOK key.
    @AppStorage("localLLMEnabled_iter039") var localLLMEnabled: Bool = false
    /// Stable ModelSpec.id — one of «phi-4-mini» / «gemma-4-e2b» / «qwen3-4b»
    /// / «qwen3-7b» / «apple-foundation-models». Empty = no active model.
    /// Switched by the user via Settings → AI Models cards.
    @AppStorage("localLLMActiveModelID_iter039") var localLLMActiveModelID: String = ""
    @AppStorage("weekStartsOn") var weekStartsOn: Int = 2 // 1=Sunday, 2=Monday
    @AppStorage("appTheme") var appTheme: String = "dark" // dark, light, auto

    /// Liquid Glass design — accent color preset.
    /// Read by `MW.accent` (Helpers/DesignSystem.swift). Default `mono` keeps the
    /// existing monochrome look so adopting the new design system doesn't tint
    /// any existing UI element. User can switch to a colored preset in
    /// Settings → Appearance once that surface ships.
    /// Allowed values: "mono" | "warmOrange" | "electric" | "mint" | "violet".
    @AppStorage("accentColor") var accentColor: String = "mono"

    // Text style (Pro only)
    @AppStorage("textStyle_lowercaseStart") var textStyleLowercaseStart: Bool = false
    @AppStorage("textStyle_noPeriod") var textStyleNoPeriod: Bool = false
    @AppStorage("textStyle_noCapitalization") var textStyleNoCapitalization: Bool = false

    // Meeting recording
    @AppStorage("meetingRecordingEnabled") var meetingRecordingEnabled: Bool = false
    /// Show notification when a call (Zoom / Meet / Teams / …) is detected.
    /// Wired in AppDelegate via `ScreenContextService.onCallContext` hook (ITER-002).
    @AppStorage("autoDetectCalls") var autoDetectCalls: Bool = false
    /// When ON: auto-start recording 5s after call detection (requires `autoDetectCalls` ON).
    @AppStorage("callsAutoStartEnabled") var callsAutoStartEnabled: Bool = false
    /// Hard cap on meeting recording duration. After N minutes, force-stop with notification.
    /// Layered defense for the "7-hour zombie recording" bug (ITER-012). Default 4h.
    @AppStorage("meetingMaxDurationMinutes") var meetingMaxDurationMinutes: Double = 240
    /// Silence backstop. If `MeetingRecorder.audioLevel` stays below threshold for N minutes
    /// consecutively, auto-stop. With ITER-026 the silence guard is now the SOLE auto-stop
    /// signal (window-loss no longer stops recording), so this needs to be tight enough
    /// that back-to-back calls don't get merged into one zombie recording. User report
    /// 2026-05-02: "через 10 минут может начаться другой созвон уже и ты скажешь что этот
    /// тот же — нужно меньше". Lowered 10 → 3 min. Real calls rarely have ≥3 min of
    /// total silence (system-audio counts toward audioLevel — as long as ANYONE is
    /// speaking, including the other side over Meet/Zoom, we're not silent).
    @AppStorage("meetingSilenceStopMinutes") var meetingSilenceStopMinutes: Double = 3
    /// When ON: post a notification ~8s after meeting stops, summarising title + extracted
    /// tasks/memories. Click → opens Library tab.
    @AppStorage("meetingRecapNotifications") var meetingRecapNotifications: Bool = true
    /// In-app Recap popup that appears ~8s after a meeting stops (2026-04-29).
    /// Shows title/summary/action items/memories with Copy + Open in Library
    /// buttons. Independent of the macOS notification banner above — both can
    /// be on simultaneously.
    @AppStorage("meetingRecapPopupEnabled") var meetingRecapPopupEnabled: Bool = true

    /// ITER-019 — the switch of the in-call hints (relabelled in P5). The old
    /// live advice pipeline still runs behind it until P6 removes it.
    @AppStorage("liveMeetingAdviceEnabled") var liveMeetingAdviceEnabled: Bool = false

    /// ITER-076 P5 — the in-call hints v2. The automatic answers are off by
    /// default: every check costs money, and the user has to ask for them.
    @AppStorage("meetingAutoAnswer") var meetingAutoAnswer: Bool = false
    /// The help shortcut: the virtual key code (36 = Return) and the Carbon
    /// modifier mask (control = 0x1000). Together they are ⌃↩.
    @AppStorage("meetingHelpKeyCode") var meetingHelpKeyCode: Int = MeetingHelpDefaults.keyCode
    @AppStorage("meetingHelpModifiers") var meetingHelpModifiers: Int = MeetingHelpDefaults.modifiers

    // ITER-015 — Proactive surfacing. Opt-in. Silently surfaces a peripheral chip
    // with 2-3 relevant memories / past decisions / pending tasks while user is
    // composing a reply in another app. Not a notification — NSWindow-based chip.
    @AppStorage("proactiveEnabled") var proactiveEnabled: Bool = false

    /// ITER-067 — "be quiet for now", without turning the feature off and
    /// losing the Inbox with it. Suppressed comments are still recorded and
    /// still readable afterwards; they simply do not interrupt.
    @AppStorage("screenAgentPaused") var screenAgentPaused: Bool = false

    /// ITER-070 — how often the Screen Agent may interrupt, as one choice
    /// instead of several unrelated intervals scattered through Settings.
    @AppStorage("screenAgentPacing") var screenAgentPacing: String = ScreenAgentPacing.balanced.rawValue

    /// ITER-069 — permission to send ONE downscaled image of an allowed,
    /// focused window to the cloud vision model. Deliberately separate from
    /// every other consent: agreeing to cloud text is not agreeing to
    /// screenshots, and this stays off until the user says otherwise.
    @AppStorage("screenAgentVisualConsent") var screenAgentVisualConsent: Bool = false

    /// When the Inbox was last opened, as a Unix timestamp. The unread badge
    /// counts delivered comments queued after this mark, so looking clears it
    /// without rewriting a single journal row — the journal is history and
    /// stays what it was.
    @AppStorage("screenAgentInboxLastOpenedAt")
    var screenAgentInboxLastOpenedAt: Double = 0
    /// Minimum gap between chip surfaces. Lower = more useful but more intrusive.
    /// Default 5 min balances usefulness against annoyance.
    // 2026-08-08 — 5 → 10 min: reference-parity cadence (its analysis interval
    // is 600s). Half the interruptions; the valuable classes (creds on screen,
    // wrong date/recipient) are not time-critical at 5-min granularity.
    @AppStorage("proactiveCooldownMinutes") var proactiveCooldownMinutes: Double = 10
    /// Apps where proactive chip is DISABLED (comma-separated bundle-ids or display names).
    /// Sensitive apps like 1Password, Keychain, Terminal are banned by default.
    @AppStorage("proactiveBlacklist") var proactiveBlacklist: String = "1Password,Keychain Access,Terminal,iTerm,Activity Monitor,System Settings"

    // Screen context
    @AppStorage("screenContextEnabled") var screenContextEnabled: Bool = false
    @AppStorage("screenContextInterval") var screenContextInterval: Double = 30
    @AppStorage("screenContextMode") var screenContextMode: String = "blacklist" // blacklist, whitelist
    @AppStorage("screenContextAppList") var screenContextAppList: String = "" // comma-separated
    /// ITER-053.1 — retention for RAW OCR rows (ScreenContext), days. 0 = keep
    /// forever. Raw OCR is the privacy-hot artifact → short default.
    @AppStorage("screenRetentionDays") var screenRetentionDays: Int = 30
    /// ITER-053.1 — retention for distilled ScreenObservation rows (the Rewind
    /// timeline), days. 0 = keep forever. Distilled → longer default.
    @AppStorage("observationRetentionDays") var observationRetentionDays: Int = 180

    // AI Advice
    @AppStorage("adviceEnabled") var adviceEnabled: Bool = false
    @AppStorage("adviceInterval") var adviceInterval: Double = 900 // seconds (15 min)
    /// ITER-022 G4 — Coach mode. When ON, advice prompt switches to a more
    /// direct accountability tone (commitment tracking, pattern callouts).
    /// Still NOT generic wellness or therapy. Opt-in by design — default Off.
    @AppStorage("adviceCoachMode") var adviceCoachMode: Bool = false

    /// ITER-022 G5 — Weekly cross-conversation pattern digest. When ON, runs
    /// every Sunday (default 18:00) over the past 7 days of conversations +
    /// memories + tasks. Surfaces recurring themes / people / stuck loops /
    /// cross-context insights that aren't visible in any single meeting.
    @AppStorage("weeklyPatternsEnabled") var weeklyPatternsEnabled: Bool = false
    /// Hour of day (0-23) at which the weekly digest fires. Default Sunday 18:00.
    @AppStorage("weeklyPatternsHour") var weeklyPatternsHour: Int = 18

    // Memories — independent from advice (spec://iterations/ITER-001#architecture.settings)
    @AppStorage("memoriesEnabled") var memoriesEnabled: Bool = false
    @AppStorage("memoriesInterval") var memoriesInterval: Double = 600 // seconds (10 min)

    // Tasks
    @AppStorage("tasksEnabled") var tasksEnabled: Bool = true
    /// ITER-057.1 — notify when the promotion loop moves a staged candidate to
    /// active. Default OFF, exactly like the reference (extraction stays quiet;
    /// the user opts in to being pinged).
    @AppStorage("taskPromotionNotificationsEnabled") var taskPromotionNotificationsEnabled: Bool = false
    /// ITER-057.1 (Codex) — the ITER-007 «one-time» screen-task→staged
    /// migration had NO flag and re-ran EVERY launch, demoting even tasks the
    /// user promoted themselves (and it would fight the promotion loop). Now
    /// genuinely one-shot.
    @AppStorage("didMigrateScreenTasksToStaged_iter007") var didMigrateScreenTasksToStaged: Bool = false
    /// ITER-057.5 — one-time cleanup: dismiss the junk tasks system permission
    /// dialogs (SecurityAgent / UserNotificationCenter / loginwindow) produced
    /// before the task whitelist existed.
    @AppStorage("didDismissSystemDialogTasks_iter057_5") var didDismissSystemDialogTasks: Bool = false

    // Screen extraction — hourly batch analysis of ScreenContext → ScreenObservation (spec://BACKLOG#Phase2.R1)
    @AppStorage("screenExtractionEnabled") var screenExtractionEnabled: Bool = true
    @AppStorage("screenExtractionInterval") var screenExtractionInterval: Double = 3600  // seconds (1 hour)

    // Realtime screen reaction — per-window LLM check for actionable tasks (spec://iterations/ITER-006).
    // ITER-057.5 — ON by default (reference parity: extraction is on; this is the
    // commitment detector, the flagship's core). Cost is bounded by the task
    // whitelist + 60s per-app cooldown + 30 calls/hour cap + mini gate; users who
    // explicitly turned it off keep their stored false.
    @AppStorage("realtimeScreenReactionEnabled") var realtimeScreenReactionEnabled: Bool = true

    // File Indexing — scan user-picked folders + extract memories from text files (spec://BACKLOG#Phase3.E1)
    @AppStorage("fileIndexingEnabled") var fileIndexingEnabled: Bool = false
    /// Comma-separated absolute folder paths (e.g. "/Users/alice/Obsidian,/Users/alice/Documents/notes").
    @AppStorage("indexedFoldersCSV") var indexedFoldersCSV: String = ""
    @AppStorage("fileIndexingInterval") var fileIndexingInterval: Double = 21600  // seconds (6 hours)

    // Apple Notes reader — scan Notes.app via AppleScript, extract memories (spec://BACKLOG#Phase3.E2)
    @AppStorage("appleNotesEnabled") var appleNotesEnabled: Bool = false
    @AppStorage("appleNotesInterval") var appleNotesInterval: Double = 43200  // seconds (12 hours)

    // Calendar reader — EventKit → tasks for upcoming events + memories for recurring patterns (spec://BACKLOG#Phase3.E3)
    @AppStorage("calendarReaderEnabled") var calendarReaderEnabled: Bool = false
    @AppStorage("calendarReaderInterval") var calendarReaderInterval: Double = 21600  // seconds (6 hours)

    // Voice questions via long-press Right ⌘ + TTS answers (spec://BACKLOG#Phase6)
    @AppStorage("ttsVoiceQuestions") var ttsVoiceQuestions: Bool = true
    @AppStorage("ttsTypedQuestions") var ttsTypedQuestions: Bool = false
    /// Long-press hold threshold for voice-question trigger (ms).
    @AppStorage("voiceQuestionHoldMs") var voiceQuestionHoldMs: Double = 500
    /// AVSpeechSynthesisVoice identifier — defaults to system's preferred voice.
    @AppStorage("ttsVoice") var ttsVoice: String = ""
    /// Speech rate multiplier (AVSpeechUtteranceDefaultSpeechRate = 0.5, range 0.5-2.0x).
    @AppStorage("ttsSpeed") var ttsSpeed: Double = 1.0
    /// Pro-only: route TTS through cloud (OpenAI via /api/pro/tts) for natural voices.
    /// Falls back to local AVSpeech if disabled, non-Pro, or cloud fails.
    @AppStorage("ttsCloudEnabled") var ttsCloudEnabled: Bool = false
    /// Cloud voice id (alloy / echo / fable / onyx / nova / shimmer). Default "nova" (warm female).
    @AppStorage("ttsCloudVoice") var ttsCloudVoice: String = "nova"

    // Obsidian outbound sync (spec://BACKLOG, 2026-04-28). When enabled, the app
    // appends each new UserMemory to a single Markdown journal file inside the
    // user's Obsidian vault. Lets memories spread out of MetaWhisp into the rest
    // of the user's knowledge graph (other Obsidian plugins, mobile, etc).
    @AppStorage("obsidianSyncEnabled") var obsidianSyncEnabled: Bool = false
    /// Absolute path to the Obsidian vault folder (must be writable).
    @AppStorage("obsidianVaultPath") var obsidianVaultPath: String = ""
    /// Periodic sync interval. Default 12h — picks up any memory created since
    /// last run that wasn't already appended (we track a "last synced" mark).
    /// Twice-a-day is enough since memories accumulate slowly.
    @AppStorage("obsidianSyncInterval") var obsidianSyncInterval: Double = 43200
    /// ISO-8601 timestamp of the last successful sync (oldest memory NOT yet
    /// appended must have createdAt > this). Empty on first run.
    @AppStorage("obsidianLastSyncedAt") var obsidianLastSyncedAt: String = ""

    /// AUD-029 — opt-in for the MCP snapshot writer (default OFF). When OFF,
    /// MetaWhisp writes NO snapshot of memories/tasks/conversations to disk and
    /// purges any existing file; when ON it exposes a local-only snapshot for
    /// the standalone `metawhisp-mcp` tool. Honoured by MCPSnapshotService.
    @AppStorage("mcpEnabled") var mcpEnabled: Bool = false

    /// ITER-032 — show one-conversation projects in the Projects view.
    /// Default off so the grid stays clean (LLM hallucinations + typo
    /// duplicates are usually one-offs). Toggle in ProjectsView header
    /// flips it on for "show me everything I've ever generated".
    @AppStorage("projectShowSingletons") var projectShowSingletons: Bool = false

    /// ITER-032.2 — one-shot migration flag. The curative pass
    /// (reclassify suspect conversations → recanonicalize aliases by
    /// conversation count → prune orphans) runs ONCE per upgrade. Future
    /// launches no-op. Bump the suffix when shipping a new sweep.
    @AppStorage("didCurativePass_iter032_2") var didCurativePass_iter032_2: Bool = false

    // Daily Summary (spec://iterations/ITER-009-daily-summary)
    @AppStorage("dailySummaryEnabled") var dailySummaryEnabled: Bool = true
    /// Hour (0-23) in local time when the recap fires. Default 22 = 10 PM.
    @AppStorage("dailySummaryHour") var dailySummaryHour: Int = 22
    /// Minute (0-59) at the scheduled hour. Default 0.
    @AppStorage("dailySummaryMinute") var dailySummaryMinute: Int = 0

    /// ITER-076 stage 4b — which browser the agent uses: `AgentBrowser`'s raw
    /// value — its own Chrome window by default, or the user's own Chrome.
    /// Settings → Agent's "Use your own Chrome" writes it (stage 8b); the
    /// errand service reads it as each errand begins.
    @AppStorage("agentBrowser") var agentBrowser: String = AgentBrowser.ownWindow.rawValue
    /// ITER-076 stage 8b — Settings → Agent's "Browser agent": on until the
    /// user turns it off (owner decision 8.1). Off stops every errand and
    /// starts none.
    @AppStorage("browserAgentOn") var browserAgentOn: Bool = true
    /// ITER-076 stage 8b — the user's Allow on the disclosure before the
    /// first errand (8.2): written only by Allow, kept through off and on and
    /// a cleared MetaChat. Until it, no errand asks for a browser.
    @AppStorage("browserAgentAllowed") var browserAgentAllowed: Bool = false

    /// Parsed list of scanned folder paths.
    var indexedFolders: [String] {
        indexedFoldersCSV
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func addIndexedFolder(_ path: String) {
        var list = indexedFolders
        guard !list.contains(path) else { return }
        list.append(path)
        indexedFoldersCSV = list.joined(separator: ",")
    }

    func removeIndexedFolder(_ path: String) {
        let list = indexedFolders.filter { $0 != path }
        indexedFoldersCSV = list.joined(separator: ",")
    }

    // Sound preset: "default" (system sounds), "bass", "signature", or "custom"
    @AppStorage("soundPreset") var soundPreset: String = "default"

    // Custom sounds (file paths, used when soundPreset == "custom")
    @AppStorage("customSound_start") var customSoundStart: String = ""
    @AppStorage("customSound_stop") var customSoundStop: String = ""
    @AppStorage("customSound_translateStart") var customSoundTranslateStart: String = ""
    @AppStorage("customSound_translateDone") var customSoundTranslateDone: String = ""

    func customSound(for role: String) -> String? {
        // Preset sounds
        if soundPreset == "bass" {
            switch role {
            case "start": return Self.bundledSound("bass_start")
            case "stop": return Self.bundledSound("bass_stop")
            case "translateStart": return Self.bundledSound("bass_start")
            case "translateDone": return Self.bundledSound("bass_stop")
            default: return nil
            }
        }
        if soundPreset == "signature" {
            switch role {
            case "start": return Self.bundledSound("PML_DTV1_SIGNATURE_SOUND_007")
            case "stop": return Self.bundledSound("PML_DTV1_SIGNATURE_SOUND_051")
            case "translateStart": return Self.bundledSound("PML_DTV1_SIGNATURE_SOUND_007")
            case "translateDone": return Self.bundledSound("PML_DTV1_SIGNATURE_SOUND_051")
            default: return nil
            }
        }
        // Custom file paths
        if soundPreset == "custom" {
            let path: String
            switch role {
            case "start": path = customSoundStart
            case "stop": path = customSoundStop
            case "translateStart": path = customSoundTranslateStart
            case "translateDone": path = customSoundTranslateDone
            default: return nil
            }
            return path.isEmpty ? nil : path
        }
        // Default — nil means system sounds
        return nil
    }

    /// Find bundled sound file in app's Resources directory
    private static func bundledSound(_ name: String) -> String? {
        // SPM copies Resources/Sounds/ into MetaWhisp_MetaWhisp.bundle
        if let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") {
            return url.path
        }
        // Fallback: look in the executable's resource bundle
        let execDir = Bundle.main.bundlePath
        let candidates = [
            "\(execDir)/Contents/Resources/MetaWhisp_MetaWhisp.bundle/Sounds/\(name).wav",
            "\(execDir)/Contents/Resources/Sounds/\(name).wav",
            "\(execDir)/../Resources/MetaWhisp_MetaWhisp.bundle/Sounds/\(name).wav",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    func setCustomSound(for role: String, path: String?) {
        switch role {
        case "start": customSoundStart = path ?? ""
        case "stop": customSoundStop = path ?? ""
        case "translateStart": customSoundTranslateStart = path ?? ""
        case "translateDone": customSoundTranslateDone = path ?? ""
        default: break
        }
    }

    // MARK: - API Keys (stored in Keychain)

    @Published var openaiKey: String {
        didSet { KeychainHelper.save(key: "com.metawhisp.openaiKey", value: openaiKey) }
    }

    @Published var cerebrasKey: String {
        didSet { KeychainHelper.save(key: "com.metawhisp.cerebrasKey", value: cerebrasKey) }
    }

    @Published var groqKey: String {
        didSet { KeychainHelper.save(key: "com.metawhisp.groqKey", value: groqKey) }
    }

    /// ITER-054 — BYOK Deepgram (optional, any tier). When set, MEETINGS are
    /// transcribed via the user's own Deepgram account in one diarized pass
    /// (real speaker labels, 1× cost, никакого нашего воркера). Dictations
    /// are unaffected.
    /// BYOK Gemini, for meetings only. Native speaker labels on the user's own
    /// account — the same bargain the Deepgram key offers, with a different
    /// provider and a thirty-minute-per-request diarization cap the transcriber
    /// slices around.
    @Published var geminiKey: String {
        didSet { KeychainHelper.save(key: "com.metawhisp.geminiKey", value: geminiKey) }
    }

    @Published var deepgramKey: String {
        didSet { KeychainHelper.save(key: "com.metawhisp.deepgramKey", value: deepgramKey) }
    }

    private init() {
        self.openaiKey = KeychainHelper.load(key: "com.metawhisp.openaiKey") ?? ""
        self.cerebrasKey = KeychainHelper.load(key: "com.metawhisp.cerebrasKey") ?? ""
        self.groqKey = KeychainHelper.load(key: "com.metawhisp.groqKey") ?? ""
        self.deepgramKey = KeychainHelper.load(key: "com.metawhisp.deepgramKey") ?? ""
        self.geminiKey = KeychainHelper.load(key: "com.metawhisp.geminiKey") ?? ""
    }

    /// Onboarding's last step. The language the user runs on is written down
    /// first, so no install ever reads as "finished onboarding, no language".
    static func recordOnboardingCompleted(in defaults: UserDefaults = .standard) {
        let language = defaults.string(forKey: "transcriptionLanguage") ?? OnboardingLanguageDefault.freshInstallDefault
        defaults.set(language, forKey: "transcriptionLanguage")
        defaults.set(true, forKey: "hasCompletedOnboarding")
    }

    /// The active API key for the selected provider.
    var activeAPIKey: String {
        switch llmProvider {
        case "cerebras": return cerebrasKey
        default: return openaiKey
        }
    }

    var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = AppIdentity.current.supportDirectory(applicationSupport: appSupport)
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Keychain Helper

/// AUD-024 — stores secrets (license key, session token, BYOK API keys) in the
/// macOS Keychain via the Security framework.
///
/// Previously this wrote a PLAINTEXT JSON file at
/// `~/Library/Application Support/MetaWhisp/.secrets` (readable by any process
/// running as the same user) — the old doc comment claimed "encrypted plist",
/// which was false. On first read we migrate every value from that legacy file
/// into the Keychain, verify each one, and delete the file only when ALL are
/// confirmed. SEC-1: there is NO plaintext read fallback — the legacy file is
/// only ever read by the migration; if a value fails to verify in the Keychain
/// the file is kept and migration retries on the next read/launch (worst case
/// the user re-enters one key — never a silent plaintext read path).
///
/// Note: Keychain ACLs are bound to the code signature, so builds must keep a
/// stable signing identity (release Developer ID + `hot-swap.sh` provide this).
enum KeychainHelper {
    private static var service: String { AppIdentity.current.keychainService }

    /// ITER-053.1 (2026-07-16) — unit tests must NEVER touch the real
    /// keychain. A keychain item whose ACL doesn't trust the xctest binary
    /// makes `SecItemCopyMatching` block on a hidden permission prompt and the
    /// whole suite hangs forever (hit when a CLI-created item joined the
    /// service). Tests see an empty keychain (deterministic) and can't pollute
    /// the user's real one either.
    private static let isUnitTest = NSClassFromString("XCTestCase") != nil

    /// The keychain the helper talks to. Under XCTest it is an empty one that
    /// keeps nothing, so no test can reach the user's secrets; a test that
    /// needs a keychain sets `backend` to a fake and puts this one back.
    static let defaultBackend: KeychainBackend = isUnitTest ? EmptyKeychain() : SystemKeychain()
    static var backend: KeychainBackend = defaultBackend

    /// What the keychain holds for `key`. "Not there" and "there but
    /// unreadable" are different answers (ITER-075 step 0, US-0.4).
    static func read(_ key: String) -> KeychainRead {
        // SEC-1: migrate-on-first-read (idempotent, no-op once the legacy file
        // is gone) guarantees the Keychain is populated before ANY read — even
        // ones that fire before applicationDidFinishLaunching (AppSettings.init
        // reads keys). The permanent plaintext read fallback is REMOVED: the
        // legacy `.secrets` file is now only ever read by the migration itself,
        // so a planted file can no longer feed values into the app.
        if !isUnitTest { migrateLegacySecretsIfNeeded() }
        return lookup(key)
    }

    /// The stored value, or nil when there is none or it cannot be read. A
    /// caller for which "cannot read" must not look like "not there" uses
    /// `read` instead.
    static func load(key: String) -> String? {
        if case .value(let text) = read(key) { return text }
        return nil
    }

    /// Stores `value`; an empty value removes the item. Returns the keychain
    /// status, which is also logged when it is a failure.
    @discardableResult
    static func save(key: String, value: String) -> OSStatus {
        value.isEmpty ? delete(key) : write(key, value)
    }

    /// Removes the item. An item that is already gone counts as removed.
    @discardableResult
    static func delete(_ key: String) -> OSStatus {
        let status = backend.delete(service: service, account: key)
        if status == errSecItemNotFound { return errSecSuccess }
        if status != errSecSuccess { NSLog("[Keychain] ❌ delete %@ failed — status %d", key, status) }
        return status
    }

    // MARK: - Keychain primitives

    /// Update in place, or add when the item is missing — never delete first,
    /// so a write that fails leaves the old value where it was. Deleting first
    /// is how a keychain that refused access lost the Pro session on
    /// 2026-09-25: the delete went through, the add did not, and its status
    /// was thrown away.
    private static func write(_ key: String, _ value: String) -> OSStatus {
        guard let data = value.data(using: .utf8) else { return errSecParam }
        var status = backend.update(service: service, account: key, data: data)
        if status == errSecItemNotFound {
            status = backend.add(service: service, account: key, data: data)
        }
        if status != errSecSuccess { NSLog("[Keychain] ❌ write %@ failed — status %d", key, status) }
        return status
    }

    /// A read without the legacy migration — the migration itself uses it.
    private static func lookup(_ key: String) -> KeychainRead {
        let (status, data) = backend.copy(service: service, account: key)
        switch status {
        case errSecSuccess:
            guard let data, let text = String(data: data, encoding: .utf8) else {
                NSLog("[Keychain] ❌ read %@ — the item is not text", key)
                return .failed(errSecDecode)
            }
            return .value(text)
        case errSecItemNotFound:
            return .notFound
        default:
            NSLog("[Keychain] ❌ read %@ failed — status %d", key, status)
            return .failed(status)
        }
    }

    // MARK: - Legacy plaintext file (.secrets) — migration source ONLY (SEC-1)

    private static var legacyURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return AppIdentity.current.supportDirectory(applicationSupport: appSupport)
            .appendingPathComponent(".secrets")
    }

    private static func legacyDict() -> [String: String]? {
        guard let data = try? Data(contentsOf: legacyURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    // MARK: - One-time migration

    private static var migrated = false
    private static let migrationLock = NSLock()

    /// Imports the legacy plaintext `.secrets` file into the Keychain (called on
    /// the first `load`, signed app → Keychain ACLs valid), verifies each value,
    /// and deletes the file only when every secret is confirmed.
    ///
    /// SEC-1: the `migrated` flag is set ONLY on full success (or when there's
    /// nothing to migrate). On a partial failure it stays false, so EVERY later
    /// `load()` this launch RETRIES — a key that failed to write isn't missing
    /// for the rest of the run (there is no plaintext fallback anymore). Locked
    /// so concurrent launch-time reads don't race on the file delete.
    static func migrateLegacySecretsIfNeeded() {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !migrated else { return }
        guard let dict = legacyDict(), !dict.isEmpty else { migrated = true; return }
        var allConfirmed = true
        for (k, v) in dict {
            // Write AND verify (read back) before trusting the Keychain copy.
            if !(write(k, v) == errSecSuccess && lookup(k) == .value(v)) {
                allConfirmed = false
            }
        }
        // Delete the plaintext file ONLY when every secret is confirmed; mark
        // migrated only then, so a partial failure is retried on the next read.
        if allConfirmed {
            try? FileManager.default.removeItem(at: legacyURL)
            migrated = true
            NSLog("[Keychain] ✅ migrated %d secrets to Keychain; legacy .secrets removed", dict.count)
        } else {
            NSLog("[Keychain] ⚠️ secret migration incomplete — will retry on next read")
        }
    }
}

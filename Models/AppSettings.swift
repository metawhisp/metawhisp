import Foundation
import Security
import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("selectedModel") var selectedModel: String = "large-v3-turbo"
    @AppStorage("transcriptionLanguage") var transcriptionLanguage: String = "ru"
    @AppStorage("hotkeyMode") var hotkeyMode: String = "toggle" // toggle, pushToTalk
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("autoSubmit") var autoSubmit: Bool = true
    @AppStorage("processingMode") var processingMode: String = "raw"
    @AppStorage("translateTo") var translateTo: String = "en"
    @AppStorage("pillStyle") var pillStyle: String = "capsule" // capsule, dotglow, island, glow
    @AppStorage("llmProvider") var llmProvider: String = "openai" // openai, cerebras
    @AppStorage("transcriptionEngine") var transcriptionEngine: String = "ondevice" // ondevice, cloud
    @AppStorage("cloudTranscriptionProvider") var cloudTranscriptionProvider: String = "groq" // groq, openai
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("weekStartsOn") var weekStartsOn: Int = 2 // 1=Sunday, 2=Monday
    @AppStorage("appTheme") var appTheme: String = "dark" // dark, light, auto

    // Text style (Pro only)
    @AppStorage("textStyle_lowercaseStart") var textStyleLowercaseStart: Bool = false
    @AppStorage("textStyle_noPeriod") var textStyleNoPeriod: Bool = false
    @AppStorage("textStyle_noCapitalization") var textStyleNoCapitalization: Bool = false

    // Meeting recording
    @AppStorage("meetingRecordingEnabled") var meetingRecordingEnabled: Bool = false
    @AppStorage("autoDetectCalls") var autoDetectCalls: Bool = false

    // Screen context
    @AppStorage("screenContextEnabled") var screenContextEnabled: Bool = false
    @AppStorage("screenContextInterval") var screenContextInterval: Double = 30
    @AppStorage("screenContextMode") var screenContextMode: String = "blacklist" // blacklist, whitelist
    @AppStorage("screenContextAppList") var screenContextAppList: String = "" // comma-separated

    // AI Advice
    @AppStorage("adviceEnabled") var adviceEnabled: Bool = false
    @AppStorage("adviceInterval") var adviceInterval: Double = 900 // seconds (15 min)

    // Memories — independent from advice (spec://iterations/ITER-001#architecture.settings)
    @AppStorage("memoriesEnabled") var memoriesEnabled: Bool = false
    @AppStorage("memoriesInterval") var memoriesInterval: Double = 600 // seconds (10 min)

    // Tasks — Omi-style action item extraction from voice transcripts (spec://BACKLOG#B1)
    @AppStorage("tasksEnabled") var tasksEnabled: Bool = true

    // Screen extraction — hourly batch analysis of ScreenContext → ScreenObservation (spec://BACKLOG#Phase2.R1)
    @AppStorage("screenExtractionEnabled") var screenExtractionEnabled: Bool = true
    @AppStorage("screenExtractionInterval") var screenExtractionInterval: Double = 3600  // seconds (1 hour)

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

    private init() {
        self.openaiKey = KeychainHelper.load(key: "com.metawhisp.openaiKey") ?? ""
        self.cerebrasKey = KeychainHelper.load(key: "com.metawhisp.cerebrasKey") ?? ""
        self.groqKey = KeychainHelper.load(key: "com.metawhisp.groqKey") ?? ""
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
        let dir = appSupport.appendingPathComponent("MetaWhisp/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Keychain Helper

/// Stores secrets in an encrypted plist in Application Support.
/// Avoids Keychain password prompts caused by code signature changes during development.
enum KeychainHelper {
    private static var storage: [String: String] = {
        load() ?? [:]
    }()

    private static var storeURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MetaWhisp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".secrets")
    }

    static func save(key: String, value: String) {
        if value.isEmpty {
            storage.removeValue(forKey: key)
        } else {
            storage[key] = value
        }
        persist()
    }

    static func load(key: String) -> String? {
        storage[key]
    }

    private static func persist() {
        if let data = try? JSONEncoder().encode(storage) {
            try? data.write(to: storeURL, options: [.atomic, .completeFileProtection])
            // Set file permissions to owner-only (600)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        }
    }

    private static func load() -> [String: String]? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}

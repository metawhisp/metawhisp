import XCTest
@testable import MetaWhisp

/// Cloud chosen but out of reach — no Pro, no key of the user's own: the on-device engine transcribes in its place
/// (A4), and Settings says so in one quiet line under the engine picker, with no new control. The coordinator owns
/// which engine runs; the line follows it in every state.
@MainActor
final class SettingsEngineNoteTests: XCTestCase {
    private var saved: (engine: String, provider: String, groq: String, openai: String) = ("", "", "", "")

    override func setUp() {
        let settings = AppSettings.shared
        saved = (settings.transcriptionEngine, settings.cloudTranscriptionProvider, settings.groqKey, settings.openaiKey)
        settings.cloudTranscriptionProvider = "groq"
        settings.groqKey = ""
        settings.openaiKey = ""
    }

    override func tearDown() {
        let settings = AppSettings.shared
        settings.transcriptionEngine = saved.engine
        settings.cloudTranscriptionProvider = saved.provider
        settings.groqKey = saved.groq
        settings.openaiKey = saved.openai
    }

    private func coordinator(pro: Bool) -> TranscriptionCoordinator {
        TranscriptionCoordinator(recorder: FakeMicrophone(), whisperEngine: nil, textInserter: TextInsertionService(),
                                 soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                 voiceQuestions: VoiceQuestionState(), cloudEngine: HeldEngine(answersAtOnce: true),
                                 openMicrophoneSettings: {}, proxyAvailable: { pro })
    }

    private func note(pro: Bool) -> String? {
        MainSettingsView.engineNote(onDeviceStandsInForCloud: coordinator(pro: pro).onDeviceStandsInForCloud)
    }

    func testCloudChosenWithoutProOrAKeySaysOnDeviceIsUsed() {
        AppSettings.shared.transcriptionEngine = "cloud"
        XCTAssertEqual(note(pro: false), "On-device is used until Pro or your own key is set.")
    }

    /// The paired cases: cloud in use — Pro, or the user's own key — and the on-device choice have no line.
    func testCloudInUseOrOnDeviceChosenHasNoLine() {
        AppSettings.shared.transcriptionEngine = "cloud"
        XCTAssertNil(note(pro: true), "Pro")
        AppSettings.shared.groqKey = "gsk_test"
        XCTAssertNil(note(pro: false), "the user's own key")
        AppSettings.shared.groqKey = ""
        AppSettings.shared.transcriptionEngine = "ondevice"
        XCTAssertNil(note(pro: false), "on-device chosen")
        XCTAssertNil(note(pro: true), "on-device chosen, with Pro")
    }

    /// A key for the other provider is no key for the chosen one: the line stays.
    func testAKeyForTheOtherProviderKeepsTheLine() {
        AppSettings.shared.transcriptionEngine = "cloud"
        AppSettings.shared.openaiKey = "sk-test"
        XCTAssertNotNil(note(pro: false))
    }

    /// The line sits under the engine picker and adds no control.
    func testTheLineSitsUnderThePickerAndAddsNoControl() throws {
        let code = try OnboardingWindowTests.codeLines(of: "Views/Windows/MainSettingsView.swift")
        let picker = try XCTUnwrap(code.firstIndex { $0.contains("engineButton(\"Cloud\"") })
        let line = try XCTUnwrap(code.firstIndex { $0.contains("Self.engineNote(onDeviceStandsInForCloud:") })
        XCTAssertLessThan(picker, line)
        XCTAssertLessThan(line - picker, 6, "right under it")
        XCTAssertFalse(code[line...(line + 3)].contains { $0.contains("Button") || $0.contains("Toggle") })
    }
}

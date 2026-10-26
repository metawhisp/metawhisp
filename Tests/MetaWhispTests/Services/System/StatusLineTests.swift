import XCTest
@testable import MetaWhisp

/// C5, step-1 review #11 — the popover's one red line is recomputed from every
/// standing condition, in a fixed order: the microphone first, then the
/// engine. It used to be whatever was written last: launch put the microphone
/// line up, "No model loaded" overwrote it, and the model loading cleared the
/// line though the microphone was still off. A line about an event — a
/// dictation's error — stays until the next recording.
@MainActor
final class StatusLineTests: XCTestCase {
    private var savedEngine = ""
    private var savedModel = ""
    private var savedGroq = ""
    private var temp: URL!

    override func setUpWithError() throws {
        savedEngine = AppSettings.shared.transcriptionEngine
        savedModel = AppSettings.shared.selectedModel
        savedGroq = AppSettings.shared.groqKey
        AppSettings.shared.transcriptionEngine = "ondevice"
        AppSettings.shared.selectedModel = ModelBootstrap.quickModelId
        AppSettings.shared.groqKey = ""
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mw-status-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        AppSettings.shared.transcriptionEngine = savedEngine
        AppSettings.shared.selectedModel = savedModel
        AppSettings.shared.groqKey = savedGroq
        try? FileManager.default.removeItem(at: temp)
    }

    private enum Microphone { case granted, neverAsked, denied }

    /// A coordinator fed by a model preparer over an empty model folder, as
    /// the app wires them.
    private func wired(_ access: Microphone) -> (TranscriptionCoordinator, FakeMicrophone, ModelManagerService) {
        let microphone = FakeMicrophone()
        microphone.hasPermission = access == .granted
        microphone.permissionUndetermined = access == .neverAsked
        // The engine's weights are in; what a load changes is the model recorded for it.
        let flow = TranscriptionCoordinator(recorder: microphone, whisperEngine: LoadableEngine(loaded: true),
                                            textInserter: TextInsertionService(),
                                            soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                            voiceQuestions: VoiceQuestionState(), cloudEngine: HeldEngine(answersAtOnce: true),
                                            openMicrophoneSettings: {}, proxyAvailable: { false })
        let models = ModelManagerService(folder: ModelFolder(kind: .applicationSupport, home: temp, supportDirectory: temp))
        let preparer = ModelPreparer(modelManager: models, coordinator: flow, settings: .shared,
                                     freeBytes: { 50_000_000_000 })
        preparer.feedStatusLine()
        retained.append(preparer)
        return (flow, microphone, models)
    }

    private var retained: [ModelPreparer] = []

    private func spin() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// The quick model loads as the onboarding's download lands.
    private func loadTheQuickModel(_ flow: TranscriptionCoordinator) {
        flow.loadedWhisperModelId = ModelBootstrap.quickModelId
    }

    func testAModelReadyWhileTheMicrophoneIsMissingKeepsTheMicrophoneLine() {
        let (flow, microphone, _) = wired(.neverAsked)
        flow.prepareMicrophoneAtLaunch(warmUp: {})
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.microphoneNotAllowedYet, "the microphone comes first")

        loadTheQuickModel(flow)
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.microphoneNotAllowedYet, "still off: the line stays")

        microphone.hasPermission = true
        microphone.permissionUndetermined = false
        flow.refreshStatusLine()          // the answer, or the app's next activation
        XCTAssertNil(flow.lastError)
    }

    func testWithTheMicrophoneAllowedTheLineFollowsTheModel() {
        let (flow, _, models) = wired(.granted)
        flow.prepareMicrophoneAtLaunch(warmUp: {})
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.noModelLoaded, "nothing on disk")

        models.downloadProgress = 0.4     // the quick start begins — its progress while it runs (A4)
        models.isDownloading = true
        spin()
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.preparingModel(0.4), "recomputed on the download's change, unasked")

        models.isDownloading = false
        loadTheQuickModel(flow)
        XCTAssertNil(flow.lastError, "whoever loads the model")
    }

    func testADeniedMicrophoneOutranksAMissingModel() {
        let (flow, _, _) = wired(.denied)
        flow.prepareMicrophoneAtLaunch(warmUp: {})
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.microphoneDeniedAtLaunch)
    }

    /// A4 — cloud chosen without Pro or a key of the user's own: the on-device engine stands in, so the line is the
    /// on-device model's — never "API key not set" — until a key puts cloud back in use.
    func testTheCloudEngineWithoutAKeyShowsTheModelsLineUntilOneIsSet() {
        AppSettings.shared.transcriptionEngine = "cloud"
        let (flow, _, _) = wired(.granted)
        flow.refreshStatusLine()
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.noModelLoaded, "nothing on disk")
        AppSettings.shared.groqKey = "gsk_test"
        spin()
        XCTAssertNil(flow.lastError, "the key's change recomputes it")
    }

    /// The download's line moves with the download, and goes once a model loads.
    func testTheProgressLineFollowsTheDownload() {
        let (flow, _, models) = wired(.granted)
        models.downloadProgress = 0.4
        models.isDownloading = true
        spin()
        XCTAssertEqual(flow.lastError, "Preparing the model… 40%")
        models.downloadProgress = 0.6
        spin()
        XCTAssertEqual(flow.lastError, "Preparing the model… 60%", "a standing line, recomputed")
        models.isDownloading = false
        loadTheQuickModel(flow)
        XCTAssertNil(flow.lastError)
    }

    func testAnEventLineStaysUntilTheNextRecording() {
        let (flow, _, _) = wired(.granted)
        flow.lastError = "Copied to clipboard — press ⌘V to paste"
        loadTheQuickModel(flow)
        flow.refreshStatusLine()
        XCTAssertEqual(flow.lastError, "Copied to clipboard — press ⌘V to paste")
    }

    func testTheModelLineStaysWhileNothingIsLoaded() {
        let (flow, _, _) = wired(.granted)
        flow.refreshStatusLine()
        flow.loadedWhisperModelId = nil   // an unload on the on-device engine
        XCTAssertEqual(flow.lastError, TranscriptionCoordinator.noModelLoaded)
    }
}

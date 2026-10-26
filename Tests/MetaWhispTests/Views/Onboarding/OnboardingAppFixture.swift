import AppKit
import XCTest
@testable import MetaWhisp

/// The onboarding's pieces as `AppDelegate.showOnboarding` puts them together, over what a test may touch: a model
/// folder of its own (the download is the test runner's offline one, so nothing is fetched), a coordinator whose
/// engines and dictation microphone are fakes, the engine readiness owner, the capture arbiter, and a practice
/// microphone that is never started. A window it shows does not bring the test runner forward. The app's own
/// settings it touches, and the onboarding's resume point, are put back.
@MainActor
final class OnboardingAppFixture {
    /// What the onboarding, the preparer and the Dashboard read or write in the app's own defaults.
    static let keys = ["hasCompletedOnboarding", "selectedModel", "transcriptionEngine", "pendingBestModelUpgrade",
                       "bestModelUpgradeAttempts", "transcriptionLanguage", "cloudTranscriptionProvider",
                       OnboardingFlow.resumeKey]

    /// The free space the preparer reads.
    final class FreeSpace { var bytes: Int64 = 50_000_000_000 }

    let space = FreeSpace()
    let folder: ModelFolder
    let manager: ModelManagerService
    let coordinator: TranscriptionCoordinator
    let preparer: ModelPreparer
    let arbiter = CaptureArbiter(busyElsewhere: { false })
    private let temp: URL
    private let saved: [(key: String, value: Any?)]
    private var controllers: [OnboardingWindowController] = []

    /// `pro`: the Pro proxy is there, so a cloud choice is the engine in use (A4).
    init(pro: Bool = false) {
        saved = Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        UserDefaults.standard.removeObject(forKey: OnboardingFlow.resumeKey)
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-onboarding-app-\(UUID().uuidString)", isDirectory: true)
        folder = ModelFolder(kind: .applicationSupport, home: temp, supportDirectory: temp)
        manager = ModelManagerService(folder: folder)
        coordinator = TranscriptionCoordinator(recorder: FakeMicrophone(), whisperEngine: nil,
                                               textInserter: TextInsertionService(),
                                               soundService: SoundService(enabled: { false }),
                                               settings: AppSettings.shared, voiceQuestions: VoiceQuestionState(),
                                               cloudEngine: HeldEngine(answersAtOnce: true), openMicrophoneSettings: {},
                                               proxyAvailable: { pro })
        let space = space
        preparer = ModelPreparer(modelManager: manager, coordinator: coordinator, settings: .shared,
                                 freeBytes: { space.bytes })
    }

    /// Puts these models' folders on disk — whole or in part, a folder is all the listing sees — and lists them.
    func putOnDisk(_ models: [String]) throws {
        for id in models {
            let variant = try XCTUnwrap(ModelManagerService.models.first { $0.id == id }?.variant)
            try FileManager.default.createDirectory(
                at: folder.speechModels.appendingPathComponent(variant, isDirectory: true),
                withIntermediateDirectories: true)
        }
        manager.refreshDownloaded()
    }

    /// The on-device engine holds this model, as the auto-load after a download leaves it.
    func load(_ model: String) {
        coordinator.whisperEngine = LoadableEngine(loaded: true)
        coordinator.loadedWhisperModelId = model
    }

    /// The window controller, set up as the app sets it up.
    func controller(openMainWindow: @escaping () -> Void = {}) -> OnboardingWindowController {
        let controller = OnboardingWindowController()
        controller.dependencies = .init(coordinator: coordinator, modelPreparer: preparer, captureArbiter: arbiter,
                                        microphone: AudioRecordingService(path: .inputOnly),
                                        openMainWindow: openMainWindow)
        controllers.append(controller)
        return controller
    }

    func settle() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func tearDown() {
        controllers.forEach { $0.window?.close() }
        settle()
        manager.cancelDownload()
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: temp)
    }
}

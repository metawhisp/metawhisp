import XCTest
@testable import MetaWhisp

/// C5 / F1 — a new install keeps its models in its own Application Support
/// folder, so its first download brings no Documents prompt; an install that
/// may have models in ~/Documents/huggingface keeps that folder. Decided once
/// and stored, in the defaults and in a marker in the copy's support folder.
/// On a defaults suite and temp folders of the test's own.
final class ModelFolderTests: XCTestCase {
    private let suite = "mw-model-folder-tests"
    private var defaults: UserDefaults!
    private var temp: URL!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mw-folder-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: temp)
    }

    private func folder(_ kind: ModelFolder.Kind) -> ModelFolder {
        ModelFolder(kind: kind, home: temp.appendingPathComponent("home"),
                    supportDirectory: temp.appendingPathComponent("Application Support/MetaWhisp"))
    }

    /// This copy's support folder and store, in the test's own Application Support.
    private var earlierFiles: [URL] {
        ModelFolder.earlierLaunchFiles(identity: AppIdentity(bundleIdentifier: "com.metawhisp.app"),
                                       applicationSupport: temp.appendingPathComponent("Application Support"))
    }

    /// The marker in the test copy's own support folder, where the app keeps it.
    private var marker: URL { ModelFolder.marker(in: earlierFiles[0]) }

    private var marked: String? { try? String(contentsOf: marker, encoding: .utf8) }

    private func choose() -> ModelFolder.Kind {
        ModelFolder.chooseOnce(in: defaults, marker: marker, ownModels: folder(.applicationSupport).base,
                               earlierLaunchFiles: earlierFiles)
    }

    // MARK: - The choice

    func testANewInstallKeepsItsModelsInItsOwnFolderAndKeepsThatChoice() throws {
        XCTAssertEqual(choose(), .applicationSupport)
        XCTAssertEqual(defaults.string(forKey: ModelFolder.choiceKey), "applicationSupport")
        // This install's own use writes the keys and files an older install would have.
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set("base", forKey: "selectedModel")
        try FileManager.default.createDirectory(at: earlierFiles[0], withIntermediateDirectories: true)
        XCTAssertEqual(choose(), .applicationSupport, "kept on every later launch")
    }

    func testAnInstallFromBefore14KeepsTheDocumentsFolder() {
        for key in ModelFolder.earlierLaunchKeys {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: earlierFiles[0])   // each key on an install of its own
            defaults.set(true, forKey: key)
            XCTAssertEqual(choose(), .documents, key)
            defaults.removeObject(forKey: key)
            XCTAssertEqual(choose(), .documents, "\(key): kept once chosen")
        }
    }

    /// Written on every launch since May 2026, so an install that never
    /// finished onboarding or picked a model still counts as one with history.
    func testAnyEarlierLaunchSinceMayCounts() {
        defaults.set(true, forKey: "didAutoPromoteProcessingMode_iter034")
        XCTAssertEqual(choose(), .documents)
    }

    /// Step-1 review #2: defaults reset, models still in ~/Documents — the
    /// support folder or the store an earlier launch made still says so.
    func testAnInstallWithEmptyDefaultsKeepsDocumentsByItsSupportFolderOrItsStore() throws {
        let support = earlierFiles[0], store = earlierFiles[1]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        XCTAssertEqual(choose(), .documents, "the support folder")

        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: support)
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: store)
        XCTAssertEqual(choose(), .documents, "the store")
    }

    /// Round-2 N1: a new install downloads into its own folder, then its
    /// defaults are reset. Its support folder now exists — its own first
    /// launch made it — and must not be read as an earlier install's.
    func testANewInstallThatDownloadedKeepsItsFolderAfterADefaultsReset() throws {
        XCTAssertEqual(choose(), .applicationSupport)
        XCTAssertEqual(marked, "applicationSupport", "kept outside the defaults as it is made")
        let own = folder(.applicationSupport)
        XCTAssertEqual(own.base.deletingLastPathComponent().path, earlierFiles[0].path, "the downloads land in the support folder")
        try FileManager.default.createDirectory(at: own.speechModels.appendingPathComponent("openai_whisper-base", isDirectory: true),
                                                withIntermediateDirectories: true)
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(choose(), .applicationSupport, "its models are where it left them")
        XCTAssertEqual(defaults.string(forKey: ModelFolder.choiceKey), "applicationSupport", "the defaults have it again")
    }

    /// …and when its marker is corrupt too: its own model folder, which no
    /// build before 1.4 wrote, says where its models are.
    func testANewInstallThatDownloadedKeepsItsFolderWithACorruptMarkerAfterADefaultsReset() throws {
        XCTAssertEqual(choose(), .applicationSupport)
        let own = folder(.applicationSupport)
        try FileManager.default.createDirectory(at: own.speechModels.appendingPathComponent("openai_whisper-base", isDirectory: true),
                                                withIntermediateDirectories: true)
        defaults.removePersistentDomain(forName: suite)
        try Data([0x61, 0xFF, 0xFE, 0x00]).write(to: marker)
        XCTAssertEqual(choose(), .applicationSupport, "its models are where it left them")
        XCTAssertEqual(marked, "applicationSupport", "put right")
    }

    /// Round-3 N1-P2: chosen, the own folder is created at once, so a new install that loses both its defaults and
    /// its marker before any download still shows its own folder — never the support folder read as an earlier
    /// install's, never Documents.
    func testANewInstallThatLosesItsDefaultsAndMarkerBeforeADownloadKeepsItsFolder() throws {
        XCTAssertEqual(choose(), .applicationSupport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder(.applicationSupport).base.path), "created at once")
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: marker)
        XCTAssertEqual(choose(), .applicationSupport)
    }

    /// Where no marker is kept — under XCTest, the app's own default — nothing is made: no test writes into a copy's
    /// support folder.
    func testWithoutAMarkerTheFolderIsNotMade() {
        let own = folder(.applicationSupport).base
        XCTAssertEqual(ModelFolder.chooseOnce(in: defaults, marker: nil, ownModels: own, earlierLaunchFiles: earlierFiles),
                       .applicationSupport)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
    }

    /// …and only for that choice: an install that keeps Documents gets no folder of its own.
    func testAnInstallThatKeepsDocumentsGetsNoOwnFolder() throws {
        try FileManager.default.createDirectory(at: earlierFiles[0], withIntermediateDirectories: true)
        XCTAssertEqual(choose(), .documents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(.applicationSupport).base.path))
    }

    /// A legacy install whose defaults were reset and which never had a
    /// marker keeps Documents by its traces — and is marked from then on.
    func testALegacyInstallWithEmptyDefaultsAndNoMarkerKeepsDocumentsAndIsMarked() throws {
        try FileManager.default.createDirectory(at: earlierFiles[0], withIntermediateDirectories: true)
        XCTAssertNil(marked)
        XCTAssertEqual(choose(), .documents)
        XCTAssertEqual(marked, "documents")
        XCTAssertEqual(defaults.string(forKey: ModelFolder.choiceKey), "documents")
    }

    /// A choice only the defaults hold — made before there was a marker, or
    /// when writing it failed — is marked on the next launch.
    func testAChoiceOnlyTheDefaultsHoldIsMarked() throws {
        defaults.set("applicationSupport", forKey: ModelFolder.choiceKey)
        try FileManager.default.createDirectory(at: earlierFiles[0], withIntermediateDirectories: true)
        XCTAssertEqual(choose(), .applicationSupport)
        XCTAssertEqual(marked, "applicationSupport")
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(choose(), .applicationSupport)
    }

    /// A marker that cannot be read, or holds anything else, is no answer:
    /// on a legacy install (no own model folder) the traces decide, nothing
    /// crashes, and the marker is put right when it can be.
    func testAnUnreadableOrCorruptMarkerFallsThroughToTheTraces() throws {
        try FileManager.default.createDirectory(at: earlierFiles[0], withIntermediateDirectories: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(.applicationSupport).base.path), "a legacy install")
        for corrupt in [Data("applicationSupport, probably".utf8), Data([0x61, 0xFF, 0xFE, 0x00])] {
            defaults.removePersistentDomain(forName: suite)
            try corrupt.write(to: marker)
            XCTAssertEqual(choose(), .documents, "corrupt: the support folder is a trace")
            XCTAssertEqual(marked, "documents", "put right")
        }

        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)   // unreadable as a file
        XCTAssertEqual(choose(), .documents, "unreadable: the traces decide")
        XCTAssertEqual(defaults.string(forKey: ModelFolder.choiceKey), "documents", "the defaults still keep it")
    }

    /// No test writes into a copy's real support folder: under XCTest the
    /// app's own marker is none, and the app's marker sits in its folder.
    func testTestsNeverWriteTheAppsMarker() {
        XCTAssertNil(ModelFolder.defaultMarker)
        XCTAssertEqual(ModelFolder.marker(in: earlierFiles[0]).deletingLastPathComponent().path, earlierFiles[0].path)
    }

    /// The evidence is this copy's own Application Support; ~/Documents is
    /// never looked at, and choosing creates nothing but the marker and,
    /// for its own folder, that folder (round-3 N1-P2).
    func testTheChoiceLooksOnlyAtThisCopysApplicationSupportAndCreatesOnlyTheMarkerAndTheFolder() throws {
        let appSupport = temp.appendingPathComponent("Application Support").path
        XCTAssertTrue(earlierFiles.allSatisfy { $0.path.hasPrefix(appSupport) }, "\(earlierFiles)")
        XCTAssertFalse(ModelFolder.earlierLaunchFiles().contains { $0.path.contains("/Documents") })
        XCTAssertFalse(ModelFolder.ownModelFolder(in: AppIdentity.current.supportDirectory).path.contains("/Documents"))
        XCTAssertEqual(choose(), .applicationSupport)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: earlierFiles[0].path).sorted(),
                       ["huggingface", "model-folder"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlierFiles[1].path), "no store")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("home").path), "nothing in the home folder")
    }

    /// The app's first steps make the store (AppDelegate's history) and the
    /// support folder (the activity lease, the queues), so the choice is made
    /// at the entry point, before the app exists — after the self-check, which
    /// writes nothing.
    func testTheChoiceIsMadeAtTheEntryPointBeforeTheAppStarts() throws {
        let launch = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Launch.swift")
        let code = try String(contentsOf: launch, encoding: .utf8).components(separatedBy: "\n")
            .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
        let selfCheck = try XCTUnwrap(code.firstIndex { $0.contains("SelfCheck.runAndExit()") })
        let choice = try XCTUnwrap(code.firstIndex { $0.contains("ModelFolder.chooseOnce(in: .standard)") })
        let app = try XCTUnwrap(code.firstIndex { $0.contains("MetaWhispApp.main()") })
        XCTAssertLessThan(selfCheck, choice)
        XCTAssertLessThan(choice, app)
    }

    // MARK: - The paths

    func testTheDocumentsFolderIsTodaysPathAndShared() {
        let documents = folder(.documents)
        XCTAssertEqual(documents.speechModels.path,
                       temp.appendingPathComponent("home/Documents/huggingface/models/argmaxinc/whisperkit-coreml").path)
        XCTAssertTrue(documents.isShared)
    }

    func testTheOwnFolderLivesInTheSupportFolderAndIsNotShared() {
        let own = folder(.applicationSupport)
        XCTAssertEqual(own.base.path, temp.appendingPathComponent("Application Support/MetaWhisp/huggingface").path)
        XCTAssertEqual(own.speechModels.path,
                       temp.appendingPathComponent("Application Support/MetaWhisp/huggingface/models/argmaxinc/whisperkit-coreml").path)
        XCTAssertFalse(own.isShared)
    }

    /// F2 — each copy of MetaWhisp gets a folder of its own, so a test copy
    /// finds none of the owner's models and really downloads.
    func testEachCopyHasItsOwnFolder() {
        let appSupport = temp.appendingPathComponent("Application Support")
        let production = ModelFolder(kind: .applicationSupport, home: temp,
                                     supportDirectory: AppIdentity(bundleIdentifier: "com.metawhisp.app").supportDirectory(applicationSupport: appSupport))
        let dev = ModelFolder(kind: .applicationSupport, home: temp,
                              supportDirectory: AppIdentity(bundleIdentifier: "com.metawhisp.app.dev").supportDirectory(applicationSupport: appSupport))
        XCTAssertNotEqual(production.base, dev.base)
    }

    // MARK: - Every reader uses the folder

    /// Left to WhisperKit, a load looks in ~/Documents/huggingface and
    /// downloads there again — the prompt the folder exists to avoid.
    func testTheEngineLoadsFromTheInstallsFolder() {
        let own = folder(.applicationSupport)
        let config = WhisperKitEngine.config(variant: "openai_whisper-base", downloadBase: own.base)
        XCTAssertEqual(config.downloadBase, own.base)
        XCTAssertEqual(config.model, "openai_whisper-base")
    }

    /// Step-1 review #8: WhisperKit loads the CoreML weights in its init only
    /// when asked (`load ?? modelFolder != nil`, WhisperKit.swift:91); left
    /// alone it loads them at the first transcription, so "loaded" came first.
    func testTheEngineLoadsTheWeightsBeforeItSaysLoaded() {
        let config = WhisperKitEngine.config(variant: "openai_whisper-base", downloadBase: folder(.applicationSupport).base)
        XCTAssertEqual(config.load, true)
        XCTAssertNil(config.modelFolder, "the download base locates the model; WhisperKit resolves the folder itself")
    }

    @MainActor
    func testTheDownloadGoesToTheInstallsFolder() async {
        let own = folder(.applicationSupport)
        let manager = ModelManagerService(folder: own)
        let received = Received()
        manager.download = { variant, base, _ in
            received.set(variant, base)
            throw CancellationError()
        }
        manager.startDownload("base")
        for _ in 0..<200 where received.base == nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(received.base, own.base)
        XCTAssertEqual(received.variant, "openai_whisper-base")
        manager.cancelDownload()
    }

    @MainActor
    func testModelsOnDiskAreFoundInTheInstallsFolder() throws {
        let own = folder(.applicationSupport)
        try FileManager.default.createDirectory(at: own.speechModels.appendingPathComponent("openai_whisper-base", isDirectory: true),
                                                withIntermediateDirectories: true)
        let manager = ModelManagerService(folder: own)
        manager.refreshDownloaded()
        XCTAssertTrue(manager.isDownloaded("base"))
        XCTAssertFalse(manager.isDownloaded("large-v3-turbo"))
    }
}

/// What a download stub was called with, read from the test's actor.
private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (variant: String, base: URL)?

    func set(_ variant: String, _ base: URL) {
        lock.lock()
        values = (variant, base)
        lock.unlock()
    }

    var base: URL? {
        lock.lock()
        defer { lock.unlock() }
        return values?.base
    }

    var variant: String? {
        lock.lock()
        defer { lock.unlock() }
        return values?.variant
    }
}

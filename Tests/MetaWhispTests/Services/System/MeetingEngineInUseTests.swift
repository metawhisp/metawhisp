import XCTest
@testable import MetaWhisp

/// A4 for meetings (Codex P1, 1.4.0 review) — a meeting's finalization takes the engine in use at every chunk and
/// every retry, so Pro ending or coming back while the meeting is transcribed takes the engine that works then. It
/// used to keep the engine it began on for every chunk and both channels: Pro coming back unloaded that on-device
/// engine under it and the chunks left failed; Pro ending left them on a cloud engine that could no longer be used.
/// Through the meeting's own chunk transcriber with the real coordinator and fake engines; the Recovery folder is the
/// test's own, in memory.
@MainActor
final class MeetingEngineInUseTests: XCTestCase {
    private struct Saved {
        let engine, provider, groq, openai: String
    }

    private var saved: Saved!

    override func setUp() {
        let settings = AppSettings.shared
        saved = Saved(engine: settings.transcriptionEngine, provider: settings.cloudTranscriptionProvider,
                      groq: settings.groqKey, openai: settings.openaiKey)
        settings.transcriptionEngine = "cloud"
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

    /// One channel of a meeting in two chunks: 250 s of steady sound, cut near the 150 s mark.
    private let channel = [Float](repeating: 0.1, count: 16_000 * 250)

    /// The coordinator as the app wires it, cloud chosen: `pro` says whether the Pro proxy is there.
    private func coordinator(pro: @escaping @MainActor () -> Bool, onDevice: (any TranscriptionEngine)?,
                             cloud: any TranscriptionEngine) -> TranscriptionCoordinator {
        TranscriptionCoordinator(recorder: FakeMicrophone(), whisperEngine: onDevice, textInserter: TextInsertionService(),
                                 soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
                                 voiceQuestions: VoiceQuestionState(), cloudEngine: cloud, openMicrophoneSettings: {},
                                 proxyAvailable: pro)
    }

    /// The chunks a meeting kept in its Recovery folder — in memory: nothing is written.
    private final class Kept {
        var chunks: [[Float]] = []
    }

    /// The channel through the meeting's chunk transcriber, its engine from the coordinator as the app asks for it.
    private func transcribe(_ flow: TranscriptionCoordinator, waitingAtMost limit: Duration = .seconds(5),
                            _ kept: Kept) async -> (segments: [StreamSegment], failedChunks: Int, booking: MeetingBooking) {
        await AppDelegate.transcribeStreamChunked(samples: channel, engine: flow.engineSource(waitingAtMost: limit),
                                                  speaker: .me, countUsage: false,
                                                  saveRecovery: { chunk in kept.chunks.append(chunk); return nil })
    }

    /// A 250 s meeting of two such channels, mic then system, through the dual-stream pass as the finalization runs it:
    /// what it books, by the meeting's length as the finalization measures it (the longer channel).
    private func booked(_ flow: TranscriptionCoordinator) async -> Double {
        let dual = await AppDelegate.transcribeMeetingDualStream(mic: channel, system: channel,
                                                                 engine: flow.engineSource(waitingAtMost: .seconds(5)),
                                                                 saveRecovery: { _ in nil })
        XCTAssertEqual(dual.failedChunks, 0)
        return dual.booking.minutes(forMeetingOf: Double(channel.count) / 16_000)
    }

    /// The channel's chunks, in seconds, as the chunk transcriber cuts it: two, cut near the 150 s mark.
    private var chunkSeconds: [Double] {
        AppDelegate.splitOnSilenceBoundaries(samples: channel, targetChunkSec: AppDelegate.meetingTargetChunkSec,
                                             searchWindowSec: 15).map { Double($0.count) / 16_000 }
    }

    // MARK: - Pro comes back

    /// Pro comes back after the first chunk: the engine switch unloads the on-device engine the meeting began on and
    /// lets it go. The chunk left goes through the cloud, and the transcript is whole.
    func testProReturningMidMeetingTranscribesTheChunkLeftThroughTheCloud() async {
        var pro = false
        let local = MeetingEngine("local", usable: { true })
        let cloud = MeetingEngine("cloud", usable: { pro })
        let flow = coordinator(pro: { pro }, onDevice: local, cloud: cloud)
        local.afterEach = { _ in
            pro = true
            await local.unloadModel()
            flow.whisperEngine = nil
        }
        let kept = Kept()
        let result = await transcribe(flow, kept)
        XCTAssertEqual(result.failedChunks, 0)
        XCTAssertEqual(result.segments.map(\.text), ["local 1", "cloud 1"])
        XCTAssertTrue(kept.chunks.isEmpty, "nothing failed, so nothing needed keeping")
    }

    // MARK: - Pro ends

    /// Pro ends after the first chunk: cloud is out of reach, and the on-device engine is made, then loaded, a moment
    /// later — after the chunk's retry would have come and gone. The chunk left waits for it and is transcribed on
    /// this Mac.
    func testProEndingMidMeetingWaitsForTheOnDeviceEngineAndTranscribesTheChunkLeftOnIt() async {
        var pro = true
        let cloud = MeetingEngine("cloud", usable: { pro })
        let local = MeetingEngine("local", loaded: false, usable: { true })
        let flow = coordinator(pro: { pro }, onDevice: nil, cloud: cloud)
        cloud.afterEach = { _ in
            pro = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                flow.whisperEngine = local                              // the engine switch makes it…
                try? await Task.sleep(for: .milliseconds(1000))
                try? await local.loadModel("base", progressHandler: nil)   // …and its model loads
            }
        }
        let kept = Kept()
        let result = await transcribe(flow, kept)
        XCTAssertEqual(result.failedChunks, 0)
        XCTAssertEqual(result.segments.map(\.text), ["cloud 1", "local 1"])
        XCTAssertTrue(kept.chunks.isEmpty)
    }

    /// The ceiling, one for the whole meeting: Pro ends and no engine comes. The chunk left fails after its retry, its
    /// audio is kept, and the finalization ends instead of waiting on.
    func testWithNoEngineInTimeTheChunkLeftIsKeptAndTheMeetingEnds() async {
        var pro = true
        let cloud = MeetingEngine("cloud", usable: { pro })
        let flow = coordinator(pro: { pro }, onDevice: nil, cloud: cloud)
        cloud.afterEach = { _ in pro = false }                          // and nothing makes an on-device engine
        let kept = Kept()
        let started = ContinuousClock.now
        let result = await transcribe(flow, waitingAtMost: .milliseconds(400), kept)
        XCTAssertEqual(result.failedChunks, 1)
        XCTAssertEqual(result.segments.map(\.text), ["cloud 1"])
        XCTAssertEqual(kept.chunks.count, 1, "the chunk left is kept")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(4), "the wait has its ceiling")
    }

    // MARK: - What the meeting books

    /// Pro comes back after the mic's first chunk (Codex P2, 1.4.0 review): the chunks left — the mic's second and
    /// both of the system channel — go through the Pro proxy, and the meeting books their share of its length. It
    /// booked nothing: the booking read the engine the meeting began on, this Mac's.
    func testAMeetingThatMovesOntoTheProProxyBooksThePartTheProxyTranscribed() async {
        var pro = false
        let local = MeetingEngine("local", usable: { true })
        let cloud = MeetingEngine("cloud", proxy: true, usable: { pro })
        let flow = coordinator(pro: { pro }, onDevice: local, cloud: cloud)
        local.afterEach = { _ in pro = true }
        let minutes = await booked(flow)
        let chunks = chunkSeconds
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(minutes, 250.0 / 60 * (chunks[1] + chunks[0] + chunks[1]) / 500, accuracy: 1e-9)
        XCTAssertGreaterThan(minutes, 0, "the proxy's part is booked")
    }

    /// Pro ends after the mic's first chunk: only that chunk went through the proxy, and only its share is booked —
    /// not the meeting's whole length for the engine it began on, nor nothing because Pro is gone by the booking.
    func testAMeetingThatMovesOffTheProProxyBooksOnlyThePartTheProxyTranscribed() async {
        var pro = true
        let local = MeetingEngine("local", usable: { true })
        let cloud = MeetingEngine("cloud", proxy: true, usable: { pro })
        let flow = coordinator(pro: { pro }, onDevice: local, cloud: cloud)
        cloud.afterEach = { _ in pro = false }
        let minutes = await booked(flow)
        let chunks = chunkSeconds
        XCTAssertEqual(minutes, 250.0 / 60 * chunks[0] / 500, accuracy: 1e-9)
        XCTAssertLessThan(minutes, 250.0 / 60, "the part on this Mac books nothing")
    }

    /// A chunk no engine transcribed — every attempt failed — books nothing: Pro ends after the mic's first chunk and no
    /// on-device engine comes in time, so the three chunks left fail (their audio kept) and only the proxy's chunk is
    /// booked, not the meeting's whole length.
    func testAChunkNoEngineTranscribedBooksNothing() async {
        var pro = true
        let cloud = MeetingEngine("cloud", proxy: true, usable: { pro })
        let flow = coordinator(pro: { pro }, onDevice: nil, cloud: cloud)
        cloud.afterEach = { _ in pro = false }
        let dual = await AppDelegate.transcribeMeetingDualStream(mic: channel, system: channel,
                                                                 engine: flow.engineSource(waitingAtMost: .milliseconds(400)),
                                                                 saveRecovery: { _ in nil })
        XCTAssertEqual(dual.failedChunks, 3)
        XCTAssertEqual(dual.booking.minutes(forMeetingOf: 250), 250.0 / 60 * chunkSeconds[0] / 500, accuracy: 1e-9)
    }

    /// The ends as before (ITER-054): a meeting wholly through the Pro proxy books its whole length, once for both
    /// channels; one wholly on this Mac books nothing, and so does the cloud on the user's own key.
    func testAMeetingWhollyThroughTheProxyBooksItsLengthAndOneOffItBooksNothing() async {
        let proxy = MeetingEngine("cloud", proxy: true, usable: { true })
        let whollyProxy = await booked(coordinator(pro: { true }, onDevice: nil, cloud: proxy))
        XCTAssertEqual(whollyProxy, 250.0 / 60, "its length, once")
        let local = MeetingEngine("local", usable: { true })
        let onThisMac = await booked(coordinator(pro: { false }, onDevice: local,
                                                 cloud: MeetingEngine("cloud", proxy: true, usable: { false })))
        XCTAssertEqual(onThisMac, 0)
        let ownKey = MeetingEngine("cloud", usable: { true })
        let onTheirKey = await booked(coordinator(pro: { true }, onDevice: nil, cloud: ownKey))
        XCTAssertEqual(onTheirKey, 0)
    }

    // MARK: - The app's wiring

    /// The finalization books what its chunks say — never the engine it began on, nor whether Pro is there at the end
    /// — and only the cloud engine's way through the Pro proxy says it went that way. Read from the source: neither
    /// has a harness here (the booking and the proxy are network calls).
    func testTheFinalizationBooksWhatItsChunksSayAndOnlyTheProxyPathSaysIt() throws {
        let delegate = try codeLines("App/AppDelegate.swift")
        XCTAssertTrue(delegate.contains { $0.contains("let minutes = dual.booking.minutes(forMeetingOf: duration)") })
        XCTAssertTrue(delegate.contains { $0.contains("await LicenseService.shared.logMeetingUsage(minutes: minutes)") })
        XCTAssertFalse(delegate.contains { $0.contains("engine is CloudWhisperEngine") }, "the engine it began on")
        XCTAssertTrue(delegate.contains { $0.contains("booking.add(seconds:") && $0.contains("viaProProxy: result.viaProProxy") })
        let cloud = try codeLines("Services/Transcription/CloudWhisperEngine.swift")
        let marks = cloud.indices.filter { cloud[$0].contains("viaProProxy: true") }
        XCTAssertEqual(marks.count, 1, "one way says it")
        let proxyPath = try XCTUnwrap(cloud.firstIndex { $0.contains("private func transcribeViaProxy(") })
        let directPath = try XCTUnwrap(cloud.firstIndex { $0.contains("private func transcribeDirect(") })
        XCTAssertTrue(marks.allSatisfy { $0 > proxyPath && $0 < directPath }, "the proxy's")
    }

    /// The finalization asks the coordinator for its engine — at the start, and through the same source at every
    /// chunk — never the engine it began on. Read from the source: the finalization has no harness here.
    func testTheFinalizationTakesItsEngineFromTheCoordinatorAtEveryChunk() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("App/AppDelegate.swift"), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
        XCTAssertTrue(code.contains { $0.contains("coordinator.engineSource(waitingAtMost:") }, "one source per meeting")
        XCTAssertTrue(code.contains {
            $0.contains("transcribeMeetingDualStream(mic: micSamples, system: sysSamples, engine: engines)")
        }, "its chunks ask that source")
        for step in ["static func transcribeMeetingDualStream(", "static func transcribeStreamChunked("] {
            let start = try XCTUnwrap(code.firstIndex { $0.contains(step) }, step)
            let signature = code[start...].prefix { !$0.contains(") async -> (") }
            XCTAssertFalse(signature.contains { $0.contains("engine: TranscriptionEngine") || $0.contains("engine: any TranscriptionEngine") },
                           "\(step) is handed a fixed engine")
        }
    }

    /// A source file's lines, by its path from the repository's root, with line comments stripped: only code counts.
    private func codeLines(_ path: String) throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
            .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
    }
}

/// A meeting's engine: says "<name> <n>" for its n-th transcription while it holds a model and can be used, and runs
/// `afterEach` on the main actor after each — what changes while the meeting is transcribed. `proxy`: its results say
/// they came through the Pro proxy, as the cloud engine's do on Pro.
final class MeetingEngine: TranscriptionEngine, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var loaded: Bool
    private var count = 0
    private let proxy: Bool
    private let usable: @MainActor () -> Bool
    var afterEach: (@MainActor (Int) async -> Void)?

    init(_ name: String, loaded: Bool = true, proxy: Bool = false, usable: @escaping @MainActor () -> Bool) {
        self.name = name
        self.loaded = loaded
        self.proxy = proxy
        self.usable = usable
    }

    var isModelLoaded: Bool { lock.withLock { loaded } }

    func loadModel(_ modelName: String, progressHandler: (@Sendable (Double) -> Void)?) async throws {
        lock.withLock { loaded = true }
    }

    func unloadModel() async {
        lock.withLock { loaded = false }
    }

    func transcribe(audioSamples: [Float], language: String?, promptWords: [String],
                    countUsage: Bool) async throws -> TranscriptionResult {
        guard isModelLoaded else { throw TranscriptionError.modelNotLoaded }
        guard await usable() else { throw TranscriptionError.noAPIKey }
        let n = lock.withLock { () -> Int in
            count += 1
            return count
        }
        if let afterEach { await afterEach(n) }
        return TranscriptionResult(text: "\(name) \(n)", language: "en", duration: 1, processingTime: 0.1, segments: [],
                                   viaProProxy: proxy)
    }
}

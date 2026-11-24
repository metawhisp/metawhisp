import XCTest
@testable import MetaWhisp

/// ITER-085 — where a Target dictation goes is read once, as recording starts, and handed to post-processing with
/// the transcript. A voice question goes to MetaChat whatever window had focus. No other mode reads the place.
@MainActor
final class TargetPlaceFlowTests: XCTestCase {
    private var savedEngine = ""
    private var savedAutoSubmit = true
    private var state = VoiceQuestionState()
    private var reads = 0

    override func setUpWithError() throws {
        savedEngine = AppSettings.shared.transcriptionEngine
        savedAutoSubmit = AppSettings.shared.autoSubmit
        // The fake engine stands in for the cloud one, and nothing is ever pasted.
        AppSettings.shared.transcriptionEngine = "cloud"
        AppSettings.shared.autoSubmit = false
        state = VoiceQuestionState()
        reads = 0
    }

    override func tearDownWithError() throws {
        state.dismiss()
        AppSettings.shared.transcriptionEngine = savedEngine
        AppSettings.shared.autoSubmit = savedAutoSubmit
    }

    private static let mail = PlaceAddress(app: "Mail", bundle: "com.apple.mail", window: "Re: Landing page")

    private func coordinator(_ processor: PlaceRecordingProcessor) -> TranscriptionCoordinator {
        let flow = TranscriptionCoordinator(
            recorder: FakeMicrophone(), whisperEngine: nil, textInserter: TextInsertionService(),
            soundService: SoundService(enabled: { false }), settings: AppSettings.shared,
            voiceQuestions: state, cloudEngine: HeldEngine(text: "the landing slips to friday", answersAtOnce: true),
            openMicrophoneSettings: {}, proxyAvailable: { true },
            readPlace: { [weak self] _ in
                self?.reads += 1
                return Self.mail
            })
        flow.textProcessor = processor
        return flow
    }

    private func spin(until done: () -> Bool, within seconds: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testADictationInTargetCarriesThePlaceReadAtItsStart() {
        let processor = PlaceRecordingProcessor(wantsPlace: true)
        let flow = coordinator(processor)
        flow.startPTT()
        flow.stopPTT()
        spin(until: { !processor.places.isEmpty })
        XCTAssertEqual(processor.places, [Self.mail])
        XCTAssertEqual(reads, 1, "read once, at the start")
    }

    func testAVoiceQuestionIsShapedForMetaChatNotForTheWindowBehindIt() {
        let processor = PlaceRecordingProcessor(wantsPlace: true)
        let flow = coordinator(processor)
        flow.startVoiceQuestion()
        flow.stopVoiceQuestion()
        spin(until: { !processor.places.isEmpty })
        XCTAssertEqual(processor.places, [PlaceAddress.metaChat])
        XCTAssertEqual(reads, 0, "the window behind a voice question is not read (Kimi review, P3)")
    }

    func testNoOtherModeReadsThePlace() {
        let processor = PlaceRecordingProcessor(wantsPlace: false)
        let flow = coordinator(processor)
        flow.startPTT()
        flow.stopPTT()
        spin(until: { !processor.places.isEmpty })
        XCTAssertEqual(processor.places, [nil])
        XCTAssertEqual(reads, 0, "nothing about the window is read")
    }
}

/// Post-processing that records the place each transcript came with.
@MainActor
final class PlaceRecordingProcessor: TranscriptPostProcessor {
    let wantsPlace: Bool
    private(set) var places: [PlaceAddress?] = []

    init(wantsPlace: Bool) {
        self.wantsPlace = wantsPlace
    }

    var needsProcessing: Bool { true }

    func process(_ text: String, translate: Bool, place: PlaceAddress?) async throws -> (String, Bool) {
        places.append(place)
        return (text, false)
    }
}

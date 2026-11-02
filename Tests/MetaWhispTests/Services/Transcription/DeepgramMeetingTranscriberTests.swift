import XCTest
@testable import MetaWhisp

/// Pure request, audio, decoding, and transcript pipeline regression tests.
final class DeepgramMeetingTranscriberTests: XCTestCase {

    typealias DG = DeepgramMeetingTranscriber

    private func channelUtterance(_ text: String, _ start: Double, _ end: Double, _ channel: Int) -> DG.DGChannelUtterance {
        DG.DGChannelUtterance(start: start, end: end, transcript: text, channel: channel, speaker: nil)
    }
    private func utt(_ s: Double, _ e: Double, _ text: String, spk: Int) -> DG.DGUtterance {
        DG.DGUtterance(start: s, end: e, transcript: text, speaker: spk)
    }

    // MARK: - URL contract

    func test_requestURL_usesExplicitLanguage() {
        for language in ["ru", "en"] {
            let components = URLComponents(url: DG.requestURL(language: language), resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.queryItems?.first { $0.name == "language" }?.value, language)
        }
    }

    func test_requestURL_autoUsesMulti() {
        let components = URLComponents(url: DG.requestURL(language: nil), resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first { $0.name == "language" }?.value, "multi")
    }

    /// Channel attribution requires separate recognition of each source.
    func test_requestURL_hasSeparateChannelsAndNoKey() {
        let url = DG.requestURL(language: nil).absoluteString
        XCTAssertTrue(url.hasPrefix("https://api.deepgram.com/v1/listen?"))
        for param in ["model=nova-3", "multichannel=true", "utterances=true", "smart_format=true", "language=multi"] {
            XCTAssertTrue(url.contains(param), "missing \(param) in \(url)")
        }
        XCTAssertFalse(url.lowercased().contains("token"))
        XCTAssertFalse(url.lowercased().contains("key"))
        XCTAssertFalse(url.contains("diarize"))
    }

    // MARK: - Speaker → channel mapping

    /// Speaker heard on the mic channel → Me; on the system channel → Them.
    func test_mapping_byChannelEnergy() {
        let utts = [utt(0, 2, "привет", spk: 0), utt(2, 4, "hello back", spk: 1)]
        let mapping = DG.mapSpeakersToChannels(
            utterances: utts,
            micEnergy: { s, _ in s < 2 ? 0.5 : 0.01 },     // mic loud during spk 0
            systemEnergy: { s, _ in s < 2 ? 0.01 : 0.5 }   // system loud during spk 1
        )
        XCTAssertEqual(mapping[0], .me)
        XCTAssertEqual(mapping[1], .them)
    }

    /// >2 speakers: every remote voice maps to Them (they all live on the
    /// system channel) — the transcript stays coherent instead of dropping them.
    func test_mapping_multipleRemoteSpeakers_allThem() {
        let utts = [utt(0, 1, "a", spk: 0), utt(1, 2, "b", spk: 1), utt(2, 3, "c", spk: 2)]
        let mapping = DG.mapSpeakersToChannels(
            utterances: utts,
            micEnergy: { s, _ in s < 1 ? 0.6 : 0.02 },
            systemEnergy: { s, _ in s < 1 ? 0.02 : 0.6 }
        )
        XCTAssertEqual(mapping[0], .me)
        XCTAssertEqual(mapping[1], .them)
        XCTAssertEqual(mapping[2], .them)
    }

    // MARK: - Segments + render (same downstream format as the Whisper path)

    func test_segments_renderAsMeThem() {
        let utts = [utt(0, 2, "как дела", spk: 0), utt(2, 4, "хорошо, спасибо", spk: 1),
                    utt(4, 6, "отлично", spk: 1)]
        let segs = DG.segments(utterances: utts, mapping: [0: .me, 1: .them])
        let text = DualStreamMerger.renderTranscript(segs)
        XCTAssertEqual(text, "Me: как дела\nThem: хорошо, спасибо отлично")
    }

    /// Whitespace-only utterances are dropped; unknown speaker ids default to
    /// Them (never crash, never attribute a stranger's words to the user).
    func test_segments_dropsEmpty_defaultsUnknownToThem() {
        let utts = [utt(0, 1, "  ", spk: 0), utt(1, 2, "text", spk: 7)]
        let segs = DG.segments(utterances: utts, mapping: [0: .me])
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].speaker, .them)
    }

    // MARK: - windowRMS

    func test_windowRMS_boundsAndSignal() {
        var samples = [Float](repeating: 0, count: 16_000 * 4)
        for i in (16_000 * 2)..<(16_000 * 3) { samples[i] = 0.5 }  // loud 2s..3s
        XCTAssertEqual(DG.windowRMS(samples, startSec: 2, endSec: 3), 0.5, accuracy: 0.01)
        XCTAssertEqual(DG.windowRMS(samples, startSec: 0, endSec: 1), 0.0, accuracy: 0.001)
        // Codex review — a window ENTIRELY past this channel's end contributes
        // ZERO (not the clamp-repeated last sample: that flipped tail Me/Them
        // when mic/system buffers differ in length).
        for i in (16_000 * 3)..<samples.count { samples[i] = 0.9 }  // loud last sample region
        XCTAssertEqual(DG.windowRMS(samples, startSec: 100, endSec: 200), 0.0, accuracy: 0.0001)
        XCTAssertEqual(DG.windowRMS([], startSec: 0, endSec: 1), 0)
    }

    // MARK: - Streamed WAV writer (Codex review — no full-meeting buffers)

    /// Header fields + payload length + mixing semantics survive the slice-wise
    /// streaming path (2s mic + 3s system → 3s file, tail from the longer).
    func test_writeMixedWAV_streamed_headerAndMixing() throws {
        let mic = [Float](repeating: 0.25, count: 32_000)      // 2s
        let system = [Float](repeating: 0.25, count: 48_000)   // 3s
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dg-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let seconds = try DG.writeMixedWAV(mic: mic, system: system, to: tmp)
        XCTAssertEqual(seconds, 3.0, accuracy: 0.001)

        let data = try Data(contentsOf: tmp)
        XCTAssertEqual(data.count, 44 + 48_000 * 2, "44-byte header + 16-bit samples")
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        // Sample rate little-endian at offset 24 = 16000.
        let rate = data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: rate), 16_000)
        // Overlap region: 0.25+0.25=0.5 → Int16 ≈ 16383; tail (system only) ≈ 8191.
        let firstSample = data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(Int(Int16(littleEndian: firstSample)), 16383, accuracy: 2)
        let tailOffset = 44 + 40_000 * 2  // 2.5s — inside system-only tail
        let tailSample = data[tailOffset..<(tailOffset + 2)].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(Int(Int16(littleEndian: tailSample)), 8191, accuracy: 2)
    }

    /// Reuse the established non-English fixture as escaped Unicode scalars.
    private func russianMeeting() -> [DG.DGChannelUtterance] {
        let phrases = [
            "\u{434}\u{430}\u{432}\u{430}\u{439}\u{442}\u{435} \u{43e}\u{431}\u{441}\u{443}\u{434}\u{438}\u{43c} \u{43f}\u{43b}\u{430}\u{43d}\u{44b} \u{43d}\u{430} \u{441}\u{43b}\u{435}\u{434}\u{443}\u{44e}\u{449}\u{443}\u{44e} \u{43d}\u{435}\u{434}\u{435}\u{43b}\u{44e}",
            "\u{43c}\u{43d}\u{435} \u{43a}\u{430}\u{436}\u{435}\u{442}\u{441}\u{44f} \u{43d}\u{443}\u{436}\u{43d}\u{43e} \u{43f}\u{435}\u{440}\u{435}\u{43d}\u{435}\u{441}\u{442}\u{438} \u{440}\u{435}\u{43b}\u{438}\u{437} \u{43d}\u{430} \u{43f}\u{43e}\u{43d}\u{435}\u{434}\u{435}\u{43b}\u{44c}\u{43d}\u{438}\u{43a}",
            "\u{43a}\u{43e}\u{43c}\u{430}\u{43d}\u{434}\u{430} \u{437}\u{430}\u{43a}\u{43e}\u{43d}\u{447}\u{438}\u{43b}\u{430} \u{438}\u{43d}\u{442}\u{435}\u{433}\u{440}\u{430}\u{446}\u{438}\u{44e} \u{43f}\u{43b}\u{430}\u{442}\u{435}\u{436}\u{435}\u{439} \u{432}\u{447}\u{435}\u{440}\u{430} \u{432}\u{435}\u{447}\u{435}\u{440}\u{43e}\u{43c}",
            "\u{43e}\u{441}\u{442}\u{430}\u{43b}\u{438}\u{441}\u{44c} \u{432}\u{43e}\u{43f}\u{440}\u{43e}\u{441}\u{44b} \u{43f}\u{43e} \u{434}\u{438}\u{437}\u{430}\u{439}\u{43d}\u{443} \u{433}\u{43b}\u{430}\u{432}\u{43d}\u{43e}\u{433}\u{43e} \u{44d}\u{43a}\u{440}\u{430}\u{43d}\u{430}",
            "\u{43f}\u{43e}\u{43b}\u{44c}\u{437}\u{43e}\u{432}\u{430}\u{442}\u{435}\u{43b}\u{438} \u{436}\u{430}\u{43b}\u{443}\u{44e}\u{442}\u{441}\u{44f} \u{43d}\u{430} \u{43c}\u{435}\u{434}\u{43b}\u{435}\u{43d}\u{43d}\u{443}\u{44e} \u{437}\u{430}\u{433}\u{440}\u{443}\u{437}\u{43a}\u{443}",
            "\u{43f}\u{440}\u{435}\u{434}\u{43b}\u{430}\u{433}\u{430}\u{44e} \u{441}\u{43e}\u{437}\u{432}\u{43e}\u{43d}\u{438}\u{442}\u{44c}\u{441}\u{44f} \u{437}\u{430}\u{432}\u{442}\u{440}\u{430} \u{432} \u{43e}\u{434}\u{438}\u{43d}\u{43d}\u{430}\u{434}\u{446}\u{430}\u{442}\u{44c} \u{443}\u{442}\u{440}\u{430}",
            "\u{431}\u{44e}\u{434}\u{436}\u{435}\u{442} \u{43d}\u{430} \u{43c}\u{430}\u{440}\u{43a}\u{435}\u{442}\u{438}\u{43d}\u{433} \u{443}\u{442}\u{432}\u{435}\u{440}\u{434}\u{438}\u{43b}\u{438} \u{431}\u{435}\u{437} \u{438}\u{437}\u{43c}\u{435}\u{43d}\u{435}\u{43d}\u{438}\u{439}",
            "\u{43d}\u{443}\u{436}\u{43d}\u{43e} \u{43e}\u{431}\u{43d}\u{43e}\u{432}\u{438}\u{442}\u{44c} \u{434}\u{43e}\u{43a}\u{443}\u{43c}\u{435}\u{43d}\u{442}\u{430}\u{446}\u{438}\u{44e} \u{43f}\u{435}\u{440}\u{435}\u{434} \u{434}\u{435}\u{43c}\u{43e}",
            "\u{442}\u{435}\u{441}\u{442}\u{438}\u{440}\u{43e}\u{432}\u{449}\u{438}\u{43a}\u{438} \u{43d}\u{430}\u{448}\u{43b}\u{438} \u{442}\u{440}\u{438} \u{43a}\u{440}\u{438}\u{442}\u{438}\u{447}\u{43d}\u{44b}\u{445} \u{431}\u{430}\u{433}\u{430}",
            "\u{430}\u{43f}\u{434}\u{435}\u{439}\u{442} \u{432}\u{44b}\u{43a}\u{430}\u{442}\u{438}\u{43c} \u{441}\u{43d}\u{430}\u{447}\u{430}\u{43b}\u{430} \u{43d}\u{430} \u{434}\u{435}\u{441}\u{44f}\u{442}\u{44c} \u{43f}\u{440}\u{43e}\u{446}\u{435}\u{43d}\u{442}\u{43e}\u{432}",
            "\u{43c}\u{435}\u{442}\u{440}\u{438}\u{43a}\u{438} \u{443}\u{434}\u{435}\u{440}\u{436}\u{430}\u{43d}\u{438}\u{44f} \u{432}\u{44b}\u{440}\u{43e}\u{441}\u{43b}\u{438} \u{437}\u{430} \u{43f}\u{43e}\u{441}\u{43b}\u{435}\u{434}\u{43d}\u{438}\u{439} \u{43c}\u{435}\u{441}\u{44f}\u{446}",
            "\u{434}\u{43e}\u{433}\u{43e}\u{432}\u{43e}\u{440}\u{438}\u{43b}\u{438}\u{441}\u{44c} \u{432}\u{43e}\u{437}\u{432}\u{440}\u{430}\u{449}\u{430}\u{435}\u{43c}\u{441}\u{44f} \u{43a} \u{44d}\u{442}\u{43e}\u{43c}\u{443} \u{432} \u{43f}\u{44f}\u{442}\u{43d}\u{438}\u{446}\u{443}",
            "\u{43d}\u{430}\u{447}\u{43d}\u{435}\u{43c} \u{441} \u{441}\u{430}\u{43c}\u{43e}\u{433}\u{43e} \u{432}\u{430}\u{436}\u{43d}\u{43e}\u{433}\u{43e} \u{432}\u{43e}\u{43f}\u{440}\u{43e}\u{441}\u{430} \u{43f}\u{43e}\u{432}\u{435}\u{441}\u{442}\u{43a}\u{438}",
            "\u{43a}\u{43b}\u{438}\u{435}\u{43d}\u{442} \u{43f}\u{43e}\u{43f}\u{440}\u{43e}\u{441}\u{438}\u{43b} \u{43f}\u{435}\u{440}\u{435}\u{43d}\u{435}\u{441}\u{442}\u{438} \u{434}\u{435}\u{43c}\u{43e}\u{43d}\u{441}\u{442}\u{440}\u{430}\u{446}\u{438}\u{44e} \u{43d}\u{430} \u{447}\u{435}\u{442}\u{432}\u{435}\u{440}\u{433}",
            "\u{434}\u{438}\u{437}\u{430}\u{439}\u{43d}\u{435}\u{440}\u{44b} \u{43f}\u{43e}\u{434}\u{433}\u{43e}\u{442}\u{43e}\u{432}\u{438}\u{43b}\u{438} \u{43d}\u{43e}\u{432}\u{44b}\u{435} \u{43c}\u{430}\u{43a}\u{435}\u{442}\u{44b} \u{44d}\u{43a}\u{440}\u{430}\u{43d}\u{430} \u{43e}\u{43f}\u{43b}\u{430}\u{442}\u{44b}",
            "\u{43d}\u{430}\u{434}\u{43e} \u{43f}\u{440}\u{43e}\u{432}\u{435}\u{440}\u{438}\u{442}\u{44c} \u{430}\u{43d}\u{430}\u{43b}\u{438}\u{442}\u{438}\u{43a}\u{443} \u{43f}\u{43e} \u{43f}\u{43e}\u{441}\u{43b}\u{435}\u{434}\u{43d}\u{435}\u{43c}\u{443} \u{440}\u{435}\u{43b}\u{438}\u{437}\u{443}",
            "\u{43f}\u{43e}\u{434}\u{434}\u{435}\u{440}\u{436}\u{43a}\u{430} \u{43f}\u{43e}\u{43b}\u{443}\u{447}\u{438}\u{43b}\u{430} \u{43c}\u{435}\u{43d}\u{44c}\u{448}\u{435} \u{43e}\u{431}\u{440}\u{430}\u{449}\u{435}\u{43d}\u{438}\u{439} \u{43d}\u{430} \u{44d}\u{442}\u{43e}\u{439} \u{43d}\u{435}\u{434}\u{435}\u{43b}\u{435}",
            "\u{441}\u{435}\u{440}\u{432}\u{435}\u{440}\u{43d}\u{44b}\u{435} \u{440}\u{430}\u{441}\u{445}\u{43e}\u{434}\u{44b} \u{432}\u{44b}\u{440}\u{43e}\u{441}\u{43b}\u{438} \u{438}\u{437}-\u{437}\u{430} \u{43d}\u{43e}\u{432}\u{43e}\u{433}\u{43e} \u{442}\u{440}\u{430}\u{444}\u{438}\u{43a}\u{430}",
            "\u{43f}\u{440}\u{435}\u{434}\u{43b}\u{430}\u{433}\u{430}\u{44e} \u{441}\u{43e}\u{43a}\u{440}\u{430}\u{442}\u{438}\u{442}\u{44c} \u{43f}\u{43b}\u{430}\u{43d} \u{43d}\u{430} \u{441}\u{43b}\u{435}\u{434}\u{443}\u{44e}\u{449}\u{438}\u{439} \u{441}\u{43f}\u{440}\u{438}\u{43d}\u{442}",
            "\u{44e}\u{440}\u{438}\u{441}\u{442}\u{44b} \u{441}\u{43e}\u{433}\u{43b}\u{430}\u{441}\u{43e}\u{432}\u{430}\u{43b}\u{438} \u{434}\u{43e}\u{433}\u{43e}\u{432}\u{43e}\u{440} \u{441} \u{43f}\u{43e}\u{434}\u{440}\u{44f}\u{434}\u{447}\u{438}\u{43a}\u{43e}\u{43c} \u{432}\u{447}\u{435}\u{440}\u{430}",
            "\u{43c}\u{430}\u{440}\u{43a}\u{435}\u{442}\u{438}\u{43d}\u{433} \u{437}\u{430}\u{43f}\u{443}\u{441}\u{43a}\u{430}\u{435}\u{442} \u{43a}\u{430}\u{43c}\u{43f}\u{430}\u{43d}\u{438}\u{44e} \u{432} \u{43d}\u{430}\u{447}\u{430}\u{43b}\u{435} \u{43c}\u{435}\u{441}\u{44f}\u{446}\u{430}",
            "\u{438}\u{441}\u{441}\u{43b}\u{435}\u{434}\u{43e}\u{432}\u{430}\u{43d}\u{438}\u{435} \u{43f}\u{43e}\u{43b}\u{44c}\u{437}\u{43e}\u{432}\u{430}\u{442}\u{435}\u{43b}\u{435}\u{439} \u{437}\u{430}\u{43a}\u{43e}\u{43d}\u{447}\u{438}\u{43c} \u{43a} \u{441}\u{440}\u{435}\u{434}\u{435}",
        ]
        return phrases.enumerated().map { index, text in
            channelUtterance(text, Double(index * 10), Double(index * 10 + 5), index % 2)
        }
    }

    // MARK: - Channel cleanup

    func test_channelCleanup_preservesLaterObjection() throws {
        let utterances = [
            channelUtterance("we should approve this contract", 10, 12, 1),
            channelUtterance("we should not approve this contract", 13, 15, 0),
        ]
        let result = DG.cleanChannelSegments(utterances: utterances)
        XCTAssertEqual(result.kept, DG.channelSegments(utterances: utterances))
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertEqual(try DG.renderChannelTranscript(result),
                       "Them: we should approve this contract\nMe: we should not approve this contract")
    }

    func test_channelCleanup_preservesRepeatedAcknowledgementsOnSameChannel() throws {
        let utterances = [
            channelUtterance("yes.", 10, 11, 0),
            channelUtterance("yes.", 20, 21, 0),
        ]
        let result = DG.cleanChannelSegments(utterances: utterances)
        XCTAssertEqual(result.kept, DG.channelSegments(utterances: utterances))
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertEqual(try DG.renderChannelTranscript(result), "Me: yes. yes.")
    }

    func test_channelCleanup_preservesConfidentSingletonEnglishInSpanishMeeting() throws {
        let phrases = [
            "Tenemos que revisar todos los detalles del contrato antes de firmarlo",
            "La fecha de entrega depende de los resultados de las pruebas",
            "El presupuesto para el siguiente trimestre incluye todos los gastos previstos",
            "Necesitamos preparar la documentacion para la reunion de la proxima semana",
        ]
        var utterances = (0..<22).map { index in
            channelUtterance(phrases[index % phrases.count], Double(index * 10), Double(index * 10 + 5), index % 2)
        }
        let phrase = "could you repeat that"
        let detection = try XCTUnwrap(MeetingTranscriptSanitizer.detectLanguage(phrase))
        XCTAssertEqual(detection.lang, "en")
        XCTAssertGreaterThanOrEqual(detection.confidence, 0.9)
        utterances.append(channelUtterance(phrase, 230, 232, 0))
        let segments = DG.channelSegments(utterances: utterances)
        let decoderResult = MeetingTranscriptSanitizer.sanitize(segments)
        XCTAssertTrue(decoderResult.dropped.contains {
            $0.segment.text == phrase && $0.reason == "foreign-language-fragment (en)"
        }, "The fixture must exercise the decoder policy's foreign-fragment filter")

        let result = DG.cleanChannelSegments(utterances: utterances)
        XCTAssertEqual(result.kept, segments)
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertTrue(try DG.renderChannelTranscript(result).hasSuffix("Me: could you repeat that"))
    }

    func test_channelCleanup_removesNearSimultaneousExactEcho() throws {
        let utterances = [
            channelUtterance("we should approve this contract", 10, 12, 1),
            channelUtterance("we should approve this contract", 10.1, 12.1, 0),
        ]
        let segments = DG.channelSegments(utterances: utterances)
        let result = DG.cleanChannelSegments(utterances: utterances)
        XCTAssertEqual(result.kept, [segments[0]])
        XCTAssertEqual(result.dropped, [.init(segment: segments[1], reason: "cross-channel-echo")])
        XCTAssertEqual(try DG.renderChannelTranscript(result), "Them: we should approve this contract")
    }

    func test_channelCleanup_removesNearSimultaneousEchoWithOmittedWord() throws {
        let utterances = [
            channelUtterance("we should approve this contract", 10, 12, 1),
            channelUtterance("we should approve contract", 10.4, 12.4, 0),
        ]
        let segments = DG.channelSegments(utterances: utterances)
        let result = DG.cleanChannelSegments(utterances: utterances)
        XCTAssertEqual(result.kept, [segments[0]])
        XCTAssertEqual(result.dropped, [.init(segment: segments[1], reason: "cross-channel-echo")])
        XCTAssertEqual(try DG.renderChannelTranscript(result), "Them: we should approve this contract")
    }

    func test_channelCleanup_preservesDifferentDoubleTalk() throws {
        let result = DG.cleanChannelSegments(utterances: [
            channelUtterance("Please review the budget before the next meeting", 10, 14, 1),
            channelUtterance("I am checking the release notes right now", 10, 14, 0),
        ])
        XCTAssertEqual(result.kept.map(\.speaker), [.me, .them])
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertEqual(try DG.renderChannelTranscript(result),
                       "Me: I am checking the release notes right now\nThem: Please review the budget before the next meeting")
    }

    func test_channelCleanup_preservesAcknowledgementsFromBothSides() throws {
        let result = DG.cleanChannelSegments(utterances: [
            channelUtterance("yes.", 10, 11, 0), channelUtterance("yes.", 11, 12, 1),
        ])
        XCTAssertEqual(result.kept.map(\.speaker), [.me, .them])
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertEqual(try DG.renderChannelTranscript(result), "Me: yes.\nThem: yes.")
    }

    func test_channelCleanup_preservesFourWordEnglishInNonEnglishMeeting() {
        var utterances = russianMeeting()
        XCTAssertGreaterThanOrEqual(utterances.count, 20)
        utterances.append(channelUtterance("can you hear me", 230, 232, 0))
        let result = DG.cleanChannelSegments(utterances: utterances)
        XCTAssertTrue(result.kept.contains { $0.text == "can you hear me" })
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func test_channelCleanup_emptyResultThrows() {
        let result = DG.cleanChannelSegments(utterances: [channelUtterance(" \n ", 0, 1, 0)])
        XCTAssertThrowsError(try DG.renderChannelTranscript(result)) { error in
            guard case DG.DGError.emptyTranscript = error else {
                return XCTFail("Expected emptyTranscript, got \(error)")
            }
        }
    }

    // MARK: - Diagnostics

    func test_diagnosticLine_comparesUtteranceAndChannelTextWithoutLoggingSpeech() throws {
        let json = """
        {"metadata":{"request_id":"request-test","duration":2.75,"model_info":{
          "model-b":{"name":"nova-3","version":"version-b","arch":"nova-3"},
          "model-a":{"name":"nova-3","version":"version-a","arch":"nova-3"}
        }},"results":{"utterances":[
          {"start":0.1,"end":1.1,"channel":0,"transcript":"Please review the budget"},
          {"start":0,"end":1,"channel":1,"transcript":"Please review the budget"}
        ],"channels":[
          {"alternatives":[{"transcript":"Please review the budget before Friday.","words":[{"end":1},{"end":2}]}]},
          {"alternatives":[{"transcript":"Please review the budget and release notes.","words":[{"end":1},{"end":2.5}]}]}
        ]}}
        """
        let response = try JSONDecoder().decode(DG.DGResponse.self, from: Data(json.utf8))
        let sanitized = DG.cleanChannelSegments(utterances: response.results?.utterances ?? [])
        let line = DG.diagnosticLine(response: response, micSampleCount: 32_000,
                                     systemSampleCount: 48_000, cleanedSegments: sanitized.kept)
        XCTAssertEqual(line, "[Deepgram] diag request_id=request-test models=[model-a:nova-3@version-a,model-b:nova-3@version-b] "
                       + "sent_ch0_s=3.000 sent_ch1_s=3.000 source_ch0_s=2.000 source_ch1_s=3.000 processed_s=2.750 "
                       + "ch0{utterance_chars=24,channel_transcript_chars=39,last_word_end_s=2.000} "
                       + "ch1{utterance_chars=24,channel_transcript_chars=43,last_word_end_s=2.500} "
                       + "total_chars_before_cleanup=48 total_chars_after_cleanup=24")
        XCTAssertFalse(line.contains("Please"))
        XCTAssertFalse(line.contains("budget"))
        XCTAssertFalse(line.contains("\n"))
    }

    func test_diagnosticLine_missingOptionalFieldsStayUnknown() throws {
        let response = try JSONDecoder().decode(DG.DGResponse.self, from: Data("{}".utf8))
        let line = DG.diagnosticLine(response: response, micSampleCount: 0,
                                     systemSampleCount: 0, cleanedSegments: [])
        XCTAssertTrue(line.contains("request_id=unknown models=[unknown]"))
        XCTAssertTrue(line.contains("processed_s=unknown"))
        for channel in 0..<2 {
            XCTAssertTrue(line.contains("ch\(channel){utterance_chars=0,channel_transcript_chars=unknown,last_word_end_s=unknown}"))
        }
        XCTAssertTrue(line.contains("total_chars_before_cleanup=0 total_chars_after_cleanup=0"))
    }

    // MARK: - Stereo WAV and channel decoding

    func test_stereoWAVHeader_zeroAndLargestRepresentableRecording() throws {
        let cases: [(frames: Int, dataBytes: UInt32, riffBytes: UInt32)] = [
            (0, 0, 36),
            (1_073_741_814, 4_294_967_256, 4_294_967_292),
        ]
        for value in cases {
            let header = try DG.stereoWAVHeader(frameCount: value.frames)
            XCTAssertEqual(header.count, 44)
            func u32(_ offset: Int) -> UInt32 {
                header[offset..<(offset + 4)].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            }
            XCTAssertEqual(u32(4), value.riffBytes)
            XCTAssertEqual(u32(40), value.dataBytes)
        }
    }

    func test_stereoWAVHeader_rejectsUnrepresentableSizes() {
        // Header-only checks: no audio buffers or output files are allocated.
        for frames in [1_073_741_815, 1_073_741_824, Int.max, -1] {
            XCTAssertThrowsError(try DG.stereoWAVHeader(frameCount: frames), "frames: \(frames)") { error in
                guard case DG.DGError.recordingTooLarge = error else {
                    return XCTFail("Expected recordingTooLarge, got \(error)")
                }
            }
        }
    }

    func test_writeStereoWAV_headerInterleaveAndPadding() throws {
        let cases: [([Float], [Float], [Int16])] = [
            ([0.25, -0.5, 2, -2], [-0.25, 1], [8191, -8191, -16383, 28861, 32685, 0, -32685, 0]),
            ([-0.25, 1], [0.25, -0.5, 2, -2], [-8191, 8191, 28861, -16383, 0, 32685, 0, -32685]),
        ]
        for (mic, system, expected) in cases {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("dg-stereo-test-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let seconds = try DG.writeStereoWAV(mic: mic, system: system, to: tmp)
            let data = try Data(contentsOf: tmp)
            func u16(_ offset: Int) -> UInt16 {
                data[offset..<(offset + 2)].withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) }
            }
            func u32(_ offset: Int) -> UInt32 {
                data[offset..<(offset + 4)].withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            }
            XCTAssertEqual(seconds, 4.0 / 16_000, accuracy: 0.000001)
            XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
            XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
            XCTAssertEqual(u32(4), 36 + 16)
            XCTAssertEqual(u16(20), 1)
            XCTAssertEqual(u16(22), 2)
            XCTAssertEqual(u32(24), 16_000)
            XCTAssertEqual(u32(28), 64_000)
            XCTAssertEqual(u16(32), 4)
            XCTAssertEqual(u16(34), 16)
            XCTAssertEqual(u32(40), 16)
            XCTAssertEqual(data.count, 44 + 16)
            for (i, sample) in expected.enumerated() {
                XCTAssertEqual(Int(Int16(bitPattern: u16(44 + i * 2))), Int(sample), accuracy: 1)
            }
        }
    }

    func test_writeStereoWAV_streamsAcrossSliceBoundary() throws {
        let count = 1_048_577
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dg-stereo-slices-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let seconds = try DG.writeStereoWAV(mic: [Float](repeating: 0.25, count: count), system: [], to: tmp)
        let data = try Data(contentsOf: tmp)
        XCTAssertEqual(seconds, Double(count) / 16_000)
        XCTAssertEqual(data.count, 44 + count * 4)
        for frame in [0, count - 2, count - 1] {
            let offset = 44 + frame * 4
            let mic = data[offset..<(offset + 2)].withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(as: Int16.self)) }
            let system = data[(offset + 2)..<(offset + 4)].withUnsafeBytes { Int16(littleEndian: $0.loadUnaligned(as: Int16.self)) }
            XCTAssertEqual(mic, 8191)
            XCTAssertEqual(system, 0)
        }
    }

    func test_channelResponse_withoutSpeakersGloballySortsAndDropsBlanks() throws {
        let json = """
        {"results":{"utterances":[
          {"start":1,"end":2,"channel":0,"transcript":"  Mic tie.  "},
          {"start":3,"end":4,"channel":0,"transcript":"Mic later."},
          {"start":5,"end":6,"channel":0,"transcript":"  "},
          {"start":0,"end":1,"channel":1,"transcript":"System first."},
          {"start":1,"end":2,"channel":1,"transcript":"System tie."}
        ]}}
        """
        let response = try JSONDecoder().decode(DG.DGResponse.self, from: Data(json.utf8))
        let utterances = try XCTUnwrap(response.results?.utterances)
        XCTAssertTrue(utterances.allSatisfy { $0.speaker == nil })
        let segments = DG.channelSegments(utterances: utterances)
        XCTAssertEqual(segments.map(\.startSec), [0, 1, 1, 3])
        XCTAssertEqual(segments.map(\.speaker), [.them, .me, .them, .me])
        XCTAssertEqual(segments.map(\.text), ["System first.", "Mic tie.", "System tie.", "Mic later."])
        XCTAssertEqual(DG.channelSegments(utterances: utterances.reversed()), segments)
    }

    func test_channelSegments_ignoreDiarizedSpeakerIdentity() {
        let segments = DG.channelSegments(utterances: [
            DG.DGChannelUtterance(start: 0, end: 1, transcript: "Mic.", channel: 0, speaker: 7),
            DG.DGChannelUtterance(start: 1, end: 2, transcript: "System.", channel: 1, speaker: 7),
        ])
        XCTAssertEqual(segments.map(\.speaker), [.me, .them])
    }

    func test_decode_realResponseShape() throws {
        let json = """
        {"metadata":{"duration":4.2},"results":{"channels":[{"alternatives":[{"transcript":"..."}]}],
         "utterances":[{"start":0.08,"end":1.9,"confidence":0.98,"channel":0,
                        "transcript":"Привет, как дела?","words":[],"speaker":0,"id":"x"}]}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DG.DGResponse.self, from: json)
        XCTAssertEqual(decoded.results?.utterances?.count, 1)
        XCTAssertEqual(decoded.results?.utterances?.first?.speaker, 0)
        XCTAssertEqual(decoded.results?.utterances?.first?.transcript, "Привет, как дела?")
    }
}

import XCTest
@testable import MetaWhisp

/// A meeting chunk carries up to 150 seconds of a call. The finalize pass had
/// two tools for Whisper artifacts and ran them in the wrong order: the blunt
/// one first.
///
/// `isAlwaysHallucination` answers "is this text ENTIRELY an artifact?" and any
/// text under 200 characters containing a known artifact token counted as yes —
/// so the whole chunk was dropped. `stripHallucinationTokens`, which removes
/// just the artifact substring and keeps the speech around it, ran later in the
/// same loop and never got the chance. The suspect log shows 45 chunks
/// discarded this way.
///
/// Strip first, then judge what is left. Nothing that was dropped before for
/// being pure artifact may survive now.
@MainActor
final class MeetingChunkTextGateTests: XCTestCase {

    // MARK: things that must still be dropped

    func testPureArtifactIsStillDropped() {
        XCTAssertNil(MeetingChunkTextGate.keep(text: "Субтитры сделал DimaTorzok", rms: 0.05))
        XCTAssertNil(MeetingChunkTextGate.keep(text: "Продолжение следует...", rms: 0.05))
        XCTAssertNil(MeetingChunkTextGate.keep(text: "Subtitles by DimaTorzok", rms: 0.05))
    }

    func testEmptyAndWhitespaceAreDropped() {
        XCTAssertNil(MeetingChunkTextGate.keep(text: "", rms: 0.05))
        XCTAssertNil(MeetingChunkTextGate.keep(text: "   \n  ", rms: 0.05))
    }

    /// Real speech does not mix three writing systems; Whisper mush does.
    func testMixedScriptGibberishIsDropped() {
        XCTAssertNil(MeetingChunkTextGate.keep(text: "привет hello こんにちは γεια", rms: 0.05))
    }

    /// A near-silent channel that produced filler stays dropped — whether the
    /// filler is a known artifact token (removed by stripping) or a repetition
    /// loop (caught by the silence branch).
    func testLowRMSHallucinationIsDropped() {
        XCTAssertNil(MeetingChunkTextGate.keep(text: "Спасибо за просмотр", rms: 0.001))
        XCTAssertNil(MeetingChunkTextGate.keep(
            text: "ну и комьюнити ну и комьюнити ну и комьюнити ну и комьюнити ну и комьюнити",
            rms: 0.001))
    }

    /// The same repetition over a channel that actually has level is NOT
    /// discarded — a person really can repeat themselves, and the silence gate
    /// is what separates the two cases.
    func testTheSameRepetitionOverRealAudioIsKept() {
        XCTAssertNotNil(MeetingChunkTextGate.keep(
            text: "ну и комьюнити ну и комьюнити ну и комьюнити ну и комьюнити ну и комьюнити",
            rms: 0.05))
    }

    /// The suspect log has to keep saying WHY, or a whole class of loss becomes
    /// invisible in the diagnostics.
    func testDropReasonsStayDistinct() {
        XCTAssertEqual(MeetingChunkTextGate.decide(text: "Субтитры сделал DimaTorzok", rms: 0.05),
                       .drop(reason: "artifact-only"))
        XCTAssertEqual(MeetingChunkTextGate.decide(text: "привет hello こんにちは γεια", rms: 0.05),
                       .drop(reason: "always-hallucination"))
        // Not an artifact token, so stripping leaves it intact — it reaches the
        // silence branch, where a phrase looping over a near-silent channel is
        // what Whisper does instead of admitting it heard nothing.
        XCTAssertEqual(
            MeetingChunkTextGate.decide(
                text: "ну и комьюнити ну и комьюнити ну и комьюнити ну и комьюнити ну и комьюнити",
                rms: 0.001),
            .drop(reason: "low-rms-hallucination"))
    }

    // MARK: the speech that used to go with it

    /// The fix: an artifact spliced onto real speech costs the artifact, not
    /// the call. Under 200 characters this whole chunk used to be discarded.
    func testSpeechSurvivesAnArtifactSplicedOntoIt() {
        let kept = MeetingChunkTextGate.keep(
            text: "Давай перенесём релиз на среду. Субтитры сделал DimaTorzok",
            rms: 0.05
        )
        XCTAssertNotNil(kept, "real speech was thrown away with the artifact")
        XCTAssertTrue(kept?.contains("перенесём релиз на среду") == true)
        XCTAssertFalse(kept?.lowercased().contains("dimatorzok") == true,
                       "the artifact itself must not reach the transcript")
    }

    func testSpeechSurvivesATrailingFillerPhrase() {
        let kept = MeetingChunkTextGate.keep(
            text: "Бюджет на квартал утвердили. Продолжение следует...",
            rms: 0.05
        )
        XCTAssertTrue(kept?.contains("Бюджет на квартал утвердили") == true)
        XCTAssertFalse(kept?.contains("Продолжение следует") == true)
    }

    /// Ordinary speech passes through untouched.
    func testOrdinarySpeechIsUnchanged() {
        let line = "Я думаю, нам нужно сначала обсудить это с командой."
        XCTAssertEqual(MeetingChunkTextGate.keep(text: line, rms: 0.05), line)
    }

    /// A quiet channel is not by itself a reason to discard real speech.
    func testQuietButRealSpeechIsKept() {
        let line = "Окей, тогда я подготовлю документ к пятнице."
        XCTAssertEqual(MeetingChunkTextGate.keep(text: line, rms: 0.001), line)
    }
}

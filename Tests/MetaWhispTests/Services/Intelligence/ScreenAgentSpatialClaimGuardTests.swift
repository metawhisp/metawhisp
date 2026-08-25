import XCTest
@testable import MetaWhisp

/// Claims only eyes can verify.
///
/// The agent's input is flat OCR, yet the prompts asked it about disabled
/// buttons and fields on the right — and the model answered the only way it
/// could: by inventing. Text-only mode now refuses to make those claims at
/// all, which is the honest version of not being able to see.
final class ScreenAgentSpatialClaimGuardTests: XCTestCase {

    func testLayoutClaimsAreCaught() {
        XCTAssertTrue(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "The field on the right is empty"))
        XCTAssertTrue(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "Поле справа не заполнено"))
    }

    func testControlStateClaimsAreCaught() {
        XCTAssertTrue(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "The Submit button is disabled"))
        XCTAssertTrue(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "Кнопка отправки неактивна"))
        XCTAssertTrue(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "The wrong plan is selected"))
    }

    func testColorAsUIStateIsCaught() {
        XCTAssertTrue(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "The Company field is highlighted in red"))
        XCTAssertTrue(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "Поле подсвечено красным"))
    }

    /// The words the guard must NOT fire on: ordinary prose that happens to
    /// share letters with the vocabulary.
    func testOrdinaryProseIsNotASpatialClaim() {
        XCTAssertFalse(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "Anna is waiting for the deck by 16:00"))
        XCTAssertFalse(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "Check the copyright notice before publishing"),
            "\"right\" inside \"copyright\" is not a layout claim")
        XCTAssertFalse(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "Прекрасный результат, отправляй"),
            "\"красн\" inside \"прекрасный\" is not a color claim")
        XCTAssertFalse(ScreenAgentSpatialClaimGuard.makesSpatialClaim(
            "Build 4021 failed on main"))
    }

    /// The end-to-end effect: a text-only candidate making a spatial claim is
    /// silenced by the director, whatever its confidence.
    func testTheDirectorSilencesTextOnlySpatialClaims() {
        let screen = "Company: ___  Submit"
        let ev = ScreenAgentEvidence([.init(id: "e1", contextID: UUID(), text: screen)])
        let c = ScreenAgentDirector.Candidate(
            headline: "The Submit button is disabled because Company is empty",
            body: "", citedEvidenceIDs: ["e1"], quote: "Company",
            confidence: 0.95, namesReferent: true)
        XCTAssertEqual(
            ScreenAgentDirector.decide(candidates: [c], evidence: ev,
                                       screenText: screen, recentHeadlines: []),
            .silence(.needsVision))
    }

    /// With visual evidence attached the same claim is allowed through — the
    /// point is honesty about the input, not banning the vocabulary.
    func testTheSameClaimWithVisualEvidencePasses() {
        let screen = "Company: ___  Submit"
        let ev = ScreenAgentEvidence([
            .init(id: "e1", contextID: UUID(), text: screen),
            .init(id: "v1", contextID: UUID(), text: "visual: Submit disabled; Company empty"),
        ])
        var c = ScreenAgentDirector.Candidate(
            headline: "The Submit button is disabled because Company is empty",
            body: "", citedEvidenceIDs: ["e1", "v1"], quote: "Company",
            confidence: 0.95, namesReferent: true)
        c.visualEvidenceIDs = ["v1"]
        guard case .item = ScreenAgentDirector.decide(
            candidates: [c], evidence: ev, screenText: screen, recentHeadlines: [])
        else { return XCTFail("visual evidence is exactly what licenses this claim") }
    }
}

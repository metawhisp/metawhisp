import XCTest
@testable import MetaWhisp

/// The words said after a meeting about its microphone. Every branch a
/// review round argued over — the floor, "brought back" vs "had not come
/// back", a discarded recording, a permission gone, a Mac with no input
/// device, a silent external input — is pinned here.
final class MicOutageReportTests: XCTestCase {

    private func input(outages: Int = 0, seconds: Double = 0, downAtStop: Bool = false, tap: Int = 160_000,
                       noPermission: Bool = false, noDevice: Bool = false, silent: Double = 0,
                       discarded: Bool = false) -> MicOutageReport.Input {
        .init(outages: outages, outageSeconds: seconds, micDownAtStop: downAtStop, tapSamples: tap,
              noPermission: noPermission, noInputDevice: noDevice, silentRunSeconds: silent, discarded: discarded)
    }

    func testAMacWithNoInputDeviceIsNotNagged() {
        XCTAssertNil(MicOutageReport.wording(input(outages: 1, seconds: 3600, downAtStop: true, tap: 0, noDevice: true)))
    }

    func testAPermissionOffFromTheStartIsANoteWithTheWordPermission() {
        let w = MicOutageReport.wording(input(outages: 1, seconds: 3600, downAtStop: true, tap: 0, noPermission: true))
        XCTAssertEqual(w?.note.contains("permission"), true)
        XCTAssertNil(w?.title, "a Mac whose permission is simply off gets the note, not a card per meeting")
        let d = MicOutageReport.wording(input(outages: 1, seconds: 60, downAtStop: true, tap: 0,
                                              noPermission: true, discarded: true))
        XCTAssertEqual(d?.note.contains("not kept"), true)
    }

    /// v16 P2: revoked at minute ten, the mic had produced — the report still
    /// says "permission", so the menu bar routes its click to the Privacy pane.
    func testAPermissionRevokedMidMeetingIsACardWithTheWordPermission() {
        let w = MicOutageReport.wording(input(outages: 1, seconds: 1800, downAtStop: true, noPermission: true))
        XCTAssertEqual(w?.note.contains("permission"), true)
        XCTAssertNotNil(w?.title)
        XCTAssertEqual(w?.body?.contains("brought back"), false)
    }

    func testABlipStaysInTheLog() {
        XCTAssertNil(MicOutageReport.wording(input(outages: 1, seconds: 1.5)))
    }

    func testAnOutagePastTheFloorIsACardThatSaysItCameBack() {
        let w = MicOutageReport.wording(input(outages: 2, seconds: 12.4))
        XCTAssertEqual(w?.note, "⚠️ Mic input was down 12s during this meeting — your side is missing for that stretch")
        XCTAssertEqual(w?.body?.contains("2 times for 12s in total and was brought back"), true)
    }

    func testAMicStillDownAtStopIsNotCalledBack() {
        let w = MicOutageReport.wording(input(outages: 1, seconds: 2, downAtStop: true))
        XCTAssertEqual(w?.body?.contains("had not come back"), true, "down at stop past one second is reported")
        XCTAssertNil(MicOutageReport.wording(input(outages: 1, seconds: 0.5, downAtStop: true)))
    }

    func testAMicThatNeverProducedIsReportedRegardlessOfTheFloor() {
        let w = MicOutageReport.wording(input(outages: 1, seconds: 0.5, downAtStop: true, tap: 0))
        XCTAssertEqual(w?.title, "No microphone input during the meeting")
    }

    func testADiscardedRecordingSaysNothingWasKept() {
        let w = MicOutageReport.wording(input(outages: 1, seconds: 20, downAtStop: true, discarded: true))
        XCTAssertEqual(w?.title, "Recording discarded — microphone was down")
        XCTAssertEqual(w?.body?.contains("not kept"), true)
        XCTAssertEqual(w?.note.contains("your side is missing"), false, "there is no transcript to be missing from")
    }

    /// v18 P2: a two-second device change at the start must not mute the
    /// fifty-minute silent run that followed.
    func testABlipDoesNotMuteTheSilentRunNote() {
        let w = MicOutageReport.wording(input(outages: 1, seconds: 1.5, silent: 50 * 60))
        XCTAssertEqual(w?.note.contains("no signal for 50 min"), true)
        XCTAssertNil(w?.title)
    }

    func testLongSpansReadAsMinutes() {
        XCTAssertEqual(MicOutageReport.span(12.4), "12s")
        XCTAssertEqual(MicOutageReport.span(3000), "50 min")
        let w = MicOutageReport.wording(input(outages: 1, seconds: 3000, downAtStop: true))
        XCTAssertEqual(w?.note.contains("down 50 min"), true)
    }

    func testASilentRunBelowTheFloorStaysInTheLog() {
        XCTAssertNil(MicOutageReport.wording(input(silent: MicOutageReport.silentRunFloorSeconds - 1)))
    }

    /// v17 P2: a headset with silence suppression produces the same zeros
    /// while its wearer listens — the run is a note worded as an observation,
    /// never a card.
    func testASilentRunPastTheFloorIsANoteNotACard() {
        let w = MicOutageReport.wording(input(silent: 50 * 60))
        XCTAssertEqual(w?.note, "⚠️ Mic input carried no signal for 50 min of this meeting — if you weren't muted, check the input device")
        XCTAssertNil(w?.title)
    }

    func testAnOutageAndASilentRunAreBothTold() {
        let w = MicOutageReport.wording(input(outages: 1, seconds: 10, silent: 10 * 60))
        XCTAssertEqual(w?.body?.contains("brought back"), true)
        XCTAssertEqual(w?.body?.contains("10 min after having worked"), true)
    }

    /// v17 P2: the system says the permission is off, yet audio was still
    /// arriving at stop — the card must not claim the user's side is missing.
    func testAPermissionOffWithAudioStillArrivingDoesNotClaimALoss() {
        let w = MicOutageReport.wording(input(outages: 1, seconds: 0, downAtStop: true, noPermission: true))
        XCTAssertEqual(w?.body?.contains("missing"), true)
        var i = input(outages: 1, seconds: 0, downAtStop: true, noPermission: true); i.audioAtStop = true
        let a = MicOutageReport.wording(i)
        XCTAssertEqual(a?.note.contains("permission"), true)
        XCTAssertEqual(a?.body?.contains("missing"), false)
        XCTAssertEqual(a?.body?.contains("still arriving"), true)
    }

    /// The other half of the contract: every permission wording MUST carry
    /// 🎤, or a revoked-permission banner dead-ends with no way to the
    /// Privacy pane (independent review, v22).
    func testEveryPermissionWordingRoutesToPrivacy() {
        var revokedWithAudio = input(outages: 1, seconds: 0, downAtStop: true, noPermission: true)
        revokedWithAudio.audioAtStop = true
        let permissionCases: [MicOutageReport.Input] = [
            input(outages: 1, seconds: 3600, downAtStop: true, tap: 0, noPermission: true),
            input(outages: 1, seconds: 60, downAtStop: true, tap: 0, noPermission: true, discarded: true),
            input(outages: 1, seconds: 1800, downAtStop: true, noPermission: true),
            revokedWithAudio,
        ]
        for i in permissionCases {
            XCTAssertEqual(MicOutageReport.wording(i)?.note.contains("🎤"), true,
                           "a permission wording must open the Privacy pane")
        }
    }

    /// The menu bar routes a note carrying 🎤 to the Privacy pane and
    /// nothing else: only the permission wordings may carry it.
    func testOnlyThePermissionWordingsRouteToPrivacy() {
        let others: [MicOutageReport.Input] = [
            input(outages: 2, seconds: 12), input(outages: 1, seconds: 2, downAtStop: true),
            input(outages: 1, seconds: 0.5, downAtStop: true, tap: 0),
            input(outages: 1, seconds: 20, downAtStop: true, discarded: true), input(silent: 3000),
        ]
        for i in others {
            let note = MicOutageReport.wording(i)?.note ?? ""
            XCTAssertFalse(note.isEmpty)
            XCTAssertFalse(note.contains("🎤"), "\(note) must not route to Privacy")
        }
    }
}

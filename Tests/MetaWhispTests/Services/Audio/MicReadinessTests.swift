import XCTest
@testable import MetaWhisp

/// A dictation's microphone is judged by the clock. A capture that never delivers, or stops delivering, sends no
/// buffer to judge it by — and the owner's headset dictations ended as "0 samples, too short" with nothing said
/// (2026-10-13: three dictations, three empty recordings).
final class MicReadinessTests: XCTestCase {

    /// A fresh bind has a second to deliver its first buffer; the built-in microphone delivers in a few dozen
    /// milliseconds.
    func testAFreshBindHasASecondToDeliver() {
        XCTAssertEqual(judge(sinceBind: 0.9), .fine)
        XCTAssertEqual(judge(sinceBind: 1.0), .rebind)
    }

    /// A Bluetooth headset first brings up its call link.
    func testABluetoothHeadsetHasLongerToBringUpItsLink() {
        XCTAssertEqual(judge(sinceBind: 2.4, bluetooth: true), .fine)
        XCTAssertEqual(judge(sinceBind: 2.5, bluetooth: true), .rebind)
    }

    /// Silence is still buffers: a bind that keeps delivering is fine however long the recording runs.
    func testADeliveringBindIsLeftAlone() {
        XCTAssertEqual(judge(sinceBind: 300, sinceLastBuffer: 0.1), .fine)
        XCTAssertEqual(judge(sinceBind: 300, sinceLastBuffer: 1.4), .fine)
    }

    /// A bind that delivered and then sent nothing has stopped.
    func testAStreamThatStopsIsBoundAgain() {
        XCTAssertEqual(judge(sinceBind: 300, sinceLastBuffer: 1.5), .rebind)
    }

    /// The ceiling: one more bind per recording, then the user is told — every following check says the same and
    /// never binds again.
    func testOneRebindThenTheUserIsTold() {
        XCTAssertEqual(judge(sinceBind: 1.0, rebindsSpent: 1), .tellUser)
        XCTAssertEqual(judge(sinceBind: 300, sinceLastBuffer: 10, rebindsSpent: 1), .tellUser)
        XCTAssertEqual(judge(sinceBind: 300, sinceLastBuffer: 10, rebindsSpent: 5), .tellUser)
    }

    /// A recording that lost its microphone with nothing bringing it back (a follow failed or gave up) needs no
    /// deadline: it is bound again at once, and after that the user is told.
    func testARecordingWithoutAMicrophoneActsAtOnce() {
        XCTAssertEqual(MicReadiness.judge(bound: false, sinceBind: 0, sinceLastBuffer: nil, bluetooth: false,
                                          rebindsSpent: 0), .rebind)
        XCTAssertEqual(MicReadiness.judge(bound: false, sinceBind: 0, sinceLastBuffer: 0.1, bluetooth: false,
                                          rebindsSpent: 1), .tellUser)
    }

    /// A dictation is seconds long: an answer after it has ended is no answer. Buffers arrive every few
    /// milliseconds, so a second without one is not a hiccup.
    func testTheDeadlinesFitADictation() {
        XCTAssertLessThanOrEqual(MicReadiness.firstBufferSeconds(bluetooth: true), 3)
        XCTAssertLessThanOrEqual(MicReadiness.stalledAfterSeconds, 2)
        XCTAssertGreaterThanOrEqual(MicReadiness.firstBufferSeconds(bluetooth: false), 0.5)
        XCTAssertGreaterThanOrEqual(MicReadiness.stalledAfterSeconds, 1)
        XCTAssertLessThan(MicReadiness.checkEverySeconds, MicReadiness.firstBufferSeconds(bluetooth: false))
    }

    private func judge(sinceBind: Double, sinceLastBuffer: Double? = nil, bluetooth: Bool = false,
                       rebindsSpent: Int = 0) -> MicReadiness.Verdict {
        MicReadiness.judge(bound: true, sinceBind: sinceBind, sinceLastBuffer: sinceLastBuffer,
                           bluetooth: bluetooth, rebindsSpent: rebindsSpent)
    }
}

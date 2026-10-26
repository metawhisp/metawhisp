import IOKit.pwr_mgt
import XCTest
@testable import MetaWhisp

/// ITER-076 B1 — while an errand runs the Mac does not sleep on idle (owner
/// decision 12 of 2026-09-26): one IOKit assertion, held once and released
/// once.
@MainActor
final class KeepAwakeTests: XCTestCase {

    private final class Calls {
        var created = 0
        var released: [IOPMAssertionID] = []
        var refuseNext = false
    }

    private func keepAwake(_ calls: Calls) -> KeepAwake {
        KeepAwake(create: {
            calls.created += 1
            if calls.refuseNext {
                calls.refuseNext = false
                return nil
            }
            return IOPMAssertionID(40 + calls.created)
        }, release: { calls.released.append($0) })
    }

    func testOneAssertionIsHeldAndReleasedOnce() {
        let calls = Calls()
        let awake = keepAwake(calls)
        awake.hold()
        awake.hold()
        XCTAssertTrue(awake.isHeld)
        XCTAssertEqual(calls.created, 1, "a second hold keeps the first assertion")
        awake.release()
        awake.release()
        XCTAssertFalse(awake.isHeld)
        XCTAssertEqual(calls.released, [41], "released once, the one that was made")
    }

    /// A refused assertion is not held, so there is nothing to release, and
    /// the next hold asks again.
    func testARefusedAssertionIsNotHeldAndIsAskedForAgain() {
        let calls = Calls()
        calls.refuseNext = true
        let awake = keepAwake(calls)
        awake.hold()
        XCTAssertFalse(awake.isHeld)
        awake.release()
        XCTAssertEqual(calls.released, [])
        awake.hold()
        XCTAssertTrue(awake.isHeld)
        XCTAssertEqual(calls.created, 2)
    }

    /// The real one: the system holds an assertion that keeps the Mac from
    /// idle sleep, and it is gone once released.
    func testTheSystemAssertionPreventsIdleSleepUntilReleased() throws {
        let id = try XCTUnwrap(KeepAwake.systemCreate())
        let held = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any]
        KeepAwake.systemRelease(id)
        XCTAssertEqual(held?[kIOPMAssertionTypeKey] as? String, kIOPMAssertionTypePreventUserIdleSystemSleep)
        XCTAssertEqual(held?[kIOPMAssertionLevelKey] as? Int, Int(kIOPMAssertionLevelOn))
        XCTAssertNil(IOPMAssertionCopyProperties(id)?.takeRetainedValue(), "released")
    }
}

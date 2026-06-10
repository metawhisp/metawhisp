import XCTest
@testable import MetaWhisp

/// LIC-1 — pins the cached-Pro grace TTL: with the flag off behaviour is
/// unchanged; with it on, a cached Pro expires after the TTL and a never-verified
/// (planted) key is never trusted.
final class LicenseEntitlementTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private typealias E = LicenseEntitlement

    func testNoKey_neverTrusted() {
        XCTAssertFalse(E.cachedProIsTrusted(hasActiveKey: false, lastVerifiedAt: now, now: now, enforce: false))
        XCTAssertFalse(E.cachedProIsTrusted(hasActiveKey: false, lastVerifiedAt: now, now: now, enforce: true))
    }

    func testFlagOff_keyIsEnough() {
        // Default behaviour: a present key is trusted regardless of verification age.
        XCTAssertTrue(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: nil, now: now, enforce: false))
        let ancient = now.addingTimeInterval(-99 * 24 * 3600)
        XCTAssertTrue(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: ancient, now: now, enforce: false))
    }

    func testFlagOn_neverVerifiedFailsClosed() {
        XCTAssertFalse(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: nil, now: now, enforce: true))
    }

    func testFlagOn_freshIsTrusted() {
        let recent = now.addingTimeInterval(-3600)  // 1h ago
        XCTAssertTrue(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: recent, now: now, enforce: true))
    }

    func testFlagOn_staleExpires() {
        let stale = now.addingTimeInterval(-(73 * 3600))  // 73h ago > 72h TTL
        XCTAssertFalse(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: stale, now: now, enforce: true))
    }

    func testFlagOn_boundaryIsExpired() {
        // Exactly at the TTL counts as expired (strict `<`).
        let atTTL = now.addingTimeInterval(-E.defaultGraceTTL)
        XCTAssertFalse(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: atTTL, now: now, enforce: true))
        let justInside = now.addingTimeInterval(-(E.defaultGraceTTL - 1))
        XCTAssertTrue(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: justInside, now: now, enforce: true))
    }

    func testCustomTTL() {
        let twoHoursAgo = now.addingTimeInterval(-2 * 3600)
        XCTAssertTrue(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: twoHoursAgo, now: now, ttl: 3 * 3600, enforce: true))
        XCTAssertFalse(E.cachedProIsTrusted(hasActiveKey: true, lastVerifiedAt: twoHoursAgo, now: now, ttl: 1 * 3600, enforce: true))
    }
}

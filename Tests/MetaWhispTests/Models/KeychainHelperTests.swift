import Security
import XCTest
@testable import MetaWhisp

/// ITER-075 step 0, US-0.4 — "not there" and "there but unreadable" are
/// different answers, and a write never deletes before it has written.
final class KeychainHelperTests: XCTestCase {

    /// A keychain in memory that records every call and can be told to fail.
    private final class FakeKeychain: KeychainBackend {
        var items: [String: Data] = [:]
        var copyStatus: OSStatus?
        var updateStatus: OSStatus?
        var calls: [String] = []

        func copy(service: String, account: String) -> (OSStatus, Data?) {
            calls.append("copy \(account)")
            if let copyStatus { return (copyStatus, nil) }
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }

        func add(service: String, account: String, data: Data) -> OSStatus {
            calls.append("add \(account)")
            guard items[account] == nil else { return errSecDuplicateItem }
            items[account] = data
            return errSecSuccess
        }

        func update(service: String, account: String, data: Data) -> OSStatus {
            calls.append("update \(account)")
            if let updateStatus { return updateStatus }
            guard items[account] != nil else { return errSecItemNotFound }
            items[account] = data
            return errSecSuccess
        }

        func delete(service: String, account: String) -> OSStatus {
            calls.append("delete \(account)")
            return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private var fake: FakeKeychain!

    override func setUp() {
        super.setUp()
        fake = FakeKeychain()
        KeychainHelper.backend = fake
    }

    override func tearDown() {
        KeychainHelper.backend = KeychainHelper.defaultBackend
        fake = nil
        super.tearDown()
    }

    func testAReadTellsMissingFromUnreadable() {
        fake.items["k"] = Data("v".utf8)
        XCTAssertEqual(KeychainHelper.read("k"), .value("v"))
        XCTAssertEqual(KeychainHelper.read("absent"), .notFound)
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            fake.copyStatus = status
            XCTAssertEqual(KeychainHelper.read("k"), .failed(status))
            XCTAssertNil(KeychainHelper.load(key: "k"), "load keeps its contract: nil when there is no readable value")
        }
    }

    func testAWriteUpdatesInPlaceAndNeverDeletesFirst() {
        fake.items["k"] = Data("old".utf8)
        XCTAssertEqual(KeychainHelper.save(key: "k", value: "new"), errSecSuccess)
        XCTAssertEqual(fake.items["k"], Data("new".utf8))
        XCTAssertFalse(fake.calls.contains("delete k"))
    }

    /// The 2026-09-25 loss: the keychain refused, the delete went through and
    /// the add did not. A refused write must leave the old value in place.
    func testARefusedWriteLeavesTheOldValue() {
        fake.items["k"] = Data("old".utf8)
        fake.updateStatus = errSecAuthFailed
        XCTAssertEqual(KeychainHelper.save(key: "k", value: "new"), errSecAuthFailed)
        XCTAssertEqual(fake.items["k"], Data("old".utf8))
        XCTAssertFalse(fake.calls.contains("delete k"))
    }

    func testAWriteAddsAMissingItem() {
        XCTAssertEqual(KeychainHelper.save(key: "k", value: "v"), errSecSuccess)
        XCTAssertEqual(fake.calls, ["update k", "add k"])
        XCTAssertEqual(fake.items["k"], Data("v".utf8))
    }

    func testAnEmptyValueDeletesAndAMissingItemCountsAsDeleted() {
        fake.items["k"] = Data("v".utf8)
        XCTAssertEqual(KeychainHelper.save(key: "k", value: ""), errSecSuccess)
        XCTAssertNil(fake.items["k"])
        XCTAssertEqual(KeychainHelper.save(key: "k", value: ""), errSecSuccess)
    }

    /// Tests must never reach the user's real keychain.
    func testTheTestRunnerGetsAnEmptyKeychain() {
        XCTAssertTrue(KeychainHelper.defaultBackend is EmptyKeychain)
    }
}

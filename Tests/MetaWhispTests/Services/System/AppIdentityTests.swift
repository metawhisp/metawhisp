import SwiftData
import XCTest
@testable import MetaWhisp

/// ITER-075 step 0, US-0.1 — a test build must never read or write the
/// owner's data, and the owner's app must keep every value it has today.
final class AppIdentityTests: XCTestCase {

    func testTheProductionAppKeepsTodaysValues() {
        let id = AppIdentity(bundleIdentifier: "com.metawhisp.app")
        XCTAssertEqual(id.flavor, .production)
        XCTAssertEqual(id.supportFolderName, "MetaWhisp")
        XCTAssertEqual(id.storeName, "MetaWhisp")
        XCTAssertEqual(id.keychainService, "com.metawhisp.secrets")
        XCTAssertEqual(id.logFileName, "MetaWhisp.log")
        XCTAssertEqual(id.urlScheme, "metawhisp")
    }

    func testEveryOtherBundleSharesNothingWithProduction() {
        let production = AppIdentity(bundleIdentifier: "com.metawhisp.app")
        let others: [String?] = ["com.metawhisp.app.dev", nil, "", "com.apple.dt.xctest.tool", "com.metawhisp.app.extra"]
        for bundle in others {
            let other = AppIdentity(bundleIdentifier: bundle)
            let label = bundle ?? "nil"
            XCTAssertEqual(other.flavor, .dev, label)
            XCTAssertNotEqual(other.supportFolderName, production.supportFolderName, label)
            XCTAssertNotEqual(other.storeName, production.storeName, label)
            XCTAssertNotEqual(other.keychainService, production.keychainService, label)
            XCTAssertNotEqual(other.logFileName, production.logFileName, label)
            XCTAssertNotEqual(other.urlScheme, production.urlScheme, label)
        }
    }

    /// The test runner is not the owner's app, so tests never open the
    /// owner's store, keychain service or log.
    func testTheTestRunnerIsNeverTheProductionApp() {
        XCTAssertEqual(AppIdentity.current.flavor, .dev)
    }

    func testPathsFollowTheIdentity() {
        let base = URL(fileURLWithPath: "/tmp/mw-identity-test", isDirectory: true)
        let production = AppIdentity(bundleIdentifier: "com.metawhisp.app")
        XCTAssertEqual(production.supportDirectory(applicationSupport: base).path, "/tmp/mw-identity-test/MetaWhisp")
        XCTAssertEqual(production.storeURL(applicationSupport: base).path, "/tmp/mw-identity-test/MetaWhisp.store")
        let dev = AppIdentity(bundleIdentifier: "com.metawhisp.app.dev")
        XCTAssertEqual(dev.supportDirectory(applicationSupport: base).path, "/tmp/mw-identity-test/MetaWhisp Dev")
        XCTAssertEqual(dev.storeURL(applicationSupport: base).path, "/tmp/mw-identity-test/MetaWhisp Dev.store")
    }

    /// SwiftData keeps a named store at `<Application Support>/<name>.store`.
    /// The backup of an unopenable store relies on `storeURL` naming that same
    /// file — for both apps, the Dev name's space included.
    func testTheStoreURLIsWhereSwiftDataKeepsTheNamedStore() throws {
        let schema = Schema(versionedSchema: MetaWhispSchemaV9.self)
        let appSupport = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        for bundle in ["com.metawhisp.app", "com.metawhisp.app.dev"] {
            let id = AppIdentity(bundleIdentifier: bundle)
            XCTAssertEqual(ModelConfiguration(id.storeName, schema: schema).url.standardizedFileURL,
                           id.storeURL(applicationSupport: appSupport).standardizedFileURL, bundle)
        }
    }

    /// ITER-075 step 0 (0.4) — only the owner's app updates itself, listens to
    /// global keys by default, and may delete the shared speech and LLM models.
    func testOnlyTheOwnersAppUpdatesItselfTakesGlobalKeysAndDeletesSharedModels() {
        let production = AppIdentity(bundleIdentifier: "com.metawhisp.app")
        XCTAssertTrue(production.updatesItself)
        XCTAssertTrue(production.globalInputByDefault)
        XCTAssertTrue(production.mayDeleteSharedModels)
        let dev = AppIdentity(bundleIdentifier: "com.metawhisp.app.dev")
        XCTAssertFalse(dev.updatesItself)
        XCTAssertFalse(dev.globalInputByDefault)
        XCTAssertFalse(dev.mayDeleteSharedModels)
    }
}

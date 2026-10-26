import Foundation

/// Everything that makes this copy of MetaWhisp a separate app from another
/// copy on the same Mac: where its data lives, which keychain service holds
/// its secrets, its log file and its sign-in URL scheme.
///
/// Only the exact production bundle id keeps today's values. Any other
/// bundle id — a test runner, an unbundled `swift run`, a copy built under
/// another bundle id — gets values of its own, so it can never read or write the owner's store,
/// secrets or log (ITER-075 step 0, US-0.1). Preferences and privacy grants
/// already follow the bundle id and need nothing here.
struct AppIdentity: Equatable {
    enum Flavor: Equatable { case production, dev }

    static let productionBundleID = "com.metawhisp.app"

    let flavor: Flavor
    /// Folder in Application Support: models, recovery audio, queues, the MCP snapshot.
    let supportFolderName: String
    /// SwiftData store name; SwiftData keeps it as `<name>.store` in Application Support.
    let storeName: String
    /// The keychain service that holds every secret this app saves.
    let keychainService: String
    /// Log file in ~/Library/Logs; the previous generation adds ".1".
    let logFileName: String
    /// Scheme of the sign-in deep link.
    let urlScheme: String

    init(bundleIdentifier: String?) {
        if bundleIdentifier == Self.productionBundleID {
            flavor = .production
            supportFolderName = "MetaWhisp"
            storeName = "MetaWhisp"
            keychainService = "com.metawhisp.secrets"
            logFileName = "MetaWhisp.log"
            urlScheme = "metawhisp"
        } else {
            flavor = .dev
            supportFolderName = "MetaWhisp Dev"
            storeName = "MetaWhisp Dev"
            keychainService = "com.metawhisp.dev.secrets"
            logFileName = "MetaWhisp Dev.log"
            urlScheme = "metawhisp-dev"
        }
    }

    /// The identity of the running app.
    static let current = AppIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)

    /// Only the owner's app updates itself: a Dev build never replaces itself
    /// through Sparkle (ITER-075 step 0, 0.4).
    var updatesItself: Bool { flavor == .production }
    /// Global hotkeys and the layout fix start on only in the owner's app, so
    /// two copies never answer the same Right ⌘ press or rewrite the same word.
    var globalInputByDefault: Bool { flavor == .production }
    /// Installs from before 1.4 keep the speech and local-LLM models in a
    /// folder shared with every other copy (~/Documents/huggingface, see
    /// `ModelFolder`); only the owner's app may delete them there.
    var mayDeleteSharedModels: Bool { flavor == .production }

    /// `<applicationSupport>/<supportFolderName>`. Not created here.
    func supportDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(supportFolderName, isDirectory: true)
    }

    /// `<applicationSupport>/<storeName>.store`, where SwiftData keeps the named store.
    func storeURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(storeName + ".store")
    }

    /// `~/Library/Application Support/<supportFolderName>`. Not created here.
    var supportDirectory: URL {
        supportDirectory(applicationSupport: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!)
    }
}

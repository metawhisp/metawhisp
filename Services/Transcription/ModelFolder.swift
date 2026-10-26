import Foundation

/// C5 / F1 — where this install keeps the models it downloads, the speech
/// models and the local LLM's weights alike, in the Hugging Face layout
/// (`<base>/models/<repo>/…`).
///
/// Every install up to 1.3.37 used the libraries' default,
/// `~/Documents/huggingface`, and macOS asks before an app touches the
/// Documents folder: a new user met that prompt on the welcome screen, before
/// any button. A new install keeps its models in its own Application Support
/// folder. An install that may already have models in Documents keeps that
/// folder; nothing is moved or deleted. Which one is decided once and stored —
/// in the defaults and, so a reset of the defaults cannot change it, in a
/// marker file in this copy's support folder.
struct ModelFolder: Equatable {
    enum Kind: String { case documents, applicationSupport }

    let kind: Kind
    /// The download base WhisperKit and the Hub are given.
    let base: URL

    init(kind: Kind, home: URL, supportDirectory: URL) {
        self.kind = kind
        switch kind {
        case .documents: base = home.appendingPathComponent("Documents/huggingface", isDirectory: true)
        case .applicationSupport: base = Self.ownModelFolder(in: supportDirectory)
        }
    }

    /// `<support folder>/huggingface`, this copy's own model folder. No build
    /// before 1.4 wrote there (they all used ~/Documents/huggingface), so
    /// finding it is evidence of a 1.4 install that chose it.
    static func ownModelFolder(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("huggingface", isDirectory: true)
    }

    /// One folder per speech model variant.
    var speechModels: URL {
        base.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// The Documents folder is shared with every other copy of MetaWhisp on
    /// the Mac; an Application Support folder belongs to its copy alone.
    var isShared: Bool { kind == .documents }

    static let choiceKey = "modelFolder_iter076"

    /// Keys only an earlier launch writes: onboarding finished, a model picked
    /// or downloaded, an engine chosen — and one that every launch since May
    /// 2026 writes. Any of them means models may sit in Documents already.
    static let earlierLaunchKeys = ["hasCompletedOnboarding", "selectedModel", "pendingBestModelUpgrade",
                                    "transcriptionEngine", "didAutoPromoteProcessingMode_iter034"]

    /// What an earlier launch leaves that a reset of the defaults does not
    /// take away: this copy's support folder and its SwiftData store (step-1
    /// review #2). Nothing inside ~/Documents is looked at — that look is the
    /// prompt this folder exists to avoid.
    static func earlierLaunchFiles(identity: AppIdentity = .current,
                                   applicationSupport: URL = FileManager.default
                                       .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> [URL] {
        [identity.supportDirectory(applicationSupport: applicationSupport),
         identity.storeURL(applicationSupport: applicationSupport)]
    }

    /// The choice kept outside the defaults (round-2 N1): a reset of the
    /// defaults takes the stored value away, and the support folder this
    /// install's own first launch made would then read as an earlier
    /// install's — its models would vanish. `<support folder>/model-folder`,
    /// holding the kind's raw value.
    static func marker(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("model-folder")
    }

    /// This copy's marker — none under XCTest, so no test writes into a
    /// copy's support folder; tests pass a marker of their own.
    static let defaultMarker: URL? = NSClassFromString("XCTestCase") != nil
        ? nil : marker(in: AppIdentity.current.supportDirectory)

    /// The kind this install keeps. Read in this order: the defaults' stored
    /// value, the marker, this copy's own model folder (→ its own folder), an
    /// earlier launch's traces (→ documents), otherwise a new install (→ its
    /// own folder). What is decided is kept in both places, whichever of them
    /// was missing it, and its own folder, when chosen, is made at once. `Launch.main` makes the first call before the app
    /// exists — before anything writes the keys above or creates the files —
    /// so this launch's own traces are never taken for an earlier launch's.
    @discardableResult
    static func chooseOnce(in defaults: UserDefaults, marker: URL? = defaultMarker,
                           ownModels: URL = ownModelFolder(in: AppIdentity.current.supportDirectory),
                           earlierLaunchFiles files: [URL] = earlierLaunchFiles()) -> Kind {
        let marked = marker.flatMap(readMarker)
        let kind: Kind
        if let stored = defaults.string(forKey: choiceKey).flatMap(Kind.init(rawValue:)) {
            kind = stored
        } else if let marked {
            kind = marked
            NSLog("[ModelFolder] the defaults lost the choice — the marker keeps %@", kind.rawValue)
        } else if FileManager.default.fileExists(atPath: ownModels.path) {
            // The marker is missing or corrupt too; the support folder alone
            // would read as an earlier install's and hide these models.
            kind = .applicationSupport
            NSLog("[ModelFolder] the choice was lost — this copy's own model folder is there: kept")
        } else {
            let earlier = earlierLaunchKeys.contains { defaults.object(forKey: $0) != nil }
                || files.contains { FileManager.default.fileExists(atPath: $0.path) }
            kind = earlier ? .documents : .applicationSupport
            NSLog("[ModelFolder] %@ — models in %@", earlier ? "an install from before 1.4" : "a new install",
                  earlier ? "~/Documents/huggingface, as before" : "its Application Support folder")
        }
        if defaults.string(forKey: choiceKey) != kind.rawValue { defaults.set(kind.rawValue, forKey: choiceKey) }
        if let marker, marked != kind { writeMarker(kind, to: marker) }
        // Round-3 N1-P2 — the own folder is made with the choice, not with the
        // first download: an install that loses its defaults and its marker
        // before any download still shows its folder (the third check above).
        // Only where a marker is kept: under XCTest none is, so no test writes
        // into a copy's support folder.
        if kind == .applicationSupport, marker != nil, !FileManager.default.fileExists(atPath: ownModels.path) {
            do {
                try FileManager.default.createDirectory(at: ownModels, withIntermediateDirectories: true)
            } catch {
                NSLog("[ModelFolder] ⚠️ the own model folder was not made (%@) — the marker still keeps the choice",
                      error.localizedDescription)
            }
        }
        return kind
    }

    /// nil when the marker is missing, unreadable or holds anything else.
    private static func readMarker(_ url: URL) -> Kind? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Kind(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func writeMarker(_ kind: Kind, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(kind.rawValue.utf8).write(to: url, options: .atomic)
        } catch {
            NSLog("[ModelFolder] ⚠️ the choice is not kept outside the defaults (%@) — a reset of the defaults decides again",
                  error.localizedDescription)
        }
    }

    /// The running app's folder.
    static let current = ModelFolder(kind: chooseOnce(in: .standard),
                                     home: FileManager.default.homeDirectoryForCurrentUser,
                                     supportDirectory: AppIdentity.current.supportDirectory)
}

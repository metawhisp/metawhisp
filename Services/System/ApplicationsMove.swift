import AppKit

/// PRD P1 15 — "Move MetaWhisp to Applications?" when the owner's build runs from anywhere else: the disk image,
/// Downloads, or the read-only copy macOS translocates a quarantined app to. It is asked first at launch, before
/// anything asks for a permission, so the grants go to the copy that stays; and Sparkle can update only a copy it can
/// replace. "Move and Open" copies the app to /Applications and opens that copy once this one has quit; "Not now" keeps
/// this launch as it is and is remembered for this copy's location — the question comes back only for a copy run
/// from another location outside Applications. A move that fails says so in one plain line, and this copy runs on.
@MainActor
enum ApplicationsMove {
    static let question = "Move MetaWhisp to Applications?"
    static let moveAndOpen = "Move and Open"
    static let notNow = "Not now"
    static let failed = "Couldn't move MetaWhisp. Drag it to Applications in Finder."

    /// The folder it moves to, and the name it gets there.
    nonisolated static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    nonisolated static let appName = "MetaWhisp.app"

    /// Where "Not now" was answered, in the app's defaults.
    nonisolated static let declinedKey = "moveToApplicationsDeclinedLocation"

    /// A copy's location, as "Not now" remembers it: its path — except that macOS runs a quarantined copy from a new
    /// random folder at every launch (App Translocation), so those launches are one location, or each would ask
    /// again. Which folder such a copy came from is not told to the app.
    nonisolated static func location(of bundle: URL) -> String {
        let path = bundle.standardizedFileURL.path
        return path.contains("/AppTranslocation/") ? "a translocated copy" : path
    }

    /// "Not now": this copy's location is remembered for the next launch.
    nonisolated static func rememberNotNow(for bundle: URL, in defaults: UserDefaults) {
        defaults.set(location(of: bundle), forKey: declinedKey)
    }

    nonisolated static func declinedLocation(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: declinedKey)
    }

    /// Whether to ask: the owner's build — a Dev copy never asks — running outside the Mac's and the user's
    /// Applications folders, with no other copy of it running (replacing the bundle under a running app is not this
    /// question's to do), and not from the location where "Not now" was answered — another location asks again. A
    /// launch a link opened (a sign-in coming back, `LinkInbox`) is not asked: a move ends the launch, and the link
    /// with it; the question comes at a later launch.
    nonisolated static func shouldOffer(bundle: URL, identity: AppIdentity, home: URL, anotherCopyRuns: Bool,
                                        declined: String? = nil, openedByLink: Bool = false) -> Bool {
        guard identity.flavor == .production, !anotherCopyRuns, !openedByLink else { return false }
        guard declined != location(of: bundle) else { return false }
        let path = bundle.standardizedFileURL.path
        let folders = [applications.path, home.appendingPathComponent("Applications").path].map { $0 + "/" }
        return !folders.contains { path.hasPrefix($0) }
    }

    /// Copies `app` into `applications` as MetaWhisp.app, replacing the copy there, and returns where it went. The
    /// copy is made beside the destination and put in place by one rename or replace, so a move cut short leaves the
    /// installed app whole. The copy carries no quarantine: macOS would otherwise run it translocated, read-only,
    /// with its grants and its updates elsewhere. The original is left where it is.
    nonisolated static func move(_ app: URL, into applications: URL) throws -> URL {
        let fileManager = FileManager.default
        let destination = applications.appendingPathComponent(appName, isDirectory: true)
        let staged = applications.appendingPathComponent(".\(appName).moving-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.copyItem(at: app, to: staged)
            removeQuarantine(under: staged)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
        return destination
    }

    /// Drops the quarantine attribute from every item of a bundle this app just copied: its own, already opened.
    nonisolated private static func removeQuarantine(under bundle: URL) {
        var items = [bundle.path]
        if let walker = FileManager.default.enumerator(atPath: bundle.path) {
            for case let relative as String in walker { items.append(bundle.appendingPathComponent(relative).path) }
        }
        for path in items { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
    }

    /// The name the reopening shell runs under: `sh -c SCRIPT NAME A B` binds NAME to `$0`, A to `$1`, B to `$2`.
    /// Without it the process id became `$0` and the path `$1`, so the shell waited for nothing and opened "" — the
    /// moved copy never opened (Codex, 1.4.0 review).
    nonisolated static let reopenShellName = "metawhisp-reopen"

    /// The shell that opens the moved copy once this process has quit: the process id (`$1`) and the path (`$2`) are
    /// its arguments, never part of its script.
    nonisolated static func reopenArguments(pid: Int32, app: URL) -> [String] {
        ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
         reopenShellName, String(pid), app.path]
    }

    static func questionAlert() -> NSAlert {
        CurrentSpaceAlert.make(question, buttons: [moveAndOpen, notNow])
    }

    static func failureAlert() -> NSAlert {
        CurrentSpaceAlert.make(failed, buttons: ["OK"])
    }

    /// The launch's first step: asks when it should, and moves on "Move and Open". True when this launch ends — the
    /// moved copy opens once it has quit; then the caller sets nothing up. `openedByLink`: whether a link has come
    /// this launch (`LinkInbox`) — read before asking and again after the answer, so a link that comes while the
    /// question is up keeps this launch too. Put off, the question remembers nothing: a later launch asks.
    static func offerAtLaunch(openedByLink: () -> Bool) -> Bool {
        let bundle = Bundle.main.bundleURL
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        let linked = openedByLink()
        func offers(openedByLink: Bool) -> Bool {
            shouldOffer(bundle: bundle, identity: .current, home: FileManager.default.homeDirectoryForCurrentUser,
                        anotherCopyRuns: others, declined: declinedLocation(in: .standard), openedByLink: openedByLink)
        }
        guard offers(openedByLink: linked) else {
            if linked, offers(openedByLink: false) {
                NSLog("[Move] this launch was opened by a link — the move is asked at a later launch")
            }
            return false
        }
        NSLog("[Move] running outside Applications (%@) — asking to move", bundle.path)
        guard CurrentSpaceAlert.ask(questionAlert()) == 0 else {
            NSLog("[Move] Not now — this launch stays where it is, and this location is not asked about again")
            rememberNotNow(for: bundle, in: .standard)
            return false
        }
        guard !openedByLink() else {
            NSLog("[Move] a link came while asking — this launch stays for it, and the move is asked at a later launch")
            return false
        }
        let moved: URL
        do {
            moved = try move(bundle, into: applications)
        } catch {
            NSLog("[Move] ❌ the move failed: %@", error.localizedDescription)
            _ = CurrentSpaceAlert.ask(failureAlert())
            return false
        }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = reopenArguments(pid: ProcessInfo.processInfo.processIdentifier, app: moved)
        do {
            try reopen.run()
        } catch {
            // The copy is in Applications; the next launch opens it from there.
            NSLog("[Move] moved to %@, but it could not be opened (%@) — this copy runs on", moved.path,
                  error.localizedDescription)
            return false
        }
        NSLog("[Move] ✅ moved to %@ — quitting so it opens there", moved.path)
        NSApp.terminate(nil)
        return true
    }
}

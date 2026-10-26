import Foundation

/// The agent's tabs not known to be closed (ITER-076 stage 9d, № 21, № 23):
/// each one's id in the browser, on disk from the moment the browser made it
/// until its close is confirmed — so a tab that a crash, a sleep or a failed
/// close left open is still the agent's to close, on the next connection
/// (`ChromeBridge.closeStrayTabs`). Ids only — no address, no title, no word
/// of an errand — so it sits beside the errand records, not among them:
/// clearing MetaChat clears the user's errands, and a tab listed here is
/// still the agent's to close. Owner-only, like the records.
@MainActor
final class AgentTabLedger {
    let file: URL

    /// `file`: for tests; the app's `AgentTabs.json` otherwise.
    init(file: URL? = nil) {
        self.file = file ?? AppIdentity.current.supportDirectory.appendingPathComponent("AgentTabs.json")
    }

    /// The tabs listed, in the order they were made.
    var open: [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    /// The browser made tab `id`.
    func opened(_ id: String) {
        let listed = open
        guard !listed.contains(id) else { return }
        write(listed + [id])
    }

    /// Tab `id` is gone — or not the agent's to close any more.
    func closed(_ id: String) {
        let listed = open
        guard listed.contains(id) else { return }
        write(listed.filter { $0 != id })
    }

    /// Writes the list — or, once it is empty, leaves no file. A list that
    /// cannot be written is logged by its error code; the errand goes on.
    private func write(_ ids: [String]) {
        let fm = FileManager.default
        do {
            if ids.isEmpty {
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                return
            }
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(ids).write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            NSLog("[AgentTabLedger] ❌ not written — error %d", (error as NSError).code)
        }
    }
}

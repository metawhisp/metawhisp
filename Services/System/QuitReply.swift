import AppKit

/// The app's one answer to a quit that waits (ITER-076 stage 9d, № 20): the
/// agent's stopped runs closing their tabs and a meeting's rescue are one wait.
/// Each part ends once — done, or out of its time — and the answer goes once,
/// when the last part has ended. With nothing to wait for, the app quits at
/// once.
@MainActor
final class QuitReply {
    private let schedule: AgentService.Schedule
    private let send: @MainActor () -> Void
    /// The parts not ended yet, by number.
    private var waiting: Set<Int> = []
    private var parts = 0
    private var sent = false

    /// `send`: the answer — `NSApp.reply(toApplicationShouldTerminate: true)`
    /// in the app. `schedule`: runs each part's limit.
    init(schedule: @escaping AgentService.Schedule = AgentService.afterDelay, send: @escaping @MainActor () -> Void) {
        self.schedule = schedule
        self.send = send
    }

    /// What `applicationShouldTerminate` answers: now when it waits for
    /// nothing, later otherwise.
    var answer: NSApplication.TerminateReply { parts == 0 ? .terminateNow : .terminateLater }

    /// One more part to wait for, `limit` at most: calling what this returns
    /// ends it; a second call, or one past the limit, does nothing. Each part
    /// holds the reply until it ends.
    func wait(within limit: Duration) -> @MainActor () -> Void {
        let part = parts
        parts += 1
        waiting.insert(part)
        let end: @MainActor () -> Void = { self.end(part) }
        schedule(limit, end)
        return end
    }

    private func end(_ part: Int) {
        guard waiting.remove(part) != nil, waiting.isEmpty, !sent else { return }
        sent = true
        send()
    }
}

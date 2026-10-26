import Combine
import Foundation
import Sparkle

/// An update never cuts a running errand short (ITER-074 §11, ITER-076 stage
/// 9d, № 209): Sparkle asks before it relaunches the app to install, and the
/// relaunch waits for the errand's end — at most the errand's own ceiling,
/// 31 minutes — then goes. Meanwhile nothing new starts and the waiting
/// errands end as not started (`AgentService.updateIsReady`). An update that
/// does not happen lets errands start again. Sparkle may not ask — its quit
/// then comes through `applicationShouldTerminate`, which stops the errand
/// and waits for its tab — and keeps this delegate weakly: the app holds it.
@MainActor
final class UpdateGate: NSObject {
    private let service: AgentService
    private let schedule: AgentService.Schedule
    /// Sparkle's install, while it waits for the errand.
    private var install: (() -> Void)?
    private var watch: AnyCancellable?

    init(service: AgentService, schedule: @escaping AgentService.Schedule = AgentService.afterDelay) {
        self.service = service
        self.schedule = schedule
    }

    /// Whether the install's relaunch waits: while an errand runs, until it
    /// ends or `AgentService.ceiling` passes, then `install` goes, once. From
    /// here on nothing new starts, as the update's quit comes either way.
    func postpone(until install: @escaping () -> Void) -> Bool {
        service.updateIsReady()
        guard service.errandRunning else { return false }
        self.install = install
        watch = service.$errandRunning.sink { [weak self] running in
            if !running { self?.letGo() }
        }
        schedule(AgentService.ceiling) { [weak self] in self?.letGo() }
        return true
    }

    /// Sparkle's update ended without the app's quit: it failed, or it was
    /// put off. Errands start again; a wait set for it installs nothing.
    func updateEnded() {
        install = nil
        watch = nil
        service.updateWithdrawn()
    }

    private func letGo() {
        guard let install else { return }
        self.install = nil
        watch = nil
        install()
    }
}

extension UpdateGate: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postpone(until: installHandler)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        updateEnded()
    }
}

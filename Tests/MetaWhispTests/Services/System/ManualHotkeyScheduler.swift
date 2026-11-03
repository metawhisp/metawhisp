import Foundation

/// The timer queue and wall clock advance together, without waiting in real time.
@MainActor
final class ManualHotkeyScheduler {
    private struct Scheduled {
        let deadline: TimeInterval
        let sequence: Int
        let work: DispatchWorkItem
    }

    private var pending: [Scheduled] = []
    private var nextSequence = 0
    private(set) var time: TimeInterval = 0
    var now: Date { Date(timeIntervalSinceReferenceDate: time) }

    func schedule(after delay: TimeInterval, work: DispatchWorkItem) {
        pending.append(Scheduled(deadline: time + delay, sequence: nextSequence, work: work))
        nextSequence += 1
        pending.sort {
            $0.deadline == $1.deadline ? $0.sequence < $1.sequence : $0.deadline < $1.deadline
        }
    }

    func advance(by duration: TimeInterval) {
        advance(to: time + duration)
    }

    func advance(to target: TimeInterval) {
        precondition(target >= time, "The manual clock cannot move backwards")
        while let next = pending.first, next.deadline <= target {
            pending.removeFirst()
            time = next.deadline
            if !next.work.isCancelled { next.work.perform() }
        }
        time = target
    }
}

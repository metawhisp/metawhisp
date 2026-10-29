import Combine
import Foundation

/// Audio-rate values never travel through the answer state or its hosting view.
@MainActor
final class MeetingCoachWaveModel: ObservableObject {
    static let shared = MeetingCoachWaveModel()
    @Published private(set) var bars: [CGFloat] = []
    private var lastPublication: TimeInterval?
    private var subscription: AnyCancellable?
    private var pending: (me: Float, them: Float, speaker: MeetingCoachSpeaker)?
    private var trailing: Task<Void, Never>?
    private let inputQueue = DispatchQueue(label: "meeting-coach-wave-input")
    private(set) var mainInputDeliveryCount = 0

    func bind(me: AnyPublisher<Float, Never>, them: AnyPublisher<Float, Never>, state: MeetingCoachState) {
        subscription = Publishers.CombineLatest3(me, them, state.speakerModel.$speaker)
            .throttle(for: .milliseconds(50), scheduler: inputQueue, latest: true)
            .receive(on: RunLoop.main)
            .sink { [weak self] me, them, speaker in
                guard let self else { return }
                self.mainInputDeliveryCount += 1
                self.receive(me: me, them: them, speaker: speaker, at: ProcessInfo.processInfo.systemUptime)
            }
    }

    func receive(me: Float, them: Float, speaker: MeetingCoachSpeaker, at now: TimeInterval) {
        pending = (me, them, speaker)
        if let lastPublication, now - lastPublication + 0.000000001 < 0.05 {
            if trailing == nil {
                let delay = max(0, 0.05 - (now - lastPublication))
                trailing = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self, let pending = self.pending else { return }
                    self.trailing = nil
                    self.receive(me: pending.me, them: pending.them, speaker: pending.speaker,
                                 at: ProcessInfo.processInfo.systemUptime)
                }
            }
            return
        }
        trailing?.cancel()
        trailing = nil
        pending = nil
        let level: Float
        switch speaker {
        case .me: level = me
        case .them: level = them
        case .both: level = max(me, them)
        case .quiet, .unavailable: level = 0
        }
        let next: [CGFloat] = speaker == .unavailable ? [] : [0.35, 0.8, 1, 0.55, 0.9, 0.4].map {
            2 + CGFloat(min(1, max(0, level))) * 12 * $0
        }
        guard next != bars else { return }
        lastPublication = now
        bars = next
    }
}

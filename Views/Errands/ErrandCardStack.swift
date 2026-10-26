import AppKit
import Combine
import Foundation

/// What an errand card's buttons ask of the errand service. The service
/// decides what each did; the card shows only what it then says.
@MainActor
protocol ErrandCardService: AnyObject {
    func stop(_ id: UUID)
    func stopAll()
    @discardableResult
    func answer(_ id: UUID, to request: ConfirmationRequest, _ answer: ConfirmationRequest.Answer) -> Bool
    @discardableResult
    func proceed(_ id: UUID, after pause: ErrandPause) -> Bool
    @discardableResult
    func showTab(_ id: UUID) -> Bool
}

extension AgentService: ErrandCardService {}

/// One card per errand (ITER-076 I-11), from the errand service's events, in
/// the order the errands came: shown top-right in the notification column
/// (`MWNotificationStackController`), above the notification cards. A card
/// updates in place while its errand runs and never fades; once the errand
/// ended it can be closed, and closes by itself after a notification card's
/// lifetime, which hovering pauses. Cards live in memory only: a relaunched
/// app shows none. Its log lines hold an errand's id and the card's kind only.
@MainActor
final class ErrandCardStack: ObservableObject {
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    static let shared = ErrandCardStack()

    /// How long an ended errand's card stays: a notification card's lifetime
    /// (`MWNotificationStack`).
    static let endedLifetime: TimeInterval = 6

    @Published private(set) var cards: [ErrandCard] = []

    private let schedule: Schedule
    private var service: (any ErrandCardService)?
    private var openSheet: @MainActor (URL) -> Void = { _ in }
    private var openResult: @MainActor (UUID) -> Void = { _ in }
    private var subscription: AnyCancellable?
    /// Each ended card's close, by the token of the timer that may still do
    /// it: a newer timer, or the cursor over the card, voids an older one.
    private var closing: [UUID: UUID] = [:]

    init(schedule: @escaping Schedule = ErrandCardStack.afterDelay) {
        self.schedule = schedule
    }

    /// Shows every errand `events` tells of; the buttons go to `service`, the
    /// Sheet's address to `openSheet`, and MetaChat's result to `openResult`.
    func observe(_ events: AnyPublisher<ErrandUpdate, Never>, service: any ErrandCardService,
                 openSheet: @escaping @MainActor (URL) -> Void, openResult: @escaping @MainActor (UUID) -> Void) {
        self.service = service
        self.openSheet = openSheet
        self.openResult = openResult
        // The service publishes on the main actor.
        subscription = events.sink { [weak self] update in
            MainActor.assumeIsolated { self?.show(update) }
        }
    }

    /// A button of errand `id`'s card. Only a button the card offers now does
    /// anything: a click on a question that closed answers nothing.
    func press(_ action: ErrandCard.Action, on id: UUID) {
        guard let card = cards.first(where: { $0.id == id }), card.buttons.contains(where: { $0.action == action })
        else { return }
        switch action {
        case .stop: service?.stop(id)
        case .stopAll: service?.stopAll()
        case .yes: card.question.map { _ = service?.answer(id, to: $0, .yes) }
        case .no: card.question.map { _ = service?.answer(id, to: $0, .no) }
        case .openSheet: card.sheet.map(openSheet)
        case .openInMetaChat: openResult(id)
        case .proceed: card.pause.map { _ = service?.proceed(id, after: $0) }
        case .showTab: _ = service?.showTab(id)
        }
    }

    /// Closes errand `id`'s card, once its errand ended.
    func close(_ id: UUID) {
        guard cards.contains(where: { $0.id == id && $0.hasEnded }) else { return }
        remove(id, why: "closed")
    }

    /// The cursor over an ended card keeps it; leaving starts its time again.
    func setHovering(_ hovering: Bool, id: UUID) {
        guard cards.contains(where: { $0.id == id && $0.hasEnded }) else { return }
        if hovering { closing[id] = nil } else { armClose(id) }
    }

    // MARK: - Private

    private func show(_ update: ErrandUpdate) {
        var next = cards
        if let index = next.firstIndex(where: { $0.id == update.id }) {
            let wasEnded = next[index].hasEnded
            next[index] = next[index].showing(update.event)
            if !wasEnded, next[index].hasEnded {
                NSLog("%@ card ended: %@", ErrandRecord.logPrefix(update.id), next[index].label)
                armClose(update.id)
            }
        } else if case .amended = update.event {
            // Its card was closed: a Sheet that came late does not bring it back.
            return
        } else {
            let card = ErrandCard(id: update.id).showing(update.event)
            next.append(card)
            NSLog("%@ card shown: %@", ErrandRecord.logPrefix(update.id), card.label)
            if card.hasEnded { armClose(update.id) }
        }
        cards = Self.inQueueOrder(next)
    }

    /// The service tells a waiting errand its place at once and a started one
    /// a moment later (its first event is where the browser stands): the
    /// errands that run or ran keep the order they came in, and the line
    /// follows them by place.
    private static func inQueueOrder(_ cards: [ErrandCard]) -> [ErrandCard] {
        cards.filter { $0.placeInLine == nil }
            + cards.filter { $0.placeInLine != nil }.sorted { $0.placeInLine! < $1.placeInLine! }
    }

    private func armClose(_ id: UUID) {
        let token = UUID()
        closing[id] = token
        schedule(Self.endedLifetime) { [weak self] in
            guard let self, self.closing[id] == token else { return }
            self.remove(id, why: "timed out")
        }
    }

    private func remove(_ id: UUID, why: String) {
        closing[id] = nil
        cards.removeAll { $0.id == id }
        NSLog("%@ card gone: %@", ErrandRecord.logPrefix(id), why)
    }

    /// Runs `action` on the main actor once `seconds` have passed.
    nonisolated static func afterDelay(_ seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            action()
        }
    }
}

extension Notification.Name {
    /// ITER-076 I-11 — MetaChat scrolls to a message. `object: UUID` = the
    /// message's id.
    static let metaChatShowMessage = Notification.Name("MetaWhisp.metaChatShowMessage")
}

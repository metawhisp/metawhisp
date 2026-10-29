import Foundation

/// One terminal event wins against the whole-request deadline.
enum MeetingCardStreamEvent {
    case reply(MeetingAnswerStreamEvent)
    case deadline
}

@MainActor
enum MeetingAnswerStreamReader {
    static func bounded(_ source: AsyncStream<MeetingAnswerStreamEvent>, deadlineMs: Int,
                        sleep: @escaping @MainActor @Sendable (Int) async throws -> Void)
        -> AsyncStream<MeetingCardStreamEvent> {
        AsyncStream { continuation in
            let reader = Task {
                for await event in source {
                    guard !Task.isCancelled else { return }
                    continuation.yield(.reply(event))
                    if case .end = event {
                        continuation.finish()
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                continuation.yield(.reply(.end(.init(status: 500, retryAfter: nil, text: nil))))
                continuation.finish()
            }
            let timer = Task {
                do {
                    try await sleep(deadlineMs)
                    try Task.checkCancellation()
                    continuation.yield(.deadline)
                    continuation.finish()
                } catch {}
            }
            continuation.onTermination = { _ in
                reader.cancel()
                timer.cancel()
            }
        }
    }
}

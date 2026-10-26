import Foundation

/// ITER-075 step 1 (1.6) — what one run of `StructuredGenerator.generate` did,
/// so a caller can tell a result from a run that never happened.
enum StructuredOutcome: Equatable {
    /// A result was written: the LLM's fields, or the short-transcript placeholder.
    case written
    /// Nothing to change: already structured, a short transcript beside a real
    /// title, or the conversation is gone.
    case unchanged
    /// Not run, or turned away by the service: no LLM access or no key, no
    /// network, a refused key, a missing model, a throttled or unavailable
    /// service (ITER-075 step 1, 1.5). Try again later.
    case notNow
    /// Run, and nothing usable came back for this conversation: an unreadable
    /// answer, a timeout, or a request refused as it was.
    case failed
}

import Foundation

/// ITER-075 step 1 (1.5) — runs take turns, first come first served. Each run
/// starts once the one handed in before it has finished, whatever that one
/// returned.
///
/// The structured generator guarded on `isRunning` and returned, so a
/// conversation that closed while another summary was being written was
/// dropped, and nothing ran it again. The local model's generations already
/// wait for their predecessor (`LocalLLMService.pendingGeneration`); this is
/// the same chain.
@MainActor
final class RunTurns<Result: Sendable> {
    private var last: Task<Result, Never>?

    /// Waits for every run handed in before this one, then runs `body`.
    func take(_ body: @escaping @MainActor () async -> Result) async -> Result {
        let previous = last
        let mine = Task { @MainActor in
            _ = await previous?.value
            return await body()
        }
        last = mine
        return await mine.value
    }
}

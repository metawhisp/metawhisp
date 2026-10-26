import Combine
import Foundation

/// ITER-075 step 1 (1.5) — says when cloud LLM access is ready to use: at
/// launch, and each time the setup changes to one that can work (Pro turned
/// on, a key entered or changed, another provider picked). The summaries that
/// wait for access run then; they used to wait for the next conversation to
/// close, or the next launch.
///
/// A key is saved on every keystroke, so it speaks only once the settings have
/// been quiet for a moment, and a setup it already announced stays quiet.
enum CloudAccessTrigger {
    /// - Parameters:
    ///   - changes: anything that may change the setup.
    ///   - setup: the setup now; nil without cloud access.
    ///   - quietFor: how long the settings must stay unchanged first.
    static func publisher(changes: AnyPublisher<Void, Never>,
                          setup: @escaping () -> String?,
                          quietFor: RunLoop.SchedulerTimeType.Stride = .seconds(2),
                          scheduler: RunLoop = .main) -> AnyPublisher<String, Never> {
        changes
            .debounce(for: quietFor, scheduler: scheduler)
            .map { _ in setup() }
            .removeDuplicates()
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }
}

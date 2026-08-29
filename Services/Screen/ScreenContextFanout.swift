import Foundation

/// ITER-064A.4 — one captured context, two independent consumers.
///
/// The task reactor and the proactive path both want every new context, and
/// neither needs the other's result. They used to be chained inside one task:
/// the reactor was awaited first, and its model call can take 20 seconds, so
/// the proactive path did not even start looking at a context until the task
/// classifier was finished with it.
///
/// Named here rather than inlined at the wiring site so the independence is a
/// property that a test can hold onto.
@MainActor
enum ScreenContextFanout {

    /// Stage 2.1-bis — a forced re-read reaches neither consumer.
    ///
    /// The ceiling on the picture gate exists so that an hour spent reading one
    /// document is not a hole in screen history. It does not mean anything
    /// happened: the pixels are the same ones both consumers already saw. Waking
    /// them here would buy a model call every ceiling interval for a window
    /// nobody touched, which is the cost the gate was added to avoid, arriving
    /// through the fix for the gate.
    static func dispatch(
        _ ctx: ScreenContext,
        isForcedReread: Bool = false,
        toTaskReactor reactor: @escaping @MainActor (ScreenContext) async -> Void,
        toProactive proactive: @escaping @MainActor (ScreenContext) -> Void
    ) {
        guard !isForcedReread else { return }
        Task { @MainActor in await reactor(ctx) }
        Task { @MainActor in proactive(ctx) }
    }
}

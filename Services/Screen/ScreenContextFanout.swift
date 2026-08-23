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

    static func dispatch(
        _ ctx: ScreenContext,
        toTaskReactor reactor: @escaping @MainActor (ScreenContext) async -> Void,
        toProactive proactive: @escaping @MainActor (ScreenContext) -> Void
    ) {
        Task { @MainActor in await reactor(ctx) }
        Task { @MainActor in proactive(ctx) }
    }
}

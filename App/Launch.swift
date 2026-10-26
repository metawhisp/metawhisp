import Foundation

/// The app's entry point. `MetaWhisp --self-check`, the release smoke test
/// (ITER-075 step 0, US-0.2), runs and exits here, before the app exists: no
/// delegate, store, keychain, log, network, capture or window. Anything else
/// settles where the models live (`ModelFolder`) and starts the app.
@main
@MainActor
enum Launch {
    static func main() {
        if SelfCheck.isRequested(CommandLine.arguments) {
            SelfCheck.runAndExit()
        }
        ExceptionPolicy.register(in: .standard)
        // F1 — where this install keeps its models, decided before the app
        // exists: its first steps create the store and the support folder the
        // choice reads as an earlier launch's.
        ModelFolder.chooseOnce(in: .standard)
        MetaWhispApp.main()
    }
}

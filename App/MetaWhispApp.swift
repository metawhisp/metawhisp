import SwiftUI

@main
struct MetaWhispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window (Cmd+,)
        Settings {
            MainSettingsView(modelManager: appDelegate.modelManager)
                .frame(width: 500, height: 550)
        }
    }
}

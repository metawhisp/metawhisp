import SwiftUI

@main
struct MetaWhispApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings are in the main window sidebar tab.
        // This invisible Settings scene intercepts Cmd+, and redirects to the main window.
        Settings {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear {
                    // Close this empty settings window and open main window instead
                    DispatchQueue.main.async {
                        NSApp.keyWindow?.close()
                        appDelegate.openMainWindow(tab: .settings)
                    }
                }
        }
    }
}

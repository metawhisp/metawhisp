import SwiftUI

/// Root view for the popover — thin wrapper around MenuBarView.
struct PopoverRootView: View {
    @ObservedObject var coordinator: TranscriptionCoordinator
    @ObservedObject var recorder: AudioRecordingService
    let closePopover: () -> Void
    var openMainWindow: () -> Void = {}

    var body: some View {
        MenuBarView(
            coordinator: coordinator,
            recorder: recorder,
            closePopover: closePopover,
            openMainWindow: openMainWindow
        )
    }
}

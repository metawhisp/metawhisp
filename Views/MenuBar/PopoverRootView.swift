import SwiftUI

/// Root view for the popover — thin wrapper around MenuBarView.
struct PopoverRootView: View {
    @ObservedObject var coordinator: TranscriptionCoordinator
    @ObservedObject var recorder: AudioRecordingService
    @ObservedObject var meetingRecorder: MeetingRecorder
    @ObservedObject var screenContext: ScreenContextService
    @ObservedObject var dailySummary: DailySummaryService
    let closePopover: () -> Void
    var openMainWindow: () -> Void = {}
    var onMeetingToggle: () -> Void = {}

    var body: some View {
        MenuBarView(
            coordinator: coordinator,
            recorder: recorder,
            meetingRecorder: meetingRecorder,
            screenContext: screenContext,
            dailySummary: dailySummary,
            closePopover: closePopover,
            openMainWindow: openMainWindow,
            onMeetingToggle: onMeetingToggle
        )
    }
}

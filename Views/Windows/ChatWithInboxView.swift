import SwiftUI

/// MetaChat with its Inbox beside it.
///
/// ITER-067 puts the Screen Agent's comments where the conversation already
/// is, rather than adding a new top-level place to check. A comment that was
/// held back — the user was in a meeting, or had paused, or had already had one
/// recently — is still here to read afterwards, which is what separates quiet
/// hours from silently throwing the work away.
struct ChatWithInboxView: View {

    private enum Pane: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case inbox = "Inbox"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .chat

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            switch pane {
            case .chat: ChatView()
            case .inbox: ScreenAgentInboxView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenAgentShowChatPane)) { _ in
            pane = .chat
        }
        .onReceive(NotificationCenter.default.publisher(for: .screenAgentShowInboxPane)) { _ in
            pane = .inbox
        }
        .onAppear {
            // A clicked card asked for a specific comment — land on the Inbox
            // rather than dropping the user into an unrelated chat.
            if AppDelegate.shared?.pendingScreenAgentItemID != nil { pane = .inbox }
        }
    }
}

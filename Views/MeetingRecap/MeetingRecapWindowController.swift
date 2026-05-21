import AppKit
import Combine
import SwiftUI

/// Manages the per-meeting recap popup window (2026-04-29).
/// Borderless non-activating panel anchored to top-center of the main screen.
/// Auto-dismiss after 60 sec if user doesn't interact, or on explicit close.
@MainActor
final class MeetingRecapWindowController {
    private var window: NSPanel?
    private var hostingView: ClickThroughHostingView<MeetingRecapView>?
    private var visibilityCancellable: AnyCancellable?
    private var autoDismissTask: Task<Void, Never>?

    init() {
        visibilityCancellable = MeetingRecapState.shared.$isVisible
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible { self?.show() } else { self?.hide() }
            }
    }

    private func show() {
        if window == nil { createWindow() }
        guard let window else { return }
        if !window.isVisible {
            positionTopCenter(window)
            window.orderFrontRegardless()
            armAutoDismiss()
        }
    }

    private func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        window?.orderOut(nil)
    }

    private func createWindow() {
        let view = MeetingRecapView(
            state: MeetingRecapState.shared,
            onCopy: { [weak self] in self?.handleCopy() },
            onOpenInLibrary: { [weak self] in self?.handleOpenInLibrary() },
            onDismiss: { MeetingRecapState.shared.dismiss() },
            onToggleTask: { [weak self] id in self?.handleToggleTask(id) }
        )
        let hosting = ClickThroughHostingView(rootView: view)
        // 480pt pill + 96pt shadow envelope (48 each side, see
        // MeetingRecapView.recapPill `.padding(48)`). Vertical bumped from 540
        // → 700 to accommodate dense recap content (header + about + with +
        // decisions + next steps + memories + actions bar can be ~520pt)
        // PLUS the 96pt shadow padding without Spacers collapsing to 0.
        // 2026-05-12 — fixes the clipped shadow visible in user screenshot.
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        hosting.autoresizingMask = [.width, .height]
        // 48-pt transparent shadow padding around the card → click-through.
        hosting.shadowInset = 48

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting

        self.window = panel
        self.hostingView = hosting
    }

    private func positionTopCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 24  // slight gap from menu bar
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Auto-dismiss after 60 sec if user doesn't engage. Cancelled on hover
    /// (TODO v2) and on explicit dismiss.
    private func armAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            MeetingRecapState.shared.dismiss()
            self?.autoDismissTask = nil
        }
    }

    // MARK: - Actions

    private func handleCopy() {
        guard let p = MeetingRecapState.shared.payload else { return }
        var text = ""
        if !p.title.isEmpty { text += "\(p.title)\n" }
        if !p.overview.isEmpty { text += "\n\(p.overview)\n" }
        if !p.actionItems.isEmpty {
            text += "\nAction items:\n"
            for item in p.actionItems {
                let mark = item.completed ? "[x]" : "[ ]"
                let suffix = item.assignee.map { " (waiting on \($0))" } ?? ""
                text += "  \(mark) \(item.description)\(suffix)\n"
            }
        }
        if !p.memories.isEmpty {
            text += "\nMemories:\n"
            for mem in p.memories {
                if let s = mem.subject, !s.isEmpty,
                   let c = mem.characterization, !c.isEmpty {
                    text += "  • \(s) — \(c)\n"
                } else {
                    text += "  • \(mem.content)\n"
                }
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSLog("[MeetingRecap] copied %d chars to clipboard", text.count)
    }

    private func handleOpenInLibrary() {
        guard let app = AppDelegate.shared, let p = MeetingRecapState.shared.payload else { return }
        // Tell the main window to show the just-finished conversation.
        app.openConversationInLibrary(id: p.conversationId)
        MeetingRecapState.shared.dismiss()
    }

    private func handleToggleTask(_ id: UUID) {
        guard let app = AppDelegate.shared else { return }
        MeetingRecapState.shared.toggleTask(id, in: app.historyService.modelContainer)
    }
}

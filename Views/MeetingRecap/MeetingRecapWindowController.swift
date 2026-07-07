import AppKit
import Combine
import SwiftUI

/// Manages the per-meeting recap popup window (2026-04-29).
/// Borderless non-activating panel anchored to top-center of the main screen.
/// Auto-dismiss after 60 sec if user doesn't interact, or on explicit close.
///
/// **Two-window design (ITER-050 B2.2 — same pattern as MeetingCoach /
/// FloatingVoice).** The card window is sized exactly to the visible recap
/// card (interactive — Copy / Open in Library / task checkboxes work); the
/// shadow child window renders only the drop shadow with
/// `ignoresMouseEvents = true`, so everything around the card clicks through.
/// Replaces `ClickThroughHostingView`, whose runtime click-through toggle
/// left the whole panel permanently non-interactive.
@MainActor
final class MeetingRecapWindowController {
    private var cardWindow: NSPanel?
    private var shadowWindow: NSPanel?
    private var shadowView: CardShadowView?
    private var hostingView: SelfSizingHostingView<MeetingRecapView>?
    private var visibilityCancellable: AnyCancellable?
    private var autoDismissTask: Task<Void, Never>?

    /// 2·radius 32 + |y| 16 = 80 — no-clip envelope for the recap shadow.
    private let shadowPadding: CGFloat = 80

    init() {
        visibilityCancellable = MeetingRecapState.shared.$isVisible
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] visible in
                if visible { self?.show() } else { self?.hide() }
            }
    }

    private func show() {
        if cardWindow == nil { createWindows() }
        guard let cardWindow, let shadowWindow else { return }
        if !cardWindow.isVisible {
            positionTopCenter(cardWindow)
            cardWindow.orderFrontRegardless()
            if cardWindow.childWindows?.contains(shadowWindow) != true {
                cardWindow.addChildWindow(shadowWindow, ordered: .below)
            }
            updateShadowFrame()
            armAutoDismiss()
        }
    }

    private func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        cardWindow?.orderOut(nil)
        if let shadowWindow, shadowWindow.isVisible,
           cardWindow?.childWindows?.contains(shadowWindow) != true {
            shadowWindow.orderOut(nil)
        }
    }

    private func createWindows() {
        let view = MeetingRecapView(
            state: MeetingRecapState.shared,
            onCopy: { [weak self] in self?.handleCopy() },
            onOpenInLibrary: { [weak self] in self?.handleOpenInLibrary() },
            onDismiss: { MeetingRecapState.shared.dismiss() },
            onToggleTask: { [weak self] id in self?.handleToggleTask(id) }
        )
        let hosting = SelfSizingHostingView(rootView: view)
        hosting.onContentSizeChange = { [weak self] size in
            self?.updateCardSize(size)
        }
        self.hostingView = hosting

        // Card window — exactly the visible 480pt-wide card. Interactive;
        // non-activating so buttons never steal focus.
        let card = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        card.isOpaque = false
        card.backgroundColor = .clear
        card.hasShadow = false  // shadow lives in the child window
        card.level = .floating
        card.collectionBehavior = MWWindowBehavior.overlay
        card.ignoresMouseEvents = false
        card.hidesOnDeactivate = false
        card.isMovableByWindowBackground = true   // drag the card to reposition
        card.contentView = hosting

        // Shadow window — child, below the card, transparent to mouse events.
        let shadowFrame = card.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        let shadow = NSPanel(
            contentRect: shadowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let shadowContent = CardShadowView(
            frame: NSRect(origin: .zero, size: shadowFrame.size),
            inset: shadowPadding,
            cornerRadius: MW.rLarge,   // recap card's corner radius
            shadowRadius: 32,
            shadowOpacity: 0.4,
            shadowYOffset: 16
        )
        shadow.isOpaque = false
        shadow.backgroundColor = .clear
        shadow.hasShadow = false
        shadow.level = card.level
        shadow.collectionBehavior = card.collectionBehavior
        shadow.ignoresMouseEvents = true
        shadow.hidesOnDeactivate = false
        shadow.isMovableByWindowBackground = false
        shadow.contentView = shadowContent

        card.addChildWindow(shadow, ordered: .below)

        self.cardWindow = card
        self.shadowWindow = shadow
        self.shadowView = shadowContent

        hosting.layoutSubtreeIfNeeded()
        hosting.reportCurrentSize()
    }

    /// Resize the card window to the measured content, keeping the top edge
    /// and horizontal center anchored (recap grows downward), then resync the
    /// shadow. Height clamped defensively — a degenerate measurement must not
    /// produce a giant or invisible card.
    private func updateCardSize(_ size: CGSize) {
        guard let cardWindow, size.width > 0, size.height > 0 else { return }
        let newSize = NSSize(
            width: ceil(min(max(size.width, 480), 520)),
            height: ceil(min(max(size.height, 160), 640))
        )
        var frame = cardWindow.frame
        guard abs(frame.width - newSize.width) > 0.5 ||
              abs(frame.height - newSize.height) > 0.5 else { return }
        let top = frame.maxY
        frame.origin.x = frame.midX - newSize.width / 2
        frame.origin.y = top - newSize.height
        frame.size = newSize
        cardWindow.setFrame(frame, display: true)
        updateShadowFrame()
    }

    private func updateShadowFrame() {
        guard let cardWindow, let shadowWindow else { return }
        let frame = cardWindow.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding)
        shadowWindow.setFrame(frame, display: true)
        shadowView?.frame = NSRect(origin: .zero, size: frame.size)
        shadowView?.needsLayout = true
    }

    private func positionTopCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        if let host = hostingView {
            host.layoutSubtreeIfNeeded()
            host.reportCurrentSize()
        }
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

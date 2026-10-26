import SwiftData
import SwiftUI

/// Chat with your own memories + transcripts + tasks.
/// Mirrors Chat tab (minimal MVP — text only, no voice/files/sharing).
/// spec://BACKLOG#B2
struct ChatView: View {
    @Query(sort: \ChatMessage.createdAt, order: .forward) private var messages: [ChatMessage]
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var license = LicenseService.shared
    /// The Screen Agent comment this conversation is about, if any.
    @State private var anchor: ScreenAgentThreadAnchor?
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var errorMsg: String?
    @FocusState private var inputFocused: Bool

    @ObservedObject private var localLLM = LocalLLMService.shared
    /// The errand cards (ITER-076 stage 8b, 8.9): a running errand typed here shows its card's lines and buttons.
    @ObservedObject private var errandCards = ErrandCardStack.shared

    /// ITER-047 Element B / ITER-051 F1.5 — chat unlocks via key, Pro, OR a
    /// ready local model (matches ChatService.hasLLMAccess).
    private var hasLLMAccess: Bool {
        LLMAccess.hasForChat(apiKey: settings.activeAPIKey, isPro: license.isPro,
                             localReady: localLLM.isReady)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !hasLLMAccess { LLMAccessBar() }
            header
            Rectangle().fill(MW.border).frame(height: MW.hairline)

            if messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            Rectangle().fill(MW.border).frame(height: MW.hairline)
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { inputFocused = true }
        // ITER-015 — accept pre-fill from the proactive chip (tap on item).
        // After prefill, auto-submit so user gets the answer immediately
        // (matches the expected "click chip → answer" UX). Without auto-submit
        // the chip felt like a dead-end — text appeared in the input box and
        // nothing happened until the user manually pressed Enter.
        // ITER-068 — a card asked to be continued. The comment and the screen it
        // came from are pinned for this conversation; the question stays the
        // user's to write.
        .onReceive(NotificationCenter.default.publisher(for: .screenAgentAnchorChat)) { notification in
            if let anchor = notification.object as? ScreenAgentThreadAnchor {
                self.anchor = anchor
                inputFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .proactivePrefillChat)) { notification in
            if let q = notification.object as? String, !q.isEmpty {
                inputText = q
                inputFocused = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    submit()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("MetaChat")
                .font(MW.monoTitle)
                .foregroundStyle(MW.textPrimary)
            Spacer()
            if !messages.isEmpty {
                Button(action: clearHistory) {
                    Text("CLEAR")
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.textMuted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(MW.textMuted)
            Text("Talk to your second brain")
                .font(MW.monoLg)
                .foregroundStyle(MW.textSecondary)
            Text("Ask about your tasks, memories, or recent voice dictations.")
                .font(MW.mono)
                .foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            VStack(alignment: .leading, spacing: 6) {
                Text("Try:").font(MW.label).tracking(0.6).foregroundStyle(MW.textMuted)
                ForEach(Self.tryLines(errandCanStart: AgentService.shared.canStartErrands), id: \.self) { line in
                    Text(line).font(MW.monoSm).foregroundStyle(MW.textSecondary)
                }
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// What the empty MetaChat offers to try: an errand too while one can start — Pro, the agent on, a run, the
    /// owner's switch on (ITER-076 stage 8b, № 160). Plain text, never a button: an errand starts with no bubble.
    static func tryLines(errandCanStart: Bool) -> [String] {
        ["• What did I do today?", "• What are my active tasks?", "• What do I know about <project>?"]
            + (errandCanStart ? [AgentSetup.example] : [])
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { msg in
                        messageRow(msg)
                            .id(msg.id)
                    }
                    if isSending {
                        typingIndicator.id("typing")
                    }
                }
                .padding(16)
            }
            .onAppear {
                // An errand card asked for its result (ITER-076 I-11): open
                // on it. Otherwise jump to the latest message without
                // animation — onChange below only fires on subsequent count
                // changes, not initial load.
                if let asked = AppDelegate.shared?.consumePendingChatMessage() {
                    proxy.scrollTo(asked, anchor: .center)
                } else if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .metaChatShowMessage)) { notification in
                // Already on screen: the request is served here, not again on
                // the next appearance.
                _ = AppDelegate.shared?.consumePendingChatMessage()
                if let asked = notification.object as? UUID {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(asked, anchor: .center) }
                }
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: isSending) {
                if isSending {
                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: ChatMessage) -> some View {
        let isUser = msg.sender == "human"
        HStack(alignment: .top, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if let err = msg.errorText {
                    Text("Error: \(err)")
                        .font(MW.monoSm)
                        .foregroundStyle(.red.opacity(0.85))
                        .padding(10)
                        .overlay(Rectangle().stroke(Color.red.opacity(0.3), lineWidth: MW.hairline))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        // The user's own words above an errand's result, this session, with no label (ITER-076
                        // stage 8b, 8.10): shown, never saved into the message.
                        if !isUser, let asked = AppDelegate.shared?.chatService.request(ofResult: msg.id) {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "quote.opening")
                                    .font(.system(size: 10))
                                    .foregroundStyle(MW.textMuted)
                                Text(asked)
                                    .font(MW.monoSm)
                                    .foregroundStyle(MW.textMuted)
                                    .lineLimit(3)
                            }
                        }
                        if !msg.text.isEmpty {
                            Text(msg.text)
                                .font(MW.mono)
                                .foregroundStyle(MW.textPrimary)
                                .textSelection(.enabled)
                        }
                        // ITER-016 — pending tool-call confirm bubble.
                        if let preview = msg.pendingToolPreview, msg.pendingToolCallJSON != nil {
                            Divider().background(MW.border)
                            Text(preview)
                                .font(MW.monoSm)
                                .foregroundStyle(MW.textSecondary)
                            HStack(spacing: 8) {
                                Button {
                                    AppDelegate.shared?.chatService.confirmTool(messageId: msg.id)
                                } label: {
                                    Text("YES, DO IT")
                                        .font(MW.label).tracking(0.6)
                                        .foregroundStyle(MW.textPrimary)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                                Button {
                                    AppDelegate.shared?.chatService.cancelTool(messageId: msg.id)
                                } label: {
                                    Text("CANCEL")
                                        .font(MW.label).tracking(0.6)
                                        .foregroundStyle(MW.textMuted)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                            }
                        } else if let result = msg.toolResultSummary, !result.isEmpty {
                            // Tool already executed — show outcome line + (when within
                            // the 60s window) an Undo button. Wrapping in TimelineView
                            // re-evaluates `undoVisible` every 5s so the button vanishes
                            // automatically when the window expires (without a chat re-render).
                            Divider().background(MW.border)
                            TimelineView(.periodic(from: .now, by: 5)) { _ in
                                HStack(alignment: .center, spacing: 6) {
                                    Text(result)
                                        .font(MW.monoSm)
                                        .foregroundStyle(
                                            result.hasPrefix("✓") ? MW.textSecondary :
                                            result.hasPrefix("↩︎") ? MW.textMuted :
                                            Color.red.opacity(0.85)
                                        )
                                    Spacer()
                                    if undoVisible(for: msg) {
                                        Button {
                                            AppDelegate.shared?.chatService.undoTool(messageId: msg.id)
                                        } label: {
                                            Text("UNDO")
                                                .font(MW.label).tracking(0.6)
                                                .foregroundStyle(MW.textSecondary)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                    // Liquid Glass spec § 7: user bubble = accent-soft fill,
                    // AI bubble = ultraThin glass. 14 px radius for both.
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isUser ? AnyShapeStyle(MW.accentSoft) : AnyShapeStyle(.ultraThinMaterial))
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isUser ? MW.accentRim : MW.border, lineWidth: 0.5)
                    )
                    .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)
                }
                // Each errand this typed message started, while it runs: its card's lines and buttons, the same
                // card's — the first answer counts, here or in the corner (ITER-076 stage 8b, 8.9).
                if isUser {
                    ForEach(liveErrandCards(of: msg.id), id: \.id) { card in
                        ErrandLiveRow(card: card) { action in errandCards.press(action, on: card.id) }
                            .frame(maxWidth: 520, alignment: .trailing)
                    }
                }
                Text(msg.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }

    /// The cards of the errands typed message `id` started this session that have not ended.
    private func liveErrandCards(of id: UUID) -> [ErrandCard] {
        let errands = AppDelegate.shared?.chatService.errands(askedBy: id) ?? []
        return errands.compactMap { errand in errandCards.cards.first { $0.id == errand && !$0.hasEnded } }
    }

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: 8) {
            TypingDots()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .mwCard(radius: MW.rSmall, elevation: .flat)
            Spacer(minLength: 40)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 0) {
            // ITER-068 — say plainly what this conversation is anchored to, and
            // when that screen was seen. Without it the user cannot tell whether
            // an answer is about the comment or about whatever is in front of
            // them now.
            if let anchor {
                HStack(spacing: 8) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(anchor.headline)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Text("\(anchor.sourceApp) · \(ScreenAgentThreadAnchor.relativeAge(from: anchor.capturedAt, to: Date()))")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        self.anchor = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop asking about this comment")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.07))
            }
            if let err = errorMsg {
                Text(err)
                    .font(MW.monoSm)
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            HStack(spacing: 8) {
                TextField("Ask your second brain…", text: $inputText, axis: .vertical)
                    .font(MW.mono)
                    .foregroundStyle(MW.textPrimary)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(10)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    .focused($inputFocused)
                    .onSubmit { submit() }
                .accessibilityLabel("MetaChat input")

                Button(action: submit) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("SEND")
                            .font(MW.label).tracking(0.6)
                            .foregroundStyle(MW.textPrimary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                .disabled(isSending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Actions

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        inputText = ""
        NSLog("[ChatService] MetaChat send: %d chars typed, screen-agent card anchor=%@", text.count, anchor == nil ? "no" : "yes")
        // ITER-068 — the anchored comment goes with the first question only.
        // After that the conversation has its own history and repeating it
        // would just crowd the context.
        let sentAnchor = anchor
        // The card goes along with the words, never as the user's own words
        // (ITER-076 I-06: an errand's goal is checked against those alone).
        let attached = anchor?.frozenContextBlock()
        self.anchor = nil
        isSending = true
        errorMsg = nil
        Task { @MainActor in
            guard let appDelegate = AppDelegate.shared else {
                errorMsg = "ChatService not available (SwiftUI context issue)"
                isSending = false
                return
            }
            let outcome = await appDelegate.chatService.send(text, attached: attached)
            if outcome == .busy || outcome == .noAccess {
                // Nothing was sent or saved (ITER-079): the message goes back
                // to the box to send again.
                if inputText.isEmpty { inputText = text }
                if self.anchor == nil { self.anchor = sentAnchor }
                errorMsg = outcome == .busy
                    ? "Still answering a voice question. Send again in a moment."
                    : appDelegate.chatService.lastError
            } else if let err = appDelegate.chatService.lastError {
                errorMsg = err
            }
            isSending = false
        }
    }

    private func clearHistory() {
    NSLog("[ChatService] chat history cleared by user (%d messages)", messages.count)
        AppDelegate.shared?.chatService.clearHistory()
    }

    /// ITER-016 v2 — Undo button visibility:
    /// Show only when (a) message has a tool_result, (b) result wasn't already
    /// reverted (text doesn't start with ↩︎ or ✗), (c) we have a real execution
    /// timestamp, (d) within the 60s window computed against THAT timestamp
    /// (not `createdAt` — user may sit on confirm bubble for minutes).
    private func undoVisible(for msg: ChatMessage) -> Bool {
        guard let result = msg.toolResultSummary, !result.isEmpty else { return false }
        guard !result.hasPrefix("↩︎") else { return false }
        guard !result.hasPrefix("✗") else { return false }
        guard let executedAt = msg.toolExecutedAt else { return false }
        return Date().timeIntervalSince(executedAt) <= 60
    }
}

/// A running errand's card in MetaChat (ITER-076 stage 8b, 8.9): the card's own lines and buttons — never saved into
/// a message, so no model reads them. Its time left to answer follows the card's.
struct ErrandLiveRow: View {
    let card: ErrandCard
    let press: (ErrandCard.Action) -> Void

    /// The card's lines as MetaChat shows them, top to bottom: its label, source, title, body and meta.
    static func lines(of card: ErrandCard) -> [String] {
        [card.label.uppercased(), card.source, card.title, card.body, card.meta].filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(Self.lines(of: card).enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(index == 0 ? MW.label : MW.monoSm)
                    .foregroundStyle(line == card.title ? MW.textPrimary : MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if card.question != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(card.countdown(at: .now)?.time ?? "")
                        .font(MW.monoSm)
                        .foregroundStyle(MW.textMuted)
                        .id(context.date)
                }
            }
            HStack(spacing: 8) {
                ForEach(card.buttons, id: \.label) { button in
                    Button { press(button.action) } label: {
                        Text(button.label)
                            .font(MW.label).tracking(0.6)
                            .foregroundStyle(button.primary ? MW.textPrimary : MW.textSecondary)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                                .stroke(button.primary ? MW.textMuted : MW.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(MW.border, lineWidth: 0.5))
    }
}

/// ChatGPT-style 3-dot typing animation.
/// Each dot pulses in opacity + scale with a 0.2s phase offset.
private struct TypingDots: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(MW.textSecondary)
                    .frame(width: 6, height: 6)
                    .opacity(opacity(for: i))
                    .scaleEffect(scale(for: i))
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }

    /// Each dot is offset in the animation cycle by 1/3 (i.e. 0, 0.33, 0.66).
    /// Uses a sine wave so the transition between dots is smooth, not abrupt.
    private func opacity(for index: Int) -> Double {
        let offset = Double(index) / 3.0
        let t = (Double(phase) + offset).truncatingRemainder(dividingBy: 1.0)
        let wave = sin(t * .pi * 2) * 0.5 + 0.5  // 0…1
        return 0.3 + wave * 0.7
    }

    private func scale(for index: Int) -> CGFloat {
        let offset = Double(index) / 3.0
        let t = (Double(phase) + offset).truncatingRemainder(dividingBy: 1.0)
        let wave = sin(t * .pi * 2) * 0.5 + 0.5
        return 0.7 + CGFloat(wave) * 0.4  // 0.7…1.1
    }
}

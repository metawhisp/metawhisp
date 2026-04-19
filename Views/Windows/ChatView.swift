import SwiftData
import SwiftUI

/// Chat with your own memories + transcripts + tasks.
/// Mirrors Chat tab (minimal MVP — text only, no voice/files/sharing).
/// spec://BACKLOG#B2
struct ChatView: View {
    @Query(sort: \ChatMessage.createdAt, order: .forward) private var messages: [ChatMessage]
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var errorMsg: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("METACHAT")
                .font(MW.monoLg)
                .foregroundStyle(MW.textPrimary)
                .tracking(2)
            Spacer()
            if !messages.isEmpty {
                Button(action: clearHistory) {
                    Text("CLEAR")
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.textMuted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
                Text("• Что я делал сегодня?").font(MW.monoSm).foregroundStyle(MW.textSecondary)
                Text("• Какие у меня активные задачи?").font(MW.monoSm).foregroundStyle(MW.textSecondary)
                Text("• Что я знаю про Overchat?").font(MW.monoSm).foregroundStyle(MW.textSecondary)
            }
            .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
                    Text(msg.text)
                        .font(MW.mono)
                        .foregroundStyle(MW.textPrimary)
                        .padding(10)
                        .background(isUser ? MW.elevated : MW.surface)
                        .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
                        .frame(maxWidth: 520, alignment: isUser ? .trailing : .leading)
                        .textSelection(.enabled)
                }
                Text(msg.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(MW.monoSm)
                    .foregroundStyle(MW.textMuted)
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var typingIndicator: some View {
        HStack(alignment: .top, spacing: 8) {
            TypingDots()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(MW.surface)
                .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
            Spacer(minLength: 40)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        VStack(spacing: 0) {
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
                    .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
                .overlay(Rectangle().stroke(MW.border, lineWidth: MW.hairline))
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
        isSending = true
        errorMsg = nil
        Task { @MainActor in
            guard let appDelegate = AppDelegate.shared else {
                errorMsg = "ChatService not available (SwiftUI context issue)"
                isSending = false
                return
            }
            await appDelegate.chatService.send(text)
            if let err = appDelegate.chatService.lastError {
                errorMsg = err
            }
            isSending = false
        }
    }

    private func clearHistory() {
        AppDelegate.shared?.chatService.clearHistory()
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

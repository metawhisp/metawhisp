import Foundation

/// Keeps the raw reply for the end contract and exposes only safe draft text.
struct MeetingAnswerStreamFilter {
    private(set) var raw = ""
    private(set) var visibleText = ""
    private(set) var blocks: [MeetingAnswerBlock] = []
    private(set) var isSuppressed = false
    private(set) var isRejected = false

    private let kind: MeetingAnswerKind
    private let action: MeetingAnswerAction?

    init(kind: MeetingAnswerKind, action: MeetingAnswerAction? = nil) {
        self.kind = kind
        self.action = action
    }

    @discardableResult
    mutating func append(_ delta: String) -> String {
        raw += delta
        update(finishing: false)
        return visibleText
    }

    mutating func finish() {
        update(finishing: true)
    }

    private mutating func update(finishing: Bool) {
        guard !isSuppressed, !isRejected else { return }
        let unfenced = Self.withoutFences(Self.withoutThinkBlocks(raw))
        let lastLineComplete = finishing || unfenced.trimmingCharacters(in: .whitespaces).last?.isNewline == true
        let text = unfenced.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = text.drop { $0.isWhitespace || $0 == "*" || $0 == "_" || $0 == "`" }
        let skip = MeetingAnswerPrompts.skipToken
        if probe.hasPrefix(skip) {
            isSuppressed = true
            visibleText = ""
            blocks = []
            return
        }
        if probe.isEmpty || skip.hasPrefix(probe) {
            // A partial sentinel must not turn into an action at the end.
            if finishing { isRejected = true }
            return
        }
        if text.hasPrefix("{") || text.hasPrefix("[") || text.count > characterLimit {
            isRejected = true
            return
        }
        // Actions have no reliable structural marker. Only their final
        // contract may publish them; they never occupy the draft.
        guard kind == .answer else { return }
        let headline = String(text.prefix { !$0.isNewline })
        guard headline.count <= MeetingAnswerContract.maxHeadlineCharacters else {
            isRejected = true
            return
        }
        guard MeetingAnswerContract.hasBoldRun(headline) else { return }
        let draft = Self.partialBlocks(text, lastLineComplete: lastLineComplete)
        visibleText = draft.text
        blocks = draft.blocks
    }

    private var characterLimit: Int {
        guard kind == .action else { return MeetingAnswerContract.maxAnswerCharacters }
        switch action {
        case .recap: return 2_000
        case .screen: return 1_500
        case .questions, .more, .none: return 1_200
        }
    }

    /// An unresolved marker tail stays held, including across arbitrary
    /// chunk boundaries. Once opened, a think block hides to its closing tag
    /// or the end of the request.
    private static func withoutThinkBlocks(_ text: String) -> String {
        let opening = "<think>"
        let closing = "</think>"
        var result = ""
        var index = text.startIndex
        var thinking = false
        while index < text.endIndex {
            let rest = text[index...]
            if !thinking, rest.hasPrefix(opening) {
                thinking = true
                index = text.index(index, offsetBy: opening.count)
            } else if thinking, rest.hasPrefix(closing) {
                thinking = false
                index = text.index(index, offsetBy: closing.count)
            } else if thinking {
                index = text.index(after: index)
            } else if opening.hasPrefix(rest) || closing.hasPrefix(rest) {
                break
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func withoutFences(_ text: String) -> String {
        var content = String(text.drop(while: \.isWhitespace))
        if content.hasPrefix("```") {
            guard let newline = content.firstIndex(where: \.isNewline) else { return "" }
            content = String(content[content.index(after: newline)...])
        }
        let lines = content.components(separatedBy: .newlines)
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        if end > 0 {
            let trimmed = lines[end - 1].trimmingCharacters(in: .whitespaces)
            // Hold even the first backtick of a possible closing fence.
            if "```".hasPrefix(trimmed) {
                return lines.prefix(end - 1).joined(separator: "\n") + "\n"
            }
        }
        return content
    }

    private static func partialBlocks(_ text: String, lastLineComplete: Bool)
        -> (text: String, blocks: [MeetingAnswerBlock]) {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first else { return ("", []) }
        var result: [MeetingAnswerBlock] = [.headline(first)]
        var lastVisibleIndex = 0
        for (index, line) in lines.dropFirst().enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let bullet = MeetingAnswerContract.bulletText(trimmed) {
                result.append(.bullet(bullet))
                lastVisibleIndex = index + 1
            } else {
                // An unfinished line can be drawn before its list marker or
                // structure is complete. Completed non-list prose ends it.
                if index == lines.count - 2, !lastLineComplete {
                    result.append(.paragraph(trimmed))
                    lastVisibleIndex = index + 1
                }
                break
            }
        }
        return (lines.prefix(lastVisibleIndex + 1).joined(separator: "\n"), result)
    }
}

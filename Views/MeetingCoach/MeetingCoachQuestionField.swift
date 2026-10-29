import AppKit
import SwiftUI

/// The one-line question field uses native editing without activating the app.
struct MeetingCoachQuestionField: NSViewRepresentable {
    let state: MeetingCoachState
    var placeholder: String? = nil
    var onClose: (() -> Void)? = nil
    var onReady: ((MeetingCoachQuestionTextField) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, onClose: onClose)
    }

    func makeNSView(context: Context) -> MeetingCoachQuestionTextField {
        let field = Self.makeField()
        field.delegate = context.coordinator
        field.onFocus = state.beginQuestionEditing
        field.onReady = onReady
        return field
    }

    func updateNSView(_ field: MeetingCoachQuestionTextField, context: Context) {
        field.placeholderString = placeholder ?? "Ask about this call"
        field.isBordered = onClose == nil
        field.drawsBackground = onClose == nil
        if field.stringValue != state.questionText {
            field.stringValue = state.questionText
        }
    }

    static func makeField() -> MeetingCoachQuestionTextField {
        let field = MeetingCoachQuestionTextField()
        field.placeholderString = "Ask about this call"
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.isEditable = true
        field.isSelectable = true
        field.refusesFirstResponder = false
        field.font = .systemFont(ofSize: 13)
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    /// The real editor command path is also driven by the headless tests.
    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let state: MeetingCoachState
        private let onClose: (() -> Void)?

        init(state: MeetingCoachState, onClose: (() -> Void)? = nil) {
            self.state = state
            self.onClose = onClose
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            state.beginQuestionEditing()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            state.questionEditingEnded()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            updateDraft(from: field)
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                updateDraft(from: field)
                state.submitQuestion()
            case #selector(NSResponder.cancelOperation(_:)):
                if let onClose { onClose() } else { state.cancelQuestion() }
            default:
                return false
            }
            field.stringValue = state.questionText
            textView.string = state.questionText
            return true
        }

        private func updateDraft(from field: NSTextField) {
            state.updateQuestionText(field.stringValue)
            guard field.stringValue != state.questionText else { return }
            field.stringValue = state.questionText
            if let editor = field.currentEditor() {
                let selected = editor.selectedRange
                editor.string = state.questionText
                editor.selectedRange = NSRange(location: min(selected.location, state.questionText.utf16.count),
                                               length: 0)
            }
        }
    }
}

/// The field is the card's only control that asks for keyboard focus.
class MeetingCoachQuestionTextField: NSTextField {
    var onFocus: (() -> Void)?
    var onReady: ((MeetingCoachQuestionTextField) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onReady?(self) }
    }

    override var needsPanelToBecomeKey: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard acquireFirstResponder() else { return false }
        onFocus?()
        return true
    }

    /// The tests substitute focus acquisition without showing a window.
    func acquireFirstResponder() -> Bool {
        super.becomeFirstResponder()
    }
}

import SwiftUI

/// Screen 2 of 4 — the two permissions dictation needs, each asked by its own button (US2). The microphone is all
/// the practice needs; Accessibility, for Right ⌘ and typing into other apps, can come later (P0 4).
struct EnableDictationScreen: View {
    /// A permission's row: what it is for, and its one button — or "Allowed".
    struct Row: Equatable {
        enum Action: Equatable {
            case allowed
            /// `prominent`: the button the screen leads with.
            case button(String, prominent: Bool)
        }

        let title: String
        let detail: String
        /// The instruction while the user is in System Settings, brighter than a description.
        var detailIsInstruction = false
        let action: Action
    }

    static let title = "Enable dictation"
    static let next = "Try dictation"

    static func microphoneRow(_ microphone: OnboardingPermissions.Microphone) -> Row {
        switch microphone {
        case .notAsked:
            return Row(title: "Microphone", detail: "Turn your voice into text.",
                       action: .button("Allow microphone", prominent: true))
        case .allowed:
            return Row(title: "Microphone", detail: "Turn your voice into text.", action: .allowed)
        case .denied:
            return Row(title: "Microphone", detail: "Microphone access is off.",
                       action: .button("Open Microphone Settings", prominent: true))
        }
    }

    static func accessibilityRow(granted: Bool, step: OnboardingFlow.AccessibilityStep,
                                 microphone: OnboardingPermissions.Microphone) -> Row {
        let purpose = "Use the shortcut and insert text in other apps."
        guard !granted else { return Row(title: "Accessibility", detail: purpose, action: .allowed) }
        let button = Row.Action.button("Open Accessibility Settings", prominent: microphone == .allowed)
        switch step {
        case .notAsked:
            return Row(title: "Accessibility", detail: purpose, action: button)
        case .waiting:
            return Row(title: "Accessibility", detail: "Turn on MetaWhisp in Accessibility.", detailIsInstruction: true,
                       action: button)
        case .notOnYet:
            return Row(title: "Accessibility", detail: "Not on yet. Right ⌘ and typing into other apps need it.",
                       action: button)
        }
    }

    /// "Try dictation": open once the microphone is allowed; with Accessibility still off it is the quieter choice,
    /// so the Settings button leads.
    static func next(_ permissions: OnboardingPermissions) -> (enabled: Bool, kind: CapsuleButtonStyle.Kind) {
        let microphone = permissions.microphone == .allowed
        return (microphone, microphone && !permissions.accessibility ? .glass : .primary)
    }

    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        let next = Self.next(flow.permissions)
        OnboardingPage {
            VStack(spacing: 30) {
                OnboardingTitle(text: Self.title)
                VStack(spacing: 0) {
                    PermissionRowView(symbol: "mic.fill", row: Self.microphoneRow(flow.permissions.microphone)) {
                        flow.microphoneButton()
                    }
                    Rectangle().fill(MW.border).frame(height: 0.5).padding(.leading, 76).padding(.trailing, 20)
                    PermissionRowView(symbol: "accessibility",
                                      row: Self.accessibilityRow(granted: flow.permissions.accessibility,
                                                                 step: flow.accessibilityStep,
                                                                 microphone: flow.permissions.microphone)) {
                        flow.accessibilityButton()
                    }
                }
                .frame(width: OnboardingStyle.column)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(MW.surface))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(MW.border, lineWidth: 0.5))
            }
        } leading: {
            Button("Back") { flow.back() }.buttonStyle(OnboardingTextButtonStyle())
        } center: {
            Button { flow.next() } label: { ArrowLabel(text: Self.next) }
                .buttonStyle(CapsuleButtonStyle(kind: next.kind))
                .keyboardShortcut(.defaultAction)
                .disabled(!next.enabled)
        }
    }
}

private struct PermissionRowView: View {
    let symbol: String
    let row: EnableDictationScreen.Row
    let press: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(MW.textPrimary)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.08)))
                .accessibilityHidden(true)
            // The words take the room the button leaves, 16 pt from it as from the icon: with a spacer's 12 pt and
            // a second gap on top, "Use the shortcut and insert text in other apps." broke onto two lines where the
            // mockup keeps one.
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(MW.textPrimary)
                Text(row.detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(row.detailIsInstruction ? MW.textPrimary : MW.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch row.action {
            case .allowed:
                AllowedLabel()
            case .button(let title, let prominent):
                Button(title, action: press).buttonStyle(RowButtonStyle(prominent: prominent))
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 92)
        .accessibilityElement(children: .contain)
    }
}

import SwiftUI

/// The one field every API key in Settings is typed into: Groq, the cloud LLM key, Deepgram, Gemini.
///
/// The user types or pastes into a draft that lives only in this view. The key reaches the setting, and with it the
/// keychain, on Return or Save, never per keystroke: a field bound straight to the setting stored the first
/// character as the key and swapped itself for the masked label after one keystroke. A stored key is drawn only
/// through `masked`, which has no negative count to trap on.
struct APIKeyField: View {
    private let placeholder: String
    private let key: ReferenceWritableKeyPath<AppSettings, String>
    @ObservedObject private var settings = AppSettings.shared
    @State private var draft = ""

    init(_ placeholder: String, key: ReferenceWritableKeyPath<AppSettings, String>) {
        self.placeholder = placeholder
        self.key = key
    }

    /// A stored key as Settings shows it: one bullet per hidden character, at most twenty, then the last four
    /// characters, shown only when at least as many stay hidden. A key shorter than eight is all bullets.
    nonisolated static func masked(_ key: String) -> String {
        let tail = 4, maxBullets = 20
        let shown = key.count >= 2 * tail ? tail : 0
        return String(repeating: "\u{2022}", count: min(maxBullets, key.count - shown)) + String(key.suffix(shown))
    }

    /// The key a draft saves: trimmed of spaces and line breaks, or nothing when that leaves it empty.
    nonisolated static func committed(_ draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var body: some View {
        let stored = settings[keyPath: key]
        HStack(spacing: MW.sp8) {
            if stored.isEmpty {
                TextField("", text: $draft, prompt: Text(placeholder).foregroundStyle(MW.textMuted))
                    .font(MW.mono)
                    .textFieldStyle(.plain)
                    .foregroundStyle(MW.textPrimary)
                    .padding(.horizontal, MW.sp8)
                    .padding(.vertical, MW.sp4)
                    .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous).stroke(MW.border, lineWidth: 0.5))
                    .onSubmit { save() }
                if Self.committed(draft) != nil {
                    Button("Save") { save() }
                        .buttonStyle(.plain)
                        .font(MW.label).tracking(0.6)
                        .foregroundStyle(MW.ok)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: MW.rSmall, style: .continuous)
                                    .stroke(MW.ok.opacity(0.4), lineWidth: 0.5))
                }
            } else {
                HStack(spacing: MW.sp8) {
                    Text(Self.masked(stored))
                        .font(MW.mono)
                        .foregroundStyle(MW.textSecondary)
                    Spacer()
                    Circle().fill(MW.ok).frame(width: 6, height: 6)
                    Button { settings[keyPath: key] = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MW.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, MW.sp8)
                .padding(.vertical, MW.sp4)
                .overlay(Rectangle().stroke(MW.borderLight, lineWidth: MW.hairline))
            }
        }
    }

    private func save() {
        guard let value = Self.committed(draft) else { return }
        settings[keyPath: key] = value
        draft = ""
    }
}

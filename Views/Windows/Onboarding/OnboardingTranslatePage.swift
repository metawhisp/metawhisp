import SwiftUI

/// Screen 4: both translation features, which used to be invisible.
///
/// Before this screen existed they were one teaser line on the dictation page
/// and one line on the final page — so the founder's own users did not know the
/// app translated at all. Each direction gets a worked example here, because
/// "translates text" sells nothing and a sentence turning into another sentence
/// sells itself.
struct OnboardingTranslatePage: View {
    let appeared: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            OnboardingHeader(
                label: "TRANSLATION",
                title: "Speak yours. Send theirs.",
                appeared: appeared
            )

            Spacer().frame(height: 6)

            Text("Both directions live on the right ⌥ key.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 22)

            VStack(spacing: 12) {
                example(
                    keycap: "Tap Right ⌥",
                    title: "Say it in yours, send it in theirs",
                    detail: "Records, then types the translation instead of your words.",
                    before: "🎙  «Отправлю правки к утру»",
                    after: "I'll send the edits by morning"
                )
                example(
                    keycap: "Hold Right ⌥",
                    title: "Turn any text you can select",
                    detail: "Their message, a doc, an error log — select it, hold, read it in yours.",
                    before: "Could you review this by EOD?",
                    after: "Сможешь посмотреть до конца дня?"
                )
            }
            .padding(.horizontal, 36)
            .opacity(appeared ? 1 : 0)

            Spacer()
        }
    }

    private func example(
        keycap: String,
        title: String,
        detail: String,
        before: String,
        after: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Keycap(text: keycap)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MW.textPrimary)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(before)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MW.textMuted)
                    Text("↓")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MW.textDim)
                    Text(after)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MW.idle)
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }
}

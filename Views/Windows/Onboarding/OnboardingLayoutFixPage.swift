import SwiftUI

/// Screen 5: layout fixing, announced rather than discovered.
///
/// This is the feature most likely to frighten someone who does not know it is
/// there — text changing by itself, in someone else's chat window. Naming it
/// here, with the two safety promises directly underneath, is what turns that
/// into the reason people keep the app instead of the reason they uninstall it.
struct OnboardingLayoutFixPage: View {
    let appeared: Bool
    @State private var typed = ""
    @State private var showFixed = false

    private let wrong = "ghbdtn rfr ltkf"
    private let right = "привет как дела"

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            OnboardingHeader(
                label: "WRONG KEYBOARD",
                title: "ghbdtn → привет, as you type",
                appeared: appeared
            )

            Spacer().frame(height: 6)

            Text("Typed a whole sentence in the wrong layout? It fixes itself, word by word.")
                .font(MW.monoSm).foregroundStyle(MW.textMuted)
                .multilineTextAlignment(.center)
                .opacity(appeared ? 1 : 0)

            Spacer().frame(height: 20)

            VStack(alignment: .leading, spacing: 6) {
                Text(typed.isEmpty ? " " : typed)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(MW.textMuted)
                Text("↓")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MW.textDim)
                    .opacity(showFixed ? 1 : 0)
                Text(showFixed ? right : " ")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(MW.idle)
                Text("Each word is corrected the moment you finish it, and the keyboard layout follows. Nothing to press.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .mwCard(radius: MW.rSmall, elevation: .flat)
            .padding(.horizontal, 36)

            Spacer().frame(height: 12)

            VStack(spacing: 8) {
                promise(
                    icon: "lock.shield",
                    title: "Never in the wrong place",
                    detail: "Password fields, terminals and password managers are refused outright."
                )
                promise(
                    icon: "arrow.uturn.backward",
                    title: "One undo, always",
                    detail: "⌘Z puts your original text back in a single step."
                )
            }
            .padding(.horizontal, 36)
            .opacity(appeared ? 1 : 0)

            Spacer()
        }
        .onChange(of: appeared) { _, val in if val { runDemo() } }
    }

    private func promise(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .light))
                .foregroundStyle(MW.textSecondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MW.textPrimary)
                Text(detail)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(MW.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .mwCard(radius: MW.rSmall, elevation: .flat)
    }

    private func runDemo() {
        typed = ""
        showFixed = false
        for (i, ch) in wrong.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + Double(i) * 0.045) {
                typed += String(ch)
            }
        }
        let done = 0.35 + Double(wrong.count) * 0.045 + 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + done) {
            withAnimation(.easeOut(duration: 0.35)) { showFixed = true }
        }
    }
}

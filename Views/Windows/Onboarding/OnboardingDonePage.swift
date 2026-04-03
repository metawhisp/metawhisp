import SwiftUI

/// Screen 6: Done — keyboard with arrows branching down then out to labels.
struct OnboardingDonePage: View {
    let appeared: Bool
    @State private var checkProgress: CGFloat = 0
    @State private var showTitle = false
    @State private var showKeyboard = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 14)

            // Compact checkmark + title
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(MW.idle.opacity(0.12), lineWidth: 2).frame(width: 36, height: 36)
                    Circle()
                        .trim(from: 0, to: checkProgress)
                        .stroke(MW.idle, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 36, height: 36)
                        .rotationEffect(.degrees(-90))
                    CheckmarkShape()
                        .trim(from: 0, to: max(0, checkProgress * 2 - 1))
                        .stroke(MW.idle, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 14)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("You're ready!")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(MW.textPrimary)
                    Text("Remember your shortcuts:")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MW.textMuted)
                }
            }
            .opacity(showTitle ? 1 : 0)

            Spacer().frame(height: 24)

            if showKeyboard {
                // Keyboard
                keyboardRow.padding(.horizontal, 24)

                Spacer().frame(height: 4)

                // Arrows + labels drawn with Canvas for precise positioning
                arrowsAndLabels.padding(.horizontal, 24)

                Spacer().frame(height: 0)
            }

            Spacer()
        }
        .onChange(of: appeared) { _, val in if val { startAnimation() } }
    }

    // MARK: - Keyboard Row

    private var keyboardRow: some View {
        HStack(spacing: 5) {
            kbKey("fn", w: 38)
            kbKey("⌃", w: 38)
            kbKey("⌥", w: 38)
            kbKey("⌘", w: 50)
            kbKey("", w: 150, h: 40) // spacebar
            kbKey("⌘", w: 50, highlight: .blue)
            kbKey("⌥", w: 40, highlight: .green)
            kbKey("⌃", w: 38)
        }
    }

    // MARK: - Arrows and Labels

    private var arrowsAndLabels: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            // Calculate key positions matching HStack layout
            // Keys: fn(38) + 5 + ⌃(38) + 5 + ⌥(38) + 5 + ⌘(50) + 5 + space(150) + 5 + ⌘(50) + 5 + ⌥(40) + 5 + ⌃(38)
            // Total keys width = 38+38+38+50+150+50+40+38 = 442, gaps = 7*5 = 35, total = 477
            let keysTotal: CGFloat = 477
            let offsetX = (totalW - keysTotal) / 2 // centering offset

            // Right ⌘ center: fn+5+⌃+5+⌥+5+⌘+5+space+5 + 25 (half of 50)
            let cmdX = offsetX + 38+5+38+5+38+5+50+5+150+5 + 25
            // Right ⌥ center: cmdX + 25 + 5 + 20 (half of 40)
            let optX = cmdX + 25 + 5 + 20

            // Label positions — spread out
            let leftLabelCenterX = totalW * 0.28
            let rightLabelCenterX = totalW * 0.72

            // Draw arrows
            Path { p in
                // ⌘ arrow: down from key, then left to label
                p.move(to: CGPoint(x: cmdX, y: 0))
                p.addLine(to: CGPoint(x: cmdX, y: 40))
                p.addLine(to: CGPoint(x: leftLabelCenterX, y: 40))
                p.addLine(to: CGPoint(x: leftLabelCenterX, y: 60))
            }
            .stroke(Color.blue.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            Path { p in
                // ⌥ arrow: down from key, then right to label
                p.move(to: CGPoint(x: optX, y: 0))
                p.addLine(to: CGPoint(x: optX, y: 30))
                p.addLine(to: CGPoint(x: rightLabelCenterX, y: 30))
                p.addLine(to: CGPoint(x: rightLabelCenterX, y: 60))
            }
            .stroke(Color.green.opacity(0.4), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Arrow dots at key bottoms
            Circle().fill(Color.blue.opacity(0.6)).frame(width: 6, height: 6)
                .position(x: cmdX, y: 0)
            Circle().fill(Color.green.opacity(0.6)).frame(width: 6, height: 6)
                .position(x: optX, y: 0)

            // Left label: TRANSCRIBE
            VStack(spacing: 5) {
                Text("TRANSCRIBE")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.4, green: 0.6, blue: 1.0))
                    .tracking(0.5)
                Text("Tap Right ⌘ to start and stop recording")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(MW.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: totalW * 0.46)
            .background(Color.blue.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .position(x: leftLabelCenterX, y: 110)

            // Right label: TRANSLATE
            VStack(spacing: 10) {
                VStack(spacing: 4) {
                    Text("TRANSLATE VOICE")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.4))
                        .tracking(0.3)
                    Text("Tap Right ⌥ to record & translate")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MW.textMuted)
                        .multilineTextAlignment(.center)
                }

                Rectangle().fill(MW.border).frame(height: MW.hairline)

                VStack(spacing: 4) {
                    Text("TRANSLATE TEXT")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.2, green: 0.8, blue: 0.4))
                        .tracking(0.3)
                    Text("Hold Right ⌥ with text selected")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(MW.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(width: totalW * 0.46)
            .background(Color.green.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.2), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .position(x: rightLabelCenterX, y: 130)
        }
        .frame(height: 200)
    }

    // MARK: - Key

    private func kbKey(_ symbol: String, w: CGFloat, h: CGFloat = 40, highlight: Color? = nil) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(highlight != nil ? highlight!.opacity(0.12) : MW.surface)
            RoundedRectangle(cornerRadius: 6)
                .stroke(highlight?.opacity(0.5) ?? MW.border, lineWidth: highlight != nil ? 1.5 : MW.hairline)
            Text(symbol)
                .font(.system(size: symbol.count > 1 ? 11 : 16, weight: .medium))
                .foregroundStyle(highlight ?? MW.textSecondary)
        }
        .frame(width: w, height: h)
    }

    // MARK: - Animation

    private func startAnimation() {
        checkProgress = 0; showTitle = false; showKeyboard = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(.easeOut(duration: 0.5)) { checkProgress = 1.0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showTitle = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { showKeyboard = true }
        }
    }
}

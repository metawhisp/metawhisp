import SwiftUI

/// ITER-085 — the Target window, after the approved mockup: the film (one phrase, three places), the words, and
/// Not now / Turn on Target; then the onboarding's Pro screen for a Free user, or "Target is on" for a Pro one.
/// Screens slide in; with Reduce Motion they only fade, and the film shows each place whole.
struct TargetIntroView: View {
    @ObservedObject var flow: TargetIntroFlow
    @ObservedObject var license: LicenseService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            screen
                .id(flow.screen)
                .transition(.asymmetric(
                    insertion: .offset(x: OnboardingMotion.offset(16, reduceMotion: reduceMotion)).combined(with: .opacity),
                    removal: .offset(x: OnboardingMotion.offset(-16, reduceMotion: reduceMotion)).combined(with: .opacity)))
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .ignoresSafeArea()
        .background(OnboardingBackground())
        .animation(.easeOut(duration: 0.24), value: flow.screen)
    }

    @ViewBuilder
    private var screen: some View {
        switch flow.screen {
        case .intro: TargetIntroScreen(flow: flow)
        case .pro: ProScreen(actions: flow.proActions, accountLinkShown: flow.accountLinkShown, license: license)
        case .on: TargetOnScreen(flow: flow)
        }
    }
}

/// The first screen: the film, then what Target is, in two sentences.
struct TargetIntroScreen: View {
    static let chip = "NEW MODE · TARGET"
    static let title = "Your words, shaped for where they go"
    static let body = "Target looks only at the app and window you dictate into. It keeps the language you speak."
    static let notNow = "Not now"
    static let turnOn = "Turn on Target"

    @ObservedObject var flow: TargetIntroFlow
    /// A render shows this place still, whole (nil: the film plays).
    var still: Int?

    var body: some View {
        OnboardingPage {
            VStack(spacing: 0) {
                TargetFilm(still: still)
                HStack(spacing: 6) {
                    Image(systemName: "scope").font(.system(size: 11, weight: .bold))
                    Text(Self.chip).font(.system(size: 11, weight: .bold)).tracking(0.66)
                }
                .foregroundStyle(TargetFilm.aim)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(TargetFilm.aim.opacity(0.12)))
                .overlay(Capsule().strokeBorder(TargetFilm.aim.opacity(0.34), lineWidth: 0.5))
                .padding(.top, 12)
                Text(Self.title)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(MW.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                Text(Self.body)
                    .font(.system(size: 15.5))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        } leading: {
            EmptyView()
        } center: {
            // No default action: the window comes up on its own while the user may be typing elsewhere.
            HStack(spacing: 12) {
                Button(Self.notNow) { flow.notNow() }
                    .buttonStyle(CapsuleButtonStyle(kind: .glass, minWidth: ProScreen.pairWidth))
                Button { flow.turnOn() } label: { ArrowLabel(text: Self.turnOn) }
                    .buttonStyle(CapsuleButtonStyle(minWidth: ProScreen.pairWidth))
            }
        }
    }
}

/// "Target is on": read, and the window closes by itself.
struct TargetOnScreen: View {
    static let title = "Target is on"
    static let body = "Switch back any time in Settings → Text processing."
    static let shownFor: Duration = .seconds(2.4)

    @ObservedObject var flow: TargetIntroFlow

    var body: some View {
        OnboardingPage {
            VStack(spacing: 14) {
                Image(systemName: "checkmark")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
                    .background(Circle().fill(LinearGradient(colors: [Color(red: 0.26, green: 0.89, blue: 0.46),
                                                                      Color(red: 0.12, green: 0.62, blue: 0.28)],
                                                             startPoint: .top, endPoint: .bottom)))
                    .shadow(color: MW.idle.opacity(0.32), radius: 20, y: 16)
                    .accessibilityHidden(true)
                OnboardingTitle(text: Self.title)
                Text(Self.body).font(OnboardingStyle.body).foregroundStyle(Color.primary.opacity(0.72))
            }
        } leading: {
            EmptyView()
        } center: {
            EmptyView()
        }
        .task {
            try? await Task.sleep(for: Self.shownFor)
            if !Task.isCancelled { flow.done() }
        }
    }
}

/// The film: the words as spoken, fillers and all; then the same words in three places — a prompt in Claude, a
/// letter in Mail, one message in Telegram — each line arriving in turn.
struct TargetFilm: View {
    enum Kind { case prompt, letter, message }

    struct Place {
        let app: String
        let symbol: String
        let detail: String
        let kind: Kind
        /// The shaped text, a line each.
        let lines: [String]
    }

    static let aim = Color(red: 0.61, green: 0.76, blue: 1.0)
    static let width: CGFloat = 624
    static let phrase = "Uh, so write the team that the landing slips to Friday because, um, the hero video isn't "
        + "rendered yet, and ask if the new copy is final."
    static let fillers: Set<String> = ["Uh,", "so", "um,"]
    static let places = [
        Place(app: "Claude", symbol: "sparkle", detail: "New chat", kind: .prompt,
              lines: ["Write the team that the landing slips to Friday because the hero video isn’t rendered yet, "
                      + "and ask if the new copy is final."]),
        Place(app: "Mail", symbol: "envelope", detail: "Re: Landing page", kind: .letter,
              lines: ["Hi team,", "The landing slips to Friday: the hero video isn’t rendered yet.",
                      "Is the new copy final?", "Thanks"]),
        Place(app: "Telegram", symbol: "paperplane", detail: "Launch team", kind: .message,
              lines: ["Landing slips to Friday, the hero video isn’t rendered yet. Is the new copy final?"]),
    ]
    private static let words = phrase.split(separator: " ").map(String.init)

    let still: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit: Int
    @State private var struck: Bool
    @State private var live = false
    @State private var place: Int?
    @State private var lines: Int

    /// `still`: that place, whole, from the first frame (a render); nil: the film plays.
    init(still: Int? = nil) {
        self.still = still
        _lit = State(initialValue: still == nil ? 0 : Self.words.count)
        _struck = State(initialValue: still != nil)
        _place = State(initialValue: still)
        _lines = State(initialValue: still == nil ? 0 : 99)
    }

    var body: some View {
        VStack(spacing: 0) {
            said
            Rectangle()
                .fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.04)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 1, height: 12)
                .padding(.vertical, 3)
            pill
            ZStack(alignment: .top) {
                if let place { card(Self.places[place]).id(place).transition(.opacity) }
                dots.frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: Self.width, height: 178)
            .padding(.top, 10)
        }
        .task { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The same words as a prompt in Claude, a letter in Mail and a message in Telegram.")
    }

    // MARK: - The words as spoken

    private var said: some View {
        HStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13))
                .foregroundStyle(live ? Color.white : MW.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(live ? Color(red: 1, green: 0.27, blue: 0.23) : Color.primary.opacity(0.08)))
            wave
            Self.words.enumerated().reduce(Text("")) { text, item in
                let (index, word) = item
                let filler = Self.fillers.contains(word)
                let opacity = index >= lit ? 0.26 : (filler && struck ? 0.34 : 1)
                return text + Text(word + " ")
                    .foregroundColor(MW.textPrimary.opacity(opacity))
                    .strikethrough(filler && struck, color: MW.textPrimary.opacity(0.6))
            }
            .font(.system(size: 12.5))
            .lineSpacing(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .frame(width: Self.width, height: 66)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
    }

    /// 17 bars that move only while the voice is heard (the mockup's formula).
    private var wave: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * 1000
            HStack(spacing: 2.5) {
                ForEach(0..<17, id: \.self) { i in
                    Capsule()
                        .fill(MW.textPrimary.opacity(0.9))
                        .frame(width: 2.5, height: live ? Self.barHeight(i, t) : 3)
                }
            }
            .frame(height: 32)
        }
    }

    static func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        let envelope = sin(Double.pi * Double(i + 1) / 18)
        let v = abs(sin(t / 120 + Double(i) * 0.9) * sin(t / 270 + Double(i) * 0.37) + 0.25 * sin(t / 60 + Double(i) * 2.1))
        return 3 + 26 * envelope * min(1, v)
    }

    // MARK: - Where the words go

    private var pill: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").font(.system(size: 14, weight: .semibold)).foregroundStyle(Self.aim)
            if let place {
                let p = Self.places[place]
                HStack(spacing: 7) {
                    Image(systemName: p.symbol).font(.system(size: 12)).opacity(0.86)
                    Text(p.app).fontWeight(.semibold)
                    Text("·").foregroundStyle(Color.primary.opacity(0.4))
                    Text(p.detail).foregroundStyle(Color.primary.opacity(0.66))
                }
                .font(.system(size: 13))
                .foregroundStyle(MW.textPrimary)
                .id(place)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reduceMotion ? 0 : 5)),
                                        removal: .opacity.combined(with: .offset(y: reduceMotion ? 0 : -5))))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 32)
        .background(Capsule().fill(Self.aim.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Self.aim.opacity(0.36), lineWidth: 0.5))
        .opacity(place == nil ? 0 : 1)
        .clipped()
    }

    private func card(_ p: Place) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: p.symbol).font(.system(size: 12))
                Text(p.app).font(.system(size: 12, weight: .semibold))
                Text(p.detail).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.5))
            }
            .foregroundStyle(Color.primary.opacity(0.86))
            .frame(height: 20)
            switch p.kind {
            case .prompt:
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(p.lines.enumerated()), id: \.offset) { index, line in
                        arriving(Text(line).font(.system(size: 13)), index)
                            .padding(.top, index == p.lines.count - 1 ? 5 : 0)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .padding(.top, 8)
            case .letter:
                HStack(spacing: 6) {
                    Text("Subject").foregroundStyle(Color.primary.opacity(0.5))
                    Text(p.detail).fontWeight(.medium).foregroundStyle(Color.primary.opacity(0.86))
                }
                .font(.system(size: 12.5))
                .padding(.top, 6)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5) }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(p.lines.enumerated()), id: \.offset) { index, line in
                        arriving(Text(line).font(.system(size: 13.5)), index)
                    }
                }
                .padding(.top, 7)
            case .message:
                HStack(alignment: .bottom, spacing: 10) {
                    arriving(Text(p.lines[0]).font(.system(size: 13)), 0)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(Color.primary.opacity(0.055)))
                        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(w: 0.07))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(w: 0.95)))
                }
                .padding(.top, 8)
            }
        }
        .foregroundStyle(MW.textPrimary)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(MW.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    /// A line that arrives in turn: it fades in and, without Reduce Motion, rises 6 pt.
    private func arriving(_ text: Text, _ index: Int) -> some View {
        text
            .fixedSize(horizontal: false, vertical: true)
            .opacity(lines > index ? 1 : 0)
            .offset(y: lines > index || reduceMotion ? 0 : 6)
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.places.count, id: \.self) { i in
                Capsule()
                    .fill(place == i ? Color.primary.opacity(0.86) : Color.primary.opacity(0.18))
                    .frame(width: place == i ? 14 : 5, height: 5)
            }
        }
        .padding(.bottom, -2)
    }

    // MARK: - The film

    private func play() async {
        if still != nil { return }
        if reduceMotion {
            lit = Self.words.count
            struck = true
            while !Task.isCancelled {
                for p in Self.places.indices {
                    withAnimation(.easeOut(duration: 0.25)) {
                        place = p
                        lines = 99
                    }
                    guard await pause(3.4) else { return }
                }
            }
            return
        }
        while !Task.isCancelled {
            withAnimation(.easeOut(duration: 0.2)) {
                place = nil
                lines = 0
            }
            lit = 0
            struck = false
            guard await pause(0.5) else { return }
            live = true
            for i in 1...Self.words.count {
                lit = i
                guard await pause(0.07) else { return }
            }
            guard await pause(0.25) else { return }
            live = false
            withAnimation(.easeOut(duration: 0.3)) { struck = true }
            guard await pause(0.5) else { return }
            for p in Self.places.indices {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                    place = p
                    lines = 0
                }
                guard await pause(0.28) else { return }
                for l in 1...Self.places[p].lines.count {
                    withAnimation(.easeOut(duration: 0.3)) { lines = l }
                    guard await pause(0.16) else { return }
                }
                guard await pause(2.3) else { return }
            }
        }
    }

    /// False once the film is gone (its window closed, or the screen changed).
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

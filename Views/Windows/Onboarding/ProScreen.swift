import SwiftUI

/// Screen 4 of 4 — Free or Pro, once, after the first words (US4). Pro is sold by the year (owner 2026-10-24): the
/// price as the site shows it, arriving as it counts down to $30 (owner 2026-10-25), the eight things Pro adds from one
/// list, and Free as the second capsule beside Get Pro, never a grey link. Get Pro opens the site's account page and
/// the onboarding is done. A Pro user is not offered Pro: "You have Pro", and Continue.
struct ProScreen: View {
    struct Tile: Equatable {
        let symbol: String
        let title: String
        let detail: String
    }

    enum Offer: Equatable { case plans, youHavePro }

    static let price = "$30"
    static let per = "a year"
    static let save = "Save 68%"
    /// The site's monthly price; a year of it is where the price's count starts.
    static let monthly = 7.77

    /// The price as it counts (owner 2026-10-25): from a year at the monthly price to the yearly one, in whole dollars
    /// so the digits keep their width — $93 (12 × $7.77 = $93.24, rounded down, never more) to $30.
    enum Count {
        static let from = (monthly * 12).rounded(.down)
        static let to = 30.0

        static func label(_ dollars: Double) -> String { "$\(Int(dollars.rounded()))" }
    }

    /// When the header's parts arrive, in seconds after the screen appears: the chip, the price at $93, its count to
    /// $30, then the saving once the price has landed. Reduce Motion: no count, and all of it at once.
    struct Reveal: Equatable {
        let chip: Double
        let price: Double
        let count: Double
        let counting: Double
        let save: Double

        init(reduceMotion: Bool) {
            (chip, price, count, counting, save) = reduceMotion ? (0, 0, 0, 0, 0) : (0.12, 0.3, 0.6, 1.2, 1.8)
        }
    }

    /// What Pro adds, each line checked against the pricing page and the app's Pro gates (mockup v6 `PRO_F`); screen
    /// hints and the browser agent are not part of Pro (U1).
    static let tiles = [
        Tile(symbol: "cloud", title: "Cloud dictation", detail: "5,400 minutes a month"),
        Tile(symbol: "sparkles", title: "AI polish", detail: "Clean, structured text"),
        Tile(symbol: "globe", title: "Translation", detail: "Into 11 languages, by voice or selection"),
        Tile(symbol: "bubble.left", title: "MetaChat", detail: "Ask about your notes and meetings"),
        Tile(symbol: "video", title: "Meeting notes", detail: "Summaries, tasks and memories"),
        Tile(symbol: "sun.max", title: "Day and week summaries", detail: "A short recap of each day and week"),
        Tile(symbol: "magnifyingglass", title: "Search by meaning", detail: "Find what you said, not just the words"),
        Tile(symbol: "waveform", title: "Natural voices", detail: "Spoken answers in a natural voice"),
    ]
    static let free = "Continue with Free"
    /// The width of each capsule in the pair.
    static let pairWidth: CGFloat = 210
    static let getPro = "Get Pro"
    static let youHavePro = "You have Pro"
    static let proceed = "Continue"

    static func offer(isPro: Bool) -> Offer { isPro ? .youHavePro : .plans }

    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var license: LicenseService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How much of the header has arrived: the chip, the price, the saving (`Reveal`).
    @State private var shown = 0
    @State private var dollars = Count.from

    var body: some View {
        switch Self.offer(isPro: license.isPro) {
        case .plans: plans
        case .youHavePro: youHavePro
        }
    }

    private var plans: some View {
        OnboardingPage {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Text("PRO")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.66)
                        .foregroundStyle(MW.textPrimary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.primary.opacity(0.16)))
                        .modifier(Arrival(shown: shown > 0))
                    HStack(spacing: 10) {
                        CountingPrice(dollars: dollars)
                        Text(Self.per).font(.system(size: 17, weight: .medium)).foregroundStyle(Color.primary.opacity(0.86))
                        Text(Self.save)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Color(red: 0.02, green: 0.17, blue: 0.07))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color(red: 0.19, green: 0.82, blue: 0.35)))
                            // Its room is kept while it waits, so nothing moves when it pops in.
                            .scaleEffect(shown > 2 || reduceMotion ? 1 : 0.6)
                            .opacity(shown > 2 ? 1 : 0)
                    }
                    .modifier(Arrival(shown: shown > 1))
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Self.tiles, id: \.title) { ProTileView(tile: $0) }
                }
                .frame(width: OnboardingStyle.column)
                .padding(.top, 22)
                if flow.accountLinkShown {
                    AccountLinkFallback().padding(.top, 8)
                } else {
                    AlreadyHaveProButton { flow.signIn() }.padding(.top, 8)
                }
            }
        } leading: {
            Button("Back") { flow.back() }.buttonStyle(OnboardingTextButtonStyle())
        } center: {
            HStack(spacing: 12) {
                // As wide as each other, as the mockup draws the pair.
                Button(Self.free) { flow.complete(.free) }
                    .buttonStyle(CapsuleButtonStyle(kind: .glass, minWidth: Self.pairWidth))
                Button { flow.getPro() } label: { ArrowLabel(text: Self.getPro) }
                    .buttonStyle(CapsuleButtonStyle(minWidth: Self.pairWidth))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task { await reveal() }
    }

    /// The header arrives as `Reveal` times it: the chip, the price at $93, its count to $30, then the saving with a
    /// spring. With Reduce Motion the price is $30 from the start and the parts fade in together.
    private func reveal() async {
        let reveal = Reveal(reduceMotion: reduceMotion)
        let began = Date()
        func at(_ second: Double) async {
            let wait = second - Date().timeIntervalSince(began)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
        let fade = Animation.easeOut(duration: reduceMotion ? 0.1 : 0.28)
        if reveal.counting == 0 { dollars = Count.to }
        await at(reveal.chip)
        withAnimation(fade) { shown = 1 }
        await at(reveal.price)
        withAnimation(fade) { shown = 2 }
        await at(reveal.count)
        if reveal.counting > 0 { withAnimation(.easeOut(duration: reveal.counting)) { dollars = Count.to } }
        await at(reveal.save)
        withAnimation(reduceMotion ? fade : .spring(response: 0.36, dampingFraction: 0.58)) { shown = 3 }
    }

    private var youHavePro: some View {
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
                OnboardingTitle(text: Self.youHavePro)
            }
        } leading: {
            Button("Back") { flow.back() }.buttonStyle(OnboardingTextButtonStyle())
        } center: {
            Button { flow.complete(.pro) } label: { ArrowLabel(text: Self.proceed) }
                .buttonStyle(CapsuleButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// The price as it counts: whole dollars on every frame of the count (`ProScreen.Count`); read aloud, the price itself.
private struct CountingPrice: View, Animatable {
    var dollars: Double

    var animatableData: Double {
        get { dollars }
        set { dollars = newValue }
    }

    var body: some View {
        Text(ProScreen.Count.label(dollars))
            .font(.system(size: 40, weight: .semibold))
            .tracking(-0.8)
            .monospacedDigit()
            .foregroundStyle(MW.textPrimary)
            .accessibilityLabel(ProScreen.price)
    }
}

private struct ProTileView: View {
    let tile: ProScreen.Tile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tile.symbol)
                .font(.system(size: 15))
                .foregroundStyle(MW.textPrimary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.08)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(tile.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(MW.textPrimary)
                Text(tile.detail).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MW.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(MW.border, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

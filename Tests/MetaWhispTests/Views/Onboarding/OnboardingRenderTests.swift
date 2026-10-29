import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

/// The onboarding as it is drawn: every screen in the onboarding's own window (`OnboardingWindowController
/// .makeWindow`), never put on screen, drawn into an image — title bar included. Each render is checked where the
/// mockup is exact; with `MW_RENDER_DIR` set, the images are written there as well, to be looked at beside the
/// mockup's.
@MainActor
final class OnboardingRenderTests: XCTestCase {
    private var fixture: OnboardingAppFixture!
    private var wasPro = false

    override func setUp() async throws {
        fixture = OnboardingAppFixture()
        wasPro = LicenseService.shared.isPro
        LicenseService.shared.isPro = false
    }

    override func tearDown() async throws {
        LicenseService.shared.isPro = wasPro
        fixture.tearDown()
        fixture = nil
    }

    // MARK: - The window

    /// The mockup's window is 720 × 600 in all, its title bar drawn over the content. Sized by its content, the
    /// window was 632 pt tall: a 32 pt empty band under the footer (owner 2026-10-25).
    func testTheWindowIsTheMockupsSizeWithTheTitleBarOverTheContent() {
        let window = OnboardingWindowController.makeWindow(rootView: Color.clear.frame(width: 720, height: 600)
            .ignoresSafeArea())
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { window.close() }
        XCTAssertEqual(window.frame.size, OnboardingWindowController.size, "the whole window")
        XCTAssertEqual(window.contentView?.frame.size, OnboardingWindowController.size, "the content under the title bar")
    }

    /// Under the app's SwiftUI lifecycle, a window whose content view is a hosting view is sized by SwiftUI from its
    /// content, with the title bar's 32 pt added on top, whatever the hosting view's sizing options: the owner's window
    /// was still 632 pt on 2026-10-25 (`[SpaceTrace]` 13:39:23), and a SwiftUI app with this same window went from 600
    /// to 632 on the turn after it was ordered front — but stayed 600 with the hosting view inside a plain view. These
    /// tests run without that lifecycle, so the arrangement itself is what they check.
    func testTheWindowHoldsTheScreensInAViewOfItsOwn() throws {
        let window = OnboardingWindowController.makeWindow(rootView: Color.clear)
        defer { window.close() }
        let own = try XCTUnwrap(window.contentView)
        XCTAssertFalse(own is NSHostingView<Color>, "SwiftUI sizes a window whose content view is its own")
        XCTAssertEqual(own.subviews.count, 1)
        let screens = try XCTUnwrap(own.subviews.first as? NSHostingView<Color>, "the screens, inside the window's view")
        XCTAssertEqual(screens.frame, own.bounds, "filling the window")
        XCTAssertEqual(screens.autoresizingMask, [.width, .height])
        XCTAssertEqual(screens.sizingOptions, [], "never asking the window for a size")
    }

    // MARK: - The footer

    /// Owner 2026-10-25: on the first screen the button sat at the left. The footer is the mockup's three columns —
    /// Back, the choice, an empty column as wide as Back's — so the choice is in the middle whether or not the screen
    /// has a Back.
    func testTheWelcomesButtonSitsInTheMiddle() throws {
        let image = render(container(on: .welcome), settle: 3.6, name: "1-welcome")
        let capsule = try XCTUnwrap(image.choiceCapsule(), "the Get started capsule is drawn")
        XCTAssertEqual(capsule.midX, image.width / 2, accuracy: 2, "centred in the window, \(capsule)")
        XCTAssertEqual(capsule.midY, image.height - 56, accuracy: 3, "in the footer, as the mockup, \(capsule)")
        let light = render(container(on: .welcome), appearance: .aqua, settle: 3.6, name: "light-1-welcome")
        let dark = try XCTUnwrap(light.choiceCapsule(), "the dark capsule on the light window")
        XCTAssertEqual(dark.midX, light.width / 2, accuracy: 2, "centred in light mode too, \(dark)")
    }

    func testTheEnableScreensButtonSitsInTheMiddle() throws {
        let image = render(container(on: .enable, permissions: .init(microphone: .allowed, accessibility: true)),
                           name: "2-enable-both-allowed")
        let capsule = try XCTUnwrap(image.choiceCapsule(), "the Try dictation capsule is drawn")
        XCTAssertEqual(capsule.midX, image.width / 2, accuracy: 2, "centred in the window, \(capsule)")
    }

    /// The pair — Continue with Free, Get Pro, as wide as each other — is centred together: Get Pro starts 6 pt right
    /// of the middle.
    func testTheProScreensPairIsCentred() throws {
        let image = render(container(on: .pro), waitForProHeader: true, name: "4-pro")
        let getPro = try XCTUnwrap(image.choiceCapsule(), "the Get Pro capsule is drawn")
        XCTAssertEqual(getPro.midX, image.width / 2 + 6 + ProScreen.pairWidth / 2, accuracy: 2, "Get Pro, \(getPro)")
    }

    // MARK: - The Pro screen's header

    /// A ceiling for the drawn header, not a fixed settle: the main run loop can lag under load.
    private static let proArrivalTimeout: TimeInterval = 10

    /// Owner 2026-10-25: the billing line and "Included with Pro — no API keys" were filler. Nothing is drawn between
    /// the price and the tiles: what comes next under the price row is the first row of tiles, 16 pt or more below.
    func testNothingSitsBetweenThePriceAndTheTiles() throws {
        let image = render(container(on: .pro), waitForProHeader: true, name: "4-pro-arrived")
        let bands = image.inkBands(x: 60...660, y: 40...480, background: CGPoint(x: 20, y: 300))
        XCTAssertGreaterThanOrEqual(bands.count, 3, "the chip, the price row, the tiles: \(bands)")
        XCTAssertGreaterThanOrEqual(bands[2].lowerBound - bands[1].upperBound, 16, "under the price: \(bands)")
    }

    /// The header arrives (owner 2026-10-25): in the first frame nothing of it is drawn — not the chip, not the price,
    /// not the saving — while the tiles are; once it has arrived, the chip and the price are there, and the saving in
    /// its green.
    func testTheProHeaderArrives() throws {
        let done = render(container(on: .pro), waitForProHeader: true, name: "4-pro-arrived")
        let ground = CGPoint(x: 20, y: 300)
        let bands = done.inkBands(x: 60...660, y: 40...480, background: ground)
        XCTAssertGreaterThanOrEqual(bands.count, 3, "\(bands)")
        let header = 40...(bands[2].lowerBound - 4), tiles = bands[2]
        XCTAssertGreaterThan(done.greenPixels(x: 60...660, y: header), 200, "the saving, drawn")
        let first = render(container(on: .pro), settle: 0, name: "4-pro-first-frame")
        XCTAssertFalse(first.inkRows(x: 60...660, y: tiles, background: ground).isEmpty, "the tiles from the start")
        XCTAssertEqual(first.inkRows(x: 60...660, y: header, background: ground), [], "the header not yet")
        XCTAssertEqual(first.greenPixels(x: 60...660, y: header), 0, "nor the saving")
    }

    // MARK: - The permission rows and the practice's words

    /// "Use the shortcut and insert text in other apps." stays on one line beside its button, as the mockup has it:
    /// under the Accessibility row's title, one band of words — two when it broke (a spacer's 12 pt and a second gap).
    func testTheAccessibilityLineStaysOnOneLine() {
        let image = render(container(on: .enable, permissions: .init(microphone: .allowed, accessibility: false)),
                           name: "2-enable-mic-only")
        let bands = image.inkBands(x: 124...420, y: 290...420, background: CGPoint(x: 64, y: 300))
        XCTAssertEqual(bands.count, 2, "the row's title and one line of words: \(bands)")
    }

    /// A sentence sits in the middle of the 236 pt box, as the mockup draws it.
    func testAShortResultSitsInTheMiddleOfTheBox() throws {
        let box = renderPlain(size: TryVoiceScreen.boxSize, name: "3-box-result-alone") {
            Self.box(.result("Send the notes tomorrow morning."))
        }
        let rows = box.inkRows(x: 30...330, y: 6...230, background: CGPoint(x: 12, y: 118))
        let first = try XCTUnwrap(rows.first), last = try XCTUnwrap(rows.last)
        XCTAssertEqual((first + last) / 2, 118, accuracy: 8, "the heading and the words, centred: \(first)…\(last)")
    }

    /// A long text starts at the top and scrolls in the room above Try again: nothing of it below 172 pt, where a
    /// text set in full would run on to the box's edge.
    func testALongResultScrollsAboveTryAgain() throws {
        let box = renderPlain(size: TryVoiceScreen.boxSize, name: "3-box-result-long-alone") {
            Self.box(.result(String(repeating: "A long sentence that keeps going and going. ", count: 12)))
        }
        let rows = box.inkRows(x: 30...330, y: 6...230, background: CGPoint(x: 12, y: 118))
        let first = try XCTUnwrap(rows.first)
        XCTAssertLessThan(first, 40, "from the top")
        XCTAssertTrue(rows.allSatisfy { $0 < 176 }, "inside the scroll, above Try again: \(rows.last ?? 0)")
    }

    private static func box(_ box: TryVoiceScreen.Box) -> some View {
        TryVoiceScreen.BoxView(box: box, level: 0, record: {}, tryAgain: {}, retryModel: {}, signIn: {}, skip: {})
    }

    // MARK: - Every screen, to look at

    func testEveryScreenRenders() throws {
        // 2 — the permissions, in each combination the rows draw.
        let combinations: [(String, OnboardingPermissions)] = [
            ("2-enable-nothing", .init(microphone: .notAsked, accessibility: false)),
            ("2-enable-mic-only", .init(microphone: .allowed, accessibility: false)),
            ("2-enable-mic-denied", .init(microphone: .denied, accessibility: false)),
        ]
        for (name, permissions) in combinations {
            _ = render(container(on: .enable, permissions: permissions), name: name)
        }
        let waiting = flow(on: .enable, permissions: .init(microphone: .allowed, accessibility: false))
        waiting.accessibilityButton()
        _ = render(container(waiting), name: "2-enable-ax-waiting")
        waiting.appBecameActive()
        _ = render(container(waiting), name: "2-enable-ax-not-on-yet")

        // 3 — the practice: ready, the model on its way, the model not got.
        try fixture.putOnDisk(["base"])
        fixture.load("base")
        _ = render(container(on: .practice), name: "3-try-ready")
        _ = render(container(on: .practice, permissions: .init(microphone: .allowed, accessibility: false)),
                   name: "3-try-ready-no-ax")
        fixture.coordinator.whisperEngine = nil
        fixture.coordinator.loadedWhisperModelId = nil
        fixture.manager.isDownloading = true
        fixture.manager.downloadProgress = 0.42
        _ = render(container(on: .practice), name: "3-try-preparing")
        fixture.manager.isDownloading = false
        fixture.manager.phase = .failed("offline")
        _ = render(container(on: .practice), name: "3-try-model-failed")

        // 3 — the box's other states.
        let boxes: [(String, TryVoiceScreen.Box)] = [
            ("3-box-listening", .recorder(listening: true, hint: "or tap Right ⌘ again")),
            ("3-box-transcribing", .transcribing),
            ("3-box-result", .result("Send the notes tomorrow morning.")),
            ("3-box-result-long", .result(String(repeating: "A long sentence that keeps going and going. ", count: 12))),
            ("3-box-no-speech", .noSpeech),
            ("3-box-waiting", .waiting("Finish your dictation first.")),
            ("3-box-failed", .failed("The microphone stopped. Try again.")),
            ("3-box-low-disk", .modelProblem(title: ModelPreparer.lowDiskTitle, detail: ModelPreparer.lowDiskDetail)),
        ]
        for (name, box) in boxes {
            _ = render(TryVoiceScreen.BoxView(box: box, level: 0.4, bars: Array(repeating: 0.5, count: 24),
                                              record: {}, tryAgain: {}, retryModel: {}, signIn: {}, skip: {})
                .frame(width: 720, height: 600).background(OnboardingBackground()), name: name)
        }

        // After — the Dashboard's card, in each state it has.
        let cards: [(String, ModelPreparer.State, RightCommand, Bool, Bool)] = [
            ("5-card-ready-free", .ready, .tap, false, false),
            ("5-card-ready-pro", .ready, .tap, true, true),
            ("5-card-ready-hold", .ready, .hold, false, false),
            ("5-card-ax-off", .ready, .unavailable, false, false),
            ("5-card-downloading", .downloading(0.42), .tap, false, false),
            ("5-card-model-failed", .failed("The speech model didn't download."), .tap, false, false),
            ("5-card-low-disk", .lowDisk, .tap, false, false),
        ]
        for (name, model, rightCommand, cloud, pro) in cards {
            let content = try XCTUnwrap(DashboardReadyCard.content(model: model, rightCommand: rightCommand, cloud: cloud,
                                                                   isPro: pro, hasDictated: false))
            _ = renderPlain(size: CGSize(width: 900, height: 260), name: name) {
                ReadyCardBody(content: content, openAccessibility: {}, tryAgain: {})
                    .padding(40).frame(width: 900, height: 260).background(MW.bg)
            }
        }

        // 4 — Pro, for Free and for a Pro user; and light mode for each screen.
        LicenseService.shared.isPro = true
        _ = render(container(on: .pro), name: "4-pro-you-have-pro")
        LicenseService.shared.isPro = false
        _ = render(container(on: .pro), settle: 1.1, name: "4-pro-counting")
        for screen in OnboardingFlow.Screen.allCases {
            let settle: TimeInterval = screen == .welcome ? 3.6 : 0.3
            _ = render(container(on: screen), appearance: .aqua, settle: settle, waitForProHeader: screen == .pro,
                       name: "light-\(screen.rawValue + 1)")
        }
    }

    // MARK: - Making and drawing

    /// The flows drawn so far; each gives its practice — and the capture arbiter — back before the next is made.
    private var flows: [OnboardingFlow] = []

    private func flow(on screen: OnboardingFlow.Screen,
                      permissions: OnboardingPermissions = .init(microphone: .allowed, accessibility: true)) -> OnboardingFlow {
        flows.forEach { $0.windowClosed() }
        flows.removeAll()
        UserDefaults.standard.set(screen.rawValue, forKey: OnboardingFlow.resumeKey)
        let arbiter = fixture.arbiter
        let flow = OnboardingFlow(environment: .init(
            permissions: { permissions },
            askForMicrophone: { _ in },
            makePractice: { PracticeRecorder(microphone: FakeMicrophone(), engine: { nil }, arbiter: arbiter) },
            openPane: { _ in },
            openAccountPage: { false }),
            finish: { _ in })
        flows.append(flow)
        return flow
    }

    private func container(on screen: OnboardingFlow.Screen,
                           permissions: OnboardingPermissions = .init(microphone: .allowed, accessibility: true))
        -> some View {
        container(flow(on: screen, permissions: permissions))
    }

    private func container(_ flow: OnboardingFlow) -> some View {
        OnboardingContainer(flow: flow, preparer: fixture.preparer, microphone: AudioRecordingService(path: .inputOnly))
    }

    /// The window's whole frame, title bar and content, drawn at the screen's scale after `settle` seconds of run
    /// loop — long enough for the welcome's intro to finish when asked. Arrived Pro renders instead poll the same
    /// window every 0.2 s for the chip, price and green saving, returning the last drawing at the ceiling so the
    /// assertions still fail if the header never arrives. The appearance is the drawing's own as well as the window's,
    /// so the app's colors and SwiftUI's resolve alike.
    private func render(_ view: some View, appearance: NSAppearance.Name = .darkAqua, settle: TimeInterval = 0.3,
                        waitForProHeader: Bool = false, name: String) -> Rendered {
        let look = NSAppearance(named: appearance)!
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = look
        defer { app.appearance = previous }
        let window = OnboardingWindowController.makeWindow(rootView: view)
        window.appearance = look
        if !waitForProHeader { RunLoop.main.run(until: Date().addingTimeInterval(settle)) }
        let frame = window.contentView!.superview!
        let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)!
        let deadline = Date().addingTimeInterval(Self.proArrivalTimeout)
        while true {
            look.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: rep) }
            guard waitForProHeader else { break }
            let image = Rendered(rep: rep, points: frame.bounds.size)
            let bands = image.inkBands(x: 60...660, y: 40...480, background: CGPoint(x: 20, y: 300))
            if bands.count >= 3,
               image.greenPixels(x: 60...660, y: 40...(bands[2].lowerBound - 4)) > 200 { break }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            RunLoop.main.run(until: Date().addingTimeInterval(min(0.2, remaining)))
        }
        window.close()
        if let folder = ProcessInfo.processInfo.environment["MW_RENDER_DIR"] {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return Rendered(rep: rep, points: frame.bounds.size)
    }
}

extension OnboardingRenderTests {
    /// A view on its own, in a borderless window of `size`, drawn as `render` draws the onboarding. The view is made
    /// after the appearance is pinned: the app's colors resolve as they are made (Codex 2026-10-25, P3).
    func renderPlain<Content: View>(size: CGSize, appearance: NSAppearance.Name = .darkAqua, name: String,
                                    @ViewBuilder _ make: () -> Content) -> Rendered {
        let look = NSAppearance(named: appearance)!
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = look
        defer { app.appearance = previous }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = look
        var made: Content?
        look.performAsCurrentDrawingAppearance { made = make() }
        let content = NSHostingView(rootView: made!)
        content.sizingOptions = []
        window.contentView = content
        window.setFrame(NSRect(origin: .zero, size: size), display: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        look.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: rep) }
        window.close()
        if let folder = ProcessInfo.processInfo.environment["MW_RENDER_DIR"] {
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return Rendered(rep: rep, points: content.bounds.size)
    }
}

/// A drawn window, measured in points.
struct Rendered {
    let rep: NSBitmapImageRep
    let points: CGSize

    var width: CGFloat { points.width }
    var height: CGFloat { points.height }
    private var scale: CGFloat { CGFloat(rep.pixelsWide) / points.width }

    private func luminance(_ x: Int, _ y: Int) -> CGFloat {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 0 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// The rows, in points, where something is drawn in the `x` columns: a pixel that differs from the color at
    /// `background` by more than a quarter of the scale.
    func inkRows(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, background: CGPoint) -> [CGFloat] {
        let ground = luminance(Int(background.x * scale), Int(background.y * scale))
        let columns = Int(x.lowerBound * scale)...min(Int(x.upperBound * scale), rep.pixelsWide - 1)
        var rows: [CGFloat] = []
        for row in Int(y.lowerBound * scale)...min(Int(y.upperBound * scale), rep.pixelsHigh - 1)
        where columns.contains(where: { abs(luminance($0, row) - ground) > 0.25 }) {
            rows.append(CGFloat(row) / scale)
        }
        return rows
    }

    /// The pixels in the box drawn in the saving's green: green well above red and blue.
    func greenPixels(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> Int {
        var count = 0
        for row in Int(y.lowerBound * scale)...min(Int(y.upperBound * scale), rep.pixelsHigh - 1) {
            for column in Int(x.lowerBound * scale)...min(Int(x.upperBound * scale), rep.pixelsWide - 1) {
                guard let c = rep.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else { continue }
                if c.greenComponent > 0.5, c.greenComponent - c.redComponent > 0.3,
                   c.greenComponent - c.blueComponent > 0.25 { count += 1 }
            }
        }
        return count
    }

    /// The runs of `inkRows` — a line of words, a title — split where 2 pt or more of the background lies between.
    func inkBands(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>, background: CGPoint) -> [ClosedRange<CGFloat>] {
        var bands: [ClosedRange<CGFloat>] = []
        for row in inkRows(x: x, y: y, background: background) {
            if let last = bands.last, row - last.upperBound < 2 {
                bands[bands.count - 1] = last.lowerBound...row
            } else {
                bands.append(row...row)
            }
        }
        return bands
    }

    /// The enabled choice in the footer — a capsule that stands out from the window's background (light on dark, dark
    /// on light): the columns of the bottom 120 pt where most of a 52 pt height differs from the background by half
    /// the scale, and the rows those columns share. Words, Back and a glass capsule differ far less, or far shorter.
    func choiceCapsule() -> CGRect? {
        let top = Int((points.height - 120) * scale), bottom = rep.pixelsHigh
        let background = luminance(Int(6 * scale), rep.pixelsHigh - Int(56 * scale))
        var columns: [Int] = []
        for x in 0..<rep.pixelsWide {
            var differing = 0
            for y in top..<bottom where abs(luminance(x, y) - background) > 0.45 { differing += 1 }
            if CGFloat(differing) > 30 * scale { columns.append(x) }
        }
        guard let first = columns.first, let last = columns.last else { return nil }
        let middle = (first + last) / 2
        let rows = (top..<bottom).filter { abs(luminance(middle, $0) - background) > 0.45 }
        guard let upper = rows.first, let lower = rows.last else { return nil }
        return CGRect(x: CGFloat(first) / scale, y: CGFloat(upper) / scale,
                      width: CGFloat(last - first + 1) / scale, height: CGFloat(lower - upper + 1) / scale)
    }
}

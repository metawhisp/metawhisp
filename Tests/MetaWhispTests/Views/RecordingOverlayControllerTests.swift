import AppKit
import Combine
import XCTest
@testable import MetaWhisp

@MainActor
final class RecordingOverlayControllerTests: XCTestCase {
    func testEveryStyleUsesAClearPanelWithoutASystemShadow() {
        _ = NSApplication.shared
        for style in ["capsule", "dotglow", "island", "glow", "shrek"] {
            let panel = RecordingOverlayController.makePanel(style: style, screen: NSScreen.main)
            XCTAssertFalse(panel.hasShadow, style)
            XCTAssertFalse(panel.isOpaque, style)
            XCTAssertEqual(panel.backgroundColor, .clear, style)
            XCTAssertEqual(panel.frame.size, RecordingOverlayController.panelSize(
                for: style, screenWidth: NSScreen.main?.frame.width ?? 1440), style)
            XCTAssertFalse(panel.isVisible, style)
        }
    }

    // Stage updates arrive through `RunLoop.main`, which runs only in the default mode. A hide that could
    // run in another mode (a window drag) would remove the indicator of a recording whose update still waits.
    func testDefaultScheduleWaitsInTheSameRunLoopModeAsStageUpdates() {
        _ = NSApplication.shared
        let tracking = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), tracking)
        let keepAlive = Timer(timeInterval: 60, repeats: false) { _ in }
        RunLoop.main.add(keepAlive, forMode: .eventTracking)
        defer { keepAlive.invalidate() }

        var order: [String] = []
        let stage = PassthroughSubject<Int, Never>()
        let delivery = stage.receive(on: RunLoop.main).sink { _ in order.append("stage") }
        defer { delivery.cancel() }
        RecordingOverlayController.defaultSchedule(0, DispatchWorkItem { order.append("hide") })
        stage.send(1)

        let trackingUntil = Date().addingTimeInterval(0.3)
        while Date() < trackingUntil {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(order, [], "nothing may run while the window server tracks a drag")

        let defaultUntil = Date().addingTimeInterval(0.3)
        while Date() < defaultUntil && order.count < 2 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(Set(order), ["stage", "hide"])
    }

    func testPreviewRecordsThenFadesAndStopsAllWork() {
        let fixture = OverlayFixture()
        fixture.overlay.preview(style: "island")
        XCTAssertEqual(fixture.shown.count, 1)
        XCTAssertEqual(fixture.overlay.pillState.style, "island")
        XCTAssertEqual(fixture.overlay.pillState.stage, .recording)

        fixture.clock.advance(by: 2.0)
        XCTAssertEqual(fixture.overlay.pillState.stage, .idle)
        XCTAssertEqual(fixture.active.count, 1)
        XCTAssertEqual(fixture.overlay.pillState.bars, Array(repeating: 0, count: 8))
        XCTAssertEqual(fixture.overlay.pillState.audioLevel, 0)
        fixture.clock.advance(by: 0.8)
        XCTAssertEqual(fixture.hidden.count, 1)
        XCTAssertTrue(fixture.active.isEmpty)
        XCTAssertEqual(fixture.clock.pendingCount, 0)
        fixture.clock.advance(by: 10)
        XCTAssertEqual(fixture.hidden.count, 1)
        XCTAssertEqual(fixture.overlay.pillState.stage, .idle)
        XCTAssertEqual(fixture.overlay.pillState.audioLevel, 0)
        XCTAssertEqual(fixture.overlay.pillState.bars, Array(repeating: 0, count: 8))
    }

    func testPreviewVoiceMovesBetweenTicksAndStaysInRange() {
        let fixture = OverlayFixture()
        fixture.overlay.preview(style: "capsule")
        fixture.clock.advance(by: 1.0 / 30)
        let first = fixture.overlay.pillState.bars
        let firstLevel = fixture.overlay.pillState.audioLevel
        fixture.clock.advance(by: 1.0 / 30)
        XCTAssertNotEqual(fixture.overlay.pillState.bars, first)
        XCTAssertNotEqual(fixture.overlay.pillState.audioLevel, firstLevel)
        for _ in 0..<55 {
            let state = fixture.overlay.pillState
            XCTAssertEqual(state.bars.count, 8)
            XCTAssertTrue(state.bars.allSatisfy { (0...1).contains($0) })
            XCTAssertTrue((0...1).contains(state.audioLevel))
            fixture.clock.advance(by: 1.0 / 30)
        }
        let voice = RecordingOverlayController.previewVoice(at: 0.4)
        XCTAssertEqual(voice.bars, RecordingOverlayController.previewVoice(at: 0.4).bars)
        XCTAssertEqual(voice.audioLevel, RecordingOverlayController.previewVoice(at: 0.4).audioLevel)
    }

    func testRapidStyleChangesNeverOverlapOrReuseEarlierTimers() throws {
        let fixture = OverlayFixture()
        for (index, style) in ["capsule", "dotglow", "island", "glow", "shrek"].enumerated() {
            if index > 0 { fixture.clock.advance(by: 0.1) }
            fixture.overlay.preview(style: style)
            XCTAssertEqual(fixture.active.count, 1, style)
            XCTAssertEqual(fixture.shown.count, index + 1)
            XCTAssertEqual(fixture.hidden.count, index)
        }
        let last = try XCTUnwrap(fixture.shown.last)
        XCTAssertEqual(last.frame.size, CGSize(width: 220, height: 220))
        fixture.clock.advance(by: 1.9)
        XCTAssertEqual(fixture.overlay.pillState.style, "shrek")
        XCTAssertEqual(fixture.overlay.pillState.stage, .recording)
        XCTAssertEqual(fixture.active, [ObjectIdentifier(last)])
        fixture.clock.advance(by: 0.9)
        XCTAssertTrue(fixture.active.isEmpty)
    }

    func testClickingTheSameStyleRestartsPreview() throws {
        let fixture = OverlayFixture()
        fixture.overlay.preview(style: "island")
        let first = try XCTUnwrap(fixture.shown.last)
        fixture.clock.advance(by: 1)
        fixture.overlay.preview(style: "island")
        XCTAssertEqual(fixture.shown.count, 2)
        XCTAssertEqual(fixture.hidden, [first])
        fixture.clock.advance(by: 1.9)
        XCTAssertEqual(fixture.overlay.pillState.stage, .recording)
        XCTAssertEqual(fixture.active.count, 1)
    }

    func testRealStagesBlockPreviewWithoutChangingTheRealPanel() {
        for stage in [PillStage.recording, .processing, .postProcessing] {
            let fixture = OverlayFixture()
            fixture.overlay.handleStageChange(stage)
            let style = fixture.overlay.pillState.style
            let active = fixture.active
            fixture.overlay.preview(style: "shrek")
            XCTAssertEqual(fixture.shown.count, 1)
            XCTAssertTrue(fixture.hidden.isEmpty)
            XCTAssertEqual(fixture.active, active)
            XCTAssertEqual(fixture.overlay.pillState.style, style)
            XCTAssertEqual(fixture.overlay.pillState.stage, stage)
            XCTAssertEqual(fixture.clock.pendingCount, 0)
        }
    }

    func testSelectionTranslationBlocksPreviewUntilHidden() {
        let fixture = OverlayFixture()
        fixture.overlay.showTranslating()
        let style = fixture.overlay.pillState.style
        let active = fixture.active
        fixture.overlay.preview(style: "shrek")
        XCTAssertEqual(fixture.shown.count, 1)
        XCTAssertTrue(fixture.hidden.isEmpty)
        XCTAssertEqual(fixture.active, active)
        XCTAssertEqual(fixture.overlay.pillState.style, style)
        XCTAssertEqual(fixture.overlay.pillState.stage, .postProcessing)
        fixture.overlay.hideTranslating()
        fixture.overlay.preview(style: "island")
        fixture.clock.advance(by: 1.9)
        XCTAssertEqual(fixture.overlay.pillState.stage, .recording)
        XCTAssertEqual(fixture.active.count, 1)
    }

    func testVoiceQuestionBlocksPreviewWithoutChangingState() {
        let fixture = OverlayFixture()
        fixture.voiceQuestionVisible = true
        let style = fixture.overlay.pillState.style
        fixture.overlay.preview(style: "shrek")
        XCTAssertTrue(fixture.shown.isEmpty)
        XCTAssertEqual(fixture.overlay.pillState.style, style)
        XCTAssertEqual(fixture.overlay.pillState.stage, .idle)
        XCTAssertEqual(fixture.clock.pendingCount, 0)
    }

    func testPreviewAfterRecordingCancelsTheRealPendingHide() {
        let fixture = OverlayFixture()
        fixture.overlay.handleStageChange(.recording)
        fixture.overlay.handleStageChange(.idle)
        fixture.overlay.preview(style: "island")
        XCTAssertEqual(fixture.shown.count, 2)
        XCTAssertEqual(fixture.hidden.count, 1)
        fixture.clock.advance(by: 1.9)
        XCTAssertEqual(fixture.overlay.pillState.stage, .recording)
        XCTAssertEqual(fixture.active.count, 1)
    }

    func testRecordingInterruptsPreviewAndOutlivesItsTimers() throws {
        let fixture = OverlayFixture()
        fixture.overlay.preview(style: "island")
        let preview = try XCTUnwrap(fixture.shown.last)
        fixture.clock.advance(by: 0.5)
        fixture.overlay.handleStageChange(.recording)
        XCTAssertEqual(fixture.hidden, [preview])
        XCTAssertEqual(fixture.shown.count, 2)
        let real = try XCTUnwrap(fixture.shown.last)
        XCTAssertEqual(fixture.active, [ObjectIdentifier(real)])
        XCTAssertEqual(fixture.overlay.pillState.audioLevel, 0)
        XCTAssertEqual(fixture.overlay.pillState.bars, Array(repeating: 0, count: 8))
        fixture.clock.advance(by: 3)
        XCTAssertEqual(fixture.active, [ObjectIdentifier(real)])
        XCTAssertEqual(fixture.overlay.pillState.stage, .recording)
        XCTAssertEqual(fixture.clock.pendingCount, 0)
    }

    func testRepeatedIdleLeavesPreviewRunning() {
        let fixture = OverlayFixture()
        fixture.overlay.preview(style: "island")
        fixture.clock.advance(by: 0.5)
        fixture.overlay.handleStageChange(.idle)
        fixture.clock.advance(by: 1.4)
        XCTAssertEqual(fixture.overlay.pillState.stage, .recording)
        XCTAssertEqual(fixture.active.count, 1)
        XCTAssertTrue(fixture.hidden.isEmpty)
    }

    func testTranslationInterruptsPreviewUntilExplicitlyHidden() throws {
        let fixture = OverlayFixture()
        fixture.overlay.preview(style: "island")
        let preview = try XCTUnwrap(fixture.shown.last)
        fixture.clock.advance(by: 0.5)
        fixture.overlay.showTranslating()
        XCTAssertEqual(fixture.hidden, [preview])
        XCTAssertEqual(fixture.shown.count, 2)
        XCTAssertEqual(fixture.overlay.pillState.stage, .postProcessing)
        XCTAssertTrue(fixture.overlay.pillState.isTranslating)
        fixture.clock.advance(by: 3)
        XCTAssertEqual(fixture.active.count, 1)
        XCTAssertEqual(fixture.overlay.pillState.stage, .postProcessing)
        fixture.overlay.hideTranslating()
        fixture.clock.advance(by: 0.8)
        XCTAssertTrue(fixture.active.isEmpty)
    }

    func testVoiceQuestionInterruptsPreviewEvenOnIdle() {
        let fixture = OverlayFixture()
        fixture.overlay.preview(style: "island")
        fixture.clock.advance(by: 0.5)
        fixture.voiceQuestionVisible = true
        fixture.overlay.handleStageChange(.idle)
        XCTAssertEqual(fixture.hidden.count, 1)
        XCTAssertTrue(fixture.active.isEmpty)
        fixture.clock.advance(by: 3)
        XCTAssertEqual(fixture.overlay.pillState.stage, .idle)
        XCTAssertEqual(fixture.overlay.pillState.audioLevel, 0)
        XCTAssertEqual(fixture.clock.pendingCount, 0)
    }

    func testStyleTapSavesThenPreviewsEvenWhenAlreadySelected() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Views/Windows/MainSettingsView.swift"))
            .components(separatedBy: "\n")
            .map { String($0.components(separatedBy: "//").first ?? "") }
            .joined(separator: "\n")
        let start = try XCTUnwrap(source.range(of: "private func pillStyleRow("))
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "private var cloudSection:"))
        let row = rest[..<end.lowerBound]
        let tap = try XCTUnwrap(row.range(of: ".onTapGesture {"))
        let body = try XCTUnwrap(row[tap.upperBound...].components(separatedBy: "}").first)
        let save = try XCTUnwrap(body.range(of: "settings.pillStyle = style.value"))
        let preview = try XCTUnwrap(body.range(of: "AppDelegate.shared?.overlay.preview(style: style.value)"))
        XCTAssertLessThan(save.lowerBound, preview.lowerBound)
        XCTAssertFalse(body.contains("if "))
        XCTAssertFalse(body.contains("guard "))
    }

}


@MainActor
private final class OverlayClock {
    private var now: TimeInterval = 0
    private var items: [(time: TimeInterval, work: DispatchWorkItem)] = []

    var pendingCount: Int { items.filter { !$0.work.isCancelled }.count }

    func schedule(_ delay: TimeInterval, _ work: DispatchWorkItem) {
        items.append((now + delay, work))
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let index = items.indices.min(by: { items[$0].time < items[$1].time }),
              items[index].time <= target + 0.000000001 {
            let item = items.remove(at: index)
            now = item.time
            if !item.work.isCancelled { item.work.perform() }
        }
        now = target
    }
}

@MainActor
private final class OverlayFixture {
    let clock = OverlayClock()
    var shown: [NSPanel] = []
    var hidden: [NSPanel] = []
    var active: Set<ObjectIdentifier> = []
    var voiceQuestionVisible = false

    lazy var overlay = RecordingOverlayController(
        schedule: { [unowned self] in clock.schedule($0, $1) },
        show: { [unowned self] panel in
            XCTAssertFalse(panel.isVisible)
            XCTAssertTrue(active.isEmpty, "the previous panel must be hidden before showing another")
            active.insert(ObjectIdentifier(panel))
            shown.append(panel)
        },
        hide: { [unowned self] panel in
            XCTAssertFalse(panel.isVisible)
            XCTAssertNotNil(active.remove(ObjectIdentifier(panel)))
            hidden.append(panel)
        },
        isVoiceQuestionVisible: { [unowned self] in voiceQuestionVisible })

    init() {
        _ = NSApplication.shared
    }
}

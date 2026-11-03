import AppKit
import SwiftUI
import XCTest
@testable import MetaWhisp

/// Hosts only hotkey controls; no account services or visible window are started.
@MainActor
final class MainSettingsHotkeyTests: XCTestCase {
    func testHotkeyControlsLayOutWithoutOrderingAWindow() async {
        let surface = HotkeyControlSurface(state: HotkeyControlState())
        defer { surface.window.close() }
        await surface.update()
        XCTAssertGreaterThan(surface.host.fittingSize.width, 0)
        XCTAssertGreaterThan(surface.host.fittingSize.height, 0)
        XCTAssertFalse(surface.window.isVisible)
        XCTAssertFalse(surface.window.isKeyWindow)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func section(from start: String, to end: String) throws -> String {
        let url = repoRoot.appendingPathComponent("Views/Windows/MainSettingsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .map { String($0.components(separatedBy: "//").first ?? "") }
            .joined(separator: "\n")
        let startRange = try XCTUnwrap(source.range(of: start), "missing settings section")
        let remaining = source[startRange.upperBound...]
        let endRange = try XCTUnwrap(remaining.range(of: end), "missing settings section boundary")
        return String(remaining[..<endRange.lowerBound])
    }

    // The headless host publishes no SwiftUI accessibility tree, so the source guards remain.
    func testModePickerRemainsAvailableForVoiceQuestionsWhenDictationIsOff() throws {
        let hotkeys = try section(from: "static func hotkeyControls(", to: "private static func hotkeyRow(")
        XCTAssertTrue(hotkeys.contains("modeButton(\"TOGGLE\", value: \"toggle\""))
        XCTAssertTrue(hotkeys.contains("modeButton(\"PUSH-TO-TALK\", value: \"pushToTalk\""))
        XCTAssertFalse(hotkeys.contains(".disabled("), "the mode picker must remain usable with dictation off")
        let mode = try section(from: "private static func modeButton(", to: "private var optionsSection:")
        XCTAssertFalse(mode.contains(".disabled("), "the individual mode controls must remain enabled")
        XCTAssertTrue(hotkeys.contains("Toggle: tap for dictation, hold for voice questions."))
        XCTAssertTrue(hotkeys.contains("Push-to-Talk: hold for dictation. Each action has its own switch."))
    }

    func testSharedChipIsANativeControlWithALabelAndLiveState() throws {
        let chip = try section(from: "static func onOffChip(", to: "private let pillStyles:")
        XCTAssertTrue(chip.contains("Button {"), "native control semantics provide keyboard activation")
        XCTAssertTrue(chip.contains(".buttonStyle(.plain)"), "preserve the existing chip appearance")
        XCTAssertFalse(chip.contains(".onTapGesture"))
        XCTAssertFalse(chip.contains(".disabled("), "the chip must accept activation")
        XCTAssertEqual(chip.components(separatedBy: "isOn.wrappedValue.toggle()").count - 1, 1)
        XCTAssertTrue(chip.contains(".accessibilityLabel(label)"))
        XCTAssertTrue(chip.contains(".accessibilityValue(isOn.wrappedValue ? \"On\" : \"Off\")"),
                      "accessibility must report the current binding state")
    }

    func testEverySharedChipReceivesItsRowLabel() throws {
        let hotkeyRow = try section(from: "private static func hotkeyRow(", to: "private static func hotkeyBadge(")
        let toggleRow = try section(from: "private func toggleRow(", to: "static func onOffChip(")
        XCTAssertTrue(hotkeyRow.contains("onOffChip(action, isOn: isOn)"))
        XCTAssertTrue(toggleRow.contains("Self.onOffChip(label, isOn: isOn)"))
    }
}

@MainActor
private final class HotkeyControlState: ObservableObject {
    @Published var transcribe = false
    @Published var translate = true
    @Published var voiceQuestion = true
    @Published var autoTranslate = true
    @Published var mode = "pushToTalk"
}

@MainActor
private struct HotkeyControlHost: View {
    @ObservedObject var state: HotkeyControlState

    var body: some View {
        MainSettingsView.hotkeyControls(
            transcribe: $state.transcribe,
            translate: $state.translate,
            voiceQuestion: $state.voiceQuestion,
            autoTranslate: $state.autoTranslate,
            mode: $state.mode
        )
    }
}

@MainActor
private final class HotkeyControlSurface {
    let window: NSWindow
    let host: NSHostingView<HotkeyControlHost>

    init(state: HotkeyControlState) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: HotkeyControlHost(state: state))
        window.contentView = host
    }

    func update() async {
        // Yield only for SwiftUI/actor work. There are no elapsed-time assumptions.
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
    }
}

import AppKit
import XCTest
@testable import MetaWhisp

/// The controller's actual panels, cached and composed without ordering a window.
@MainActor
final class MeetingCoachRenderTests: XCTestCase {
    func testRenderMeetingCardStates() async throws {
        guard let folder = ProcessInfo.processInfo.environment["METAWHISP_RENDER_DIR"] else {
            throw XCTSkip("Set METAWHISP_RENDER_DIR to write the meeting card renders.")
        }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try await render("collapsed-empty", in: directory) { $0.setSpeaker(.them) }
        try await render("collapsed-answer", in: directory, configure: publishProposalAnswers)
        try await render("streaming", in: directory) { state in
            state.setThinking(true)
            state.showDraft(MeetingAnswerDraft(requestID: UUID(), generation: 1, kind: .answer,
                heard: "When can you send the proposal?",
                blocks: [.headline("I can send it by Friday afternoon.")]))
        }
        try await render("hover-chips", in: directory, expanded: true, configure: publishProposalAnswers)
        try await render("hover-empty", in: directory, expanded: true) { _ in }
        try await render("ask-open", in: directory, expanded: true) { state in
            state.openAsk()
            state.beginQuestionEditing()
            state.updateQuestionText("How long is the trial?")
        }
        try await render("typed-question", in: directory, expanded: true) { state in
            state.openAsk()
            state.publish(MeetingAnswer(id: UUID(), generation: 1, heard: nil, kind: .answer,
                provenance: .transcript, action: nil,
                blocks: [.headline("The trial lasts two weeks."), .bullet("Review progress after the first week")],
                createdAt: Date(), question: "How long is the trial?"))
        }
        try await render("transcript", in: directory, expanded: true) { state in
            state.transcriptTailProvider = {
                [.init(speaker: .them, text: "What would the rollout look like?", startSample: 0, endSample: 16_000),
                 .init(speaker: .me, text: "Two weeks for setup, then the team goes live.", startSample: 16_000, endSample: 32_000),
                 .init(speaker: .them, text: "When can you send the proposal?", startSample: 32_000, endSample: 48_000)]
            }
            state.selectTab(.transcript)
        }
        try await render("hidden-unseen", in: directory) { state in
            state.hidePanel()
            publishProposalAnswers(state)
        }
        try await render("long-recap", in: directory, expanded: true) { state in
            let section: [MeetingAnswerBlock] = [
                .paragraph("The proposal will cover the agreed scope."),
                .bullet("Include final pricing for both delivery options."),
                .bullet("Attach a draft timeline with review milestones."),
                .paragraph("The trial will help confirm the setup."),
                .bullet("Check access before the trial begins."),
                .bullet("Collect feedback after the first review.")
            ]
            state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .action, provenance: .transcript,
                action: .recap, blocks: Array(repeating: section, count: 6).flatMap { $0 }, createdAt: Date()))
        }
        try await render("dark-appearance", in: directory, expanded: true, dark: true,
                         configure: publishProposalAnswers)
        try await render("header-answers", in: directory, configure: publishProposalAnswers)
        try await render("header-transcript", in: directory) { state in
            state.selectTab(.transcript)
        }
        try await render("header-halted", in: directory, expanded: true) { state in
            state.haltForBalance()
        }
        try await render("busy-retained-answer", in: directory, expanded: true) { state in
            publishProposalAnswers(state)
            state.showBusy(requestID: UUID(), generation: 1)
        }
        try await render("busy-transcript", in: directory, expanded: true) { state in
            state.selectTab(.transcript)
            state.showBusy(requestID: UUID(), generation: 1)
        }
        try await render("stopping", in: directory, expanded: true) { state in
            state.beginStopping()
        }

        for name in ["collapsed-empty", "collapsed-answer", "streaming", "hover-chips", "hover-empty",
                     "ask-open", "typed-question", "transcript", "hidden-unseen", "long-recap", "dark-appearance",
                     "header-answers", "header-transcript", "header-halted", "busy-retained-answer",
                     "busy-transcript", "stopping"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).png").path), name)
        }
    }

    private func publishProposalAnswers(_ state: MeetingCoachState) {
        for headline in ["We can start with a short trial.", "Both delivery options cover the same scope."] {
            state.publish(MeetingAnswer(id: UUID(), heard: nil, kind: .answer, provenance: .transcript,
                action: nil, blocks: [.headline(headline)], createdAt: Date(timeIntervalSince1970: 0)))
        }
        state.publish(MeetingAnswer(id: UUID(), heard: "When can you send the proposal?", kind: .answer,
            provenance: .transcript, action: nil,
            blocks: [.headline("I can send it by Friday afternoon."), .bullet("Final pricing included"),
                     .bullet("Two delivery options"), .bullet("Draft timeline attached")],
            createdAt: Date(timeIntervalSince1970: 0)))
    }

    private func render(_ name: String, in directory: URL, expanded: Bool = false, dark: Bool = false,
                        configure: (MeetingCoachState) -> Void) async throws {
        let state = MeetingCoachState()
        state.arm(generation: 1)
        state.shortcutLabel = "⌃↩"
        state.setSpeaker(.quiet)
        configure(state)
        let wave = MeetingCoachWaveModel()
        wave.receive(me: 0.2, them: 0.8, speaker: state.speaker, at: 0)
        let startedAt = Date().addingTimeInterval(-758)

        // The real view observes this key; restore the user's value after each fixture.
        let defaults = UserDefaults.standard
        let oldScreenSetting = defaults.object(forKey: "screenContextEnabled")
        defaults.set(true, forKey: "screenContextEnabled")
        defer {
            if let oldScreenSetting { defaults.set(oldScreenSetting, forKey: "screenContextEnabled") }
            else { defaults.removeObject(forKey: "screenContextEnabled") }
        }
        let look = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = look
        defer { app.appearance = previous }

        let controller = MeetingCoachWindowController(state: state, ordersWindows: false,
            visibleFrame: { NSRect(x: 0, y: 0, width: 1000, height: 600) },
            recordingStartedAt: { startedAt }, wave: wave)
        controller.show()
        if expanded { controller.pointerEntered(.capsule) }
        defer { controller.hide() }
        let capsule = try XCTUnwrap(controller.capsulePanel)
        let answer = try XCTUnwrap(controller.answerPanel)
        capsule.appearance = look
        answer.appearance = look
        try await Task.sleep(for: .milliseconds(250))
        capsule.contentView?.layoutSubtreeIfNeeded()
        answer.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(capsule.isVisible, name)
        XCTAssertFalse(answer.isVisible, name)
        if controller.isAnswerPresented { XCTAssertTrue(answer.parent === capsule, name) }
        else { XCTAssertNil(answer.parent, name) }
        XCTAssertEqual(answer.frame.maxY, capsule.frame.minY - 8, name)
        if name == "long-recap" {
            XCTAssertEqual(answer.frame.height, controller.availableAnswerHeight)
            XCTAssertTrue(try XCTUnwrap(controller.answerScrollView).hasVerticalScroller)
        }

        let answerHeight = controller.isAnswerPresented ? answer.frame.height : 0
        let capsuleShadow = try XCTUnwrap(controller.capsuleShadowPanel)
        let answerShadow = try XCTUnwrap(controller.answerShadowPanel)
        let padding = capsule.frame.minX - capsuleShadow.frame.minX
        let lowestY = answerHeight > 0 ? answer.frame.minY : capsule.frame.minY
        let canvas = NSRect(x: answer.frame.minX, y: lowestY, width: 392,
                            height: capsule.frame.maxY - lowestY).insetBy(dx: -padding, dy: -padding)
        let size = canvas.size
        let bitmap = try makeBitmap(size)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let capsuleImage = try cache(try XCTUnwrap(capsule.contentView), look: look)
        let answerImage = controller.isAnswerPresented
            ? try cache(try XCTUnwrap(answer.contentView), look: look) : nil
        let capsuleShadowBitmap = try meetingCoachShadowBitmap(try XCTUnwrap(capsuleShadow.contentView as? CardShadowView))
        let answerShadowBitmap = controller.isAnswerPresented
            ? try meetingCoachShadowBitmap(try XCTUnwrap(answerShadow.contentView as? CardShadowView)) : nil
        let capsuleRect = capsule.frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        if let answerShadowBitmap {
            NSImage(cgImage: try XCTUnwrap(answerShadowBitmap.cgImage), size: answerShadow.frame.size)
                .draw(in: answerShadow.frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY))
        }
        NSImage(cgImage: try XCTUnwrap(capsuleShadowBitmap.cgImage), size: capsuleShadow.frame.size)
            .draw(in: capsuleShadow.frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY))
        answerImage?.draw(in: answer.frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY))
        capsuleImage.draw(in: capsuleRect)
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: Int(capsuleRect.midX * 2),
            y: Int((size.height - capsuleRect.maxY + 5) * 2))).alphaComponent, 0.1,
            "\(name): capsule must remain centered in the composition")
        if answerHeight > 0 {
            let gapCenter = NSPoint(x: capsule.frame.midX, y: answer.frame.maxY + 4)
            XCTAssertFalse(capsule.frame.contains(gapCenter) || answer.frame.contains(gapCenter),
                           "\(name): shadows may draw in the gap, but no interactive window may cover it")
        }
        if name == "collapsed-empty" || name == "hidden-unseen" {
            // A 12-point speaker label fits one centered line in the 34-point capsule.
            // Ink in these upper/lower bands catches wrapping or vertical truncation.
            var wrappedLabelPixels = 0
            let left = Int(capsuleRect.minX * 2)
            let top = Int((size.height - capsuleRect.maxY) * 2)
            for y in Array((top + 8)..<(top + 18)) + Array((top + 50)..<(top + 60)) {
                for x in (left + 240)..<(left + 304) {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.65,
                       color.alphaComponent > 0.9 { wrappedLabelPixels += 1 }
                }
            }
            XCTAssertEqual(wrappedLabelPixels, 0, "\(name): speaker label must not wrap")
        }
        XCTAssertFalse(capsule.isVisible, name)
        XCTAssertFalse(answer.isVisible, name)
        let destination = directory.appendingPathComponent("\(name).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination, options: .atomic)
        let written = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: destination)))
        XCTAssertEqual(written.pixelsWide, Int(size.width * 2), name)
        XCTAssertEqual(written.pixelsHigh, Int(size.height * 2), name)
    }

    private func cache(_ view: NSView, look: NSAppearance) throws -> NSImage {
        let bitmap = try makeBitmap(view.bounds.size)
        look.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        return NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: view.bounds.size)
    }

    private func makeBitmap(_ size: NSSize) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        return bitmap
    }
}

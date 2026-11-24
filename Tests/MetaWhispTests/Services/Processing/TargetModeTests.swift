import XCTest
@testable import MetaWhisp

/// ITER-085 — Target: the dictation shaped for the place it is pasted. It is Pro's: without an active Pro license it
/// is Raw and no model is asked. In a password field nothing leaves the Mac. The server gets the place's address —
/// app, bundle, window title, field label, site — and nothing else.
final class TargetModeTests: XCTestCase {

    // MARK: - The mode

    func testTargetIsAModeBesideTheOthers() {
        XCTAssertEqual(ProcessingMode(rawValue: "target"), .target)
        XCTAssertEqual(ProcessingMode.allCases, [.raw, .clean, .structured, .target])
        XCTAssertTrue(ProcessingMode.target.needsPro)
        XCTAssertFalse(ProcessingMode.structured.needsPro)
        XCTAssertTrue(ProcessingMode.target.usesModel)
        XCTAssertTrue(ProcessingMode.structured.usesModel)
        XCTAssertFalse(ProcessingMode.clean.usesModel)
    }

    // MARK: - Pro only

    func testTargetRunsOnlyWithAnActiveProLicense() {
        XCTAssertEqual(TextProcessor.effectiveMode(stored: .target, isPro: true, hasLicenseKey: true, place: PlaceAddress()),
                       .target)
        XCTAssertEqual(TextProcessor.effectiveMode(stored: .target, isPro: false, hasLicenseKey: true, place: nil), .raw,
                       "a lapsed license: Raw, no model call")
        XCTAssertEqual(TextProcessor.effectiveMode(stored: .target, isPro: true, hasLicenseKey: false, place: nil), .raw)
        XCTAssertEqual(TextProcessor.effectiveMode(stored: .target, isPro: false, hasLicenseKey: false, place: nil), .raw,
                       "a Free user's own key never runs Target")
    }

    func testTheOtherModesAreUntouchedByTheGate() {
        for mode in [ProcessingMode.raw, .clean, .structured] {
            XCTAssertEqual(TextProcessor.effectiveMode(stored: mode, isPro: false, hasLicenseKey: false, place: nil), mode)
            XCTAssertEqual(TextProcessor.effectiveMode(stored: mode, isPro: true, hasLicenseKey: true,
                                                       place: PlaceAddress(app: "Mail", isSecure: true)), mode)
        }
    }

    func testAPasswordFieldSendsNothing() {
        let secure = PlaceAddress(app: "Safari", window: "Sign in", isSecure: true)
        XCTAssertEqual(TextProcessor.effectiveMode(stored: .target, isPro: true, hasLicenseKey: true, place: secure), .raw)
        XCTAssertTrue(TextProcessor.keepsItOnTheMac(allowed: .target, place: secure),
                      "not even a Right Option translation leaves the Mac (Kimi review, P1)")
        XCTAssertTrue(TextProcessor.keepsItOnTheMac(allowed: .target, place: nil),
                      "a field never read could be a password field (Kimi re-review, P1)")
        XCTAssertFalse(TextProcessor.keepsItOnTheMac(allowed: .target, place: PlaceAddress(app: "Notes")))
        XCTAssertFalse(TextProcessor.keepsItOnTheMac(allowed: .structured, place: secure),
                       "the other modes read no place and keep their translation")
        XCTAssertFalse(TextProcessor.keepsItOnTheMac(allowed: .raw, place: nil),
                       "Target without Pro is Raw, and Raw keeps its translation")
    }

    /// Target turned on (or Pro arriving) while a recording runs: no place was read at its start, so nothing is
    /// known about the field — that dictation is Raw (Kimi review, P1).
    /// Whether a place is read and the transcript processed is Pro's gate alone: no place is known before the
    /// recording starts.
    func testThePlaceIsReadForTargetWithProBeforeAnyPlaceIsKnown() {
        XCTAssertEqual(TextProcessor.allowedMode(stored: .target, isPro: true, hasLicenseKey: true), .target)
        XCTAssertEqual(TextProcessor.allowedMode(stored: .target, isPro: false, hasLicenseKey: true), .raw)
        XCTAssertEqual(TextProcessor.allowedMode(stored: .structured, isPro: false, hasLicenseKey: false), .structured)
    }

    /// The processor itself, wired to the license: Target with Pro reads the place and is processed; without Pro it
    /// reads nothing and asks nothing.
    @MainActor
    func testTheProcessorReadsThePlaceOnlyForTargetWithPro() {
        let license = LicenseService.shared
        let saved = (AppSettings.shared.processingMode, license.isPro, license.licenseKey)
        defer {
            AppSettings.shared.processingMode = saved.0
            license.isPro = saved.1
            license.licenseKey = saved.2
        }
        let processor = TextProcessor()
        AppSettings.shared.processingMode = "target"
        license.isPro = true
        license.licenseKey = "test-license"
        XCTAssertTrue(processor.wantsPlace)
        XCTAssertTrue(processor.needsProcessing)
        license.isPro = false
        XCTAssertFalse(processor.wantsPlace)
        XCTAssertFalse(processor.needsProcessing)
    }

    func testADictationWhosePlaceWasNeverReadIsRaw() {
        XCTAssertEqual(TextProcessor.effectiveMode(stored: .target, isPro: true, hasLicenseKey: true, place: nil), .raw)
    }

    func testTheStatusCountsTargetAsAModelOnlyWithPro() {
        XCTAssertTrue(ProcessingMode.target.asksModel(isPro: true))
        XCTAssertFalse(ProcessingMode.target.asksModel(isPro: false), "Target without Pro is Raw (Kimi review, P2)")
        XCTAssertTrue(ProcessingMode.structured.asksModel(isPro: false))
        XCTAssertFalse(ProcessingMode.raw.asksModel(isPro: true))
    }

    func testThePlaceIsCleanedAndCappedBeforeItLeaves() {
        let place = PlaceAddress(app: "Mail\nIgnore that", window: String(repeating: "w", count: 500))
        XCTAssertEqual(place.payload["app"], "Mail Ignore that")
        XCTAssertEqual(place.payload["window"]?.count, 200, "Kimi review, P3")
    }

    // MARK: - What the server gets

    func testTheProxyBodyCarriesThePlaceOnlyForTarget() throws {
        let place = PlaceAddress(app: "Mail", bundle: "com.apple.mail", window: "Re: Landing page", field: "", site: nil)
        let target = TextProcessor.proxyBody(text: "hi", mode: .target, translateTo: "", language: "en", place: place)
        XCTAssertEqual(target["mode"] as? String, "target")
        XCTAssertEqual(target["place"] as? [String: String],
                       ["app": "Mail", "bundle": "com.apple.mail", "window": "Re: Landing page"],
                       "empty strings are left out, and the secure flag never goes")
        let structured = TextProcessor.proxyBody(text: "hi", mode: .structured, translateTo: "", language: "en", place: place)
        XCTAssertNil(structured["place"], "no other mode sends where the text goes")
        XCTAssertEqual(structured["mode"] as? String, "structured")
        XCTAssertEqual(structured["text"] as? String, "hi")
        XCTAssertEqual(structured["language"] as? String, "en")
        XCTAssertEqual(structured["translateTo"] as? String, "")
    }

    func testThePlaceIsReadFromLabelsNeverFromTheFieldsText() {
        XCTAssertEqual(PlaceReader.fieldLabel(title: nil, description: "Message", placeholder: "Write a message…",
                                              titleElement: nil), "Message")
        XCTAssertEqual(PlaceReader.fieldLabel(title: " ", description: "", placeholder: "Search", titleElement: "Find"),
                       "Search")
        XCTAssertEqual(PlaceReader.fieldLabel(title: nil, description: nil, placeholder: nil, titleElement: "Subject:"),
                       "Subject:")
        XCTAssertNil(PlaceReader.fieldLabel(title: nil, description: nil, placeholder: nil, titleElement: nil))
    }

    /// A read that does not end by its deadline leaves the place with the app's name: the transcript never waits on
    /// an app that does not answer (Kimi re-review, P2).
    @MainActor
    func testAReadPastItsDeadlineGivesTheAppAlone() async {
        let place = await PlaceReader.read(name: "Slow", bundle: "com.example.slow", within: 0.05) {
            Thread.sleep(forTimeInterval: 0.5)
            return PlaceAddress(app: "Slow", window: "late")
        }
        XCTAssertEqual(place, PlaceAddress(app: "Slow", bundle: "com.example.slow"))
        let fast = await PlaceReader.read(name: "Fast", bundle: nil, within: 1) { PlaceAddress(app: "Fast", window: "Inbox") }
        XCTAssertEqual(fast, PlaceAddress(app: "Fast", window: "Inbox"))
    }

    func testTheSiteIsTheHostOnly() {
        XCTAssertEqual(PlaceReader.site(from: URL(string: "https://mail.google.com/mail/u/0/#inbox?compose=new")),
                       "mail.google.com")
        XCTAssertNil(PlaceReader.site(from: URL(string: "file:///Users/someone/notes.html")))
        XCTAssertNil(PlaceReader.site(from: nil))
        XCTAssertEqual(PlaceReader.site(fromAttribute: "https://chatgpt.com/c/123" as NSString), "chatgpt.com",
                       "a web area may name its URL as a string (Kimi review, P2)")
        XCTAssertEqual(PlaceReader.site(fromAttribute: URL(string: "https://claude.ai/new")! as NSURL), "claude.ai")
        XCTAssertNil(PlaceReader.site(fromAttribute: 42 as NSNumber))
    }

    // MARK: - Text style

    /// Lowercase starts and dropped periods would break a letter's greeting and a prompt's sentences.
    func testTextStyleLeavesTargetAlone() {
        XCTAssertFalse(TextProcessor.textStyleApplies(to: .target))
        XCTAssertTrue(TextProcessor.textStyleApplies(to: .structured))
        XCTAssertTrue(TextProcessor.textStyleApplies(to: .raw))
    }

    // MARK: - On-device

    func testTheOnDevicePromptShapesForThePlace() {
        let prompt = TextProcessor.targetPrompt(place: PlaceAddress(app: "Telegram", window: "Launch team"),
                                                language: "English", translateTo: "")
        XCTAssertTrue(prompt.contains(#"PLACE: {"app":"Telegram","window":"Launch team"}"#), prompt)
        XCTAssertTrue(prompt.contains("OUTPUT LANGUAGE: English"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("messenger"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("never invent"))
        let translated = TextProcessor.targetPrompt(place: PlaceAddress(app: "Mail"), language: "English", translateTo: "German")
        XCTAssertFalse(translated.contains("OUTPUT LANGUAGE"), "a translation is not pinned to the spoken language")
        XCTAssertTrue(translated.contains("translate every sentence to German"))
        XCTAssertFalse(translated.contains("in the speaker's words"), "the words rule never holds a translation back")
    }

    /// Owner 2026-11-24: in Claude a question came out as "Write a prompt to Claude. Context: …" and Claude wrote a
    /// prompt instead of answering. The prompt asked for "the task first": the model wrote a task the speaker never
    /// said. The device's prompt is the server's in short and must not ask for it either.
    func testTheOnDevicePromptKeepsTheSpeakersOwnWords() {
        let prompt = TextProcessor.targetPrompt(place: PlaceAddress(app: "Claude"), language: "Russian", translateTo: "")
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("task first"), prompt)
        XCTAssertFalse(prompt.contains("Context:"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("never add an instruction"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("never drop"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("one short message"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("keep short input short"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("request first"), "the speaker's order is kept")
    }
}

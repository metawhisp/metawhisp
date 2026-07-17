import XCTest
@testable import MetaWhisp

/// Corner-case coverage for `TaskExtractionFilters` — the pure-function gate
/// that decides which screen-extracted candidates become tasks. Had ZERO
/// tests before 2026-05-28 despite gating every task the user sees.
///
/// User reported "tasks тоже хуета" (2026-05-28). These tests pin the
/// current behaviour AND surface logic gaps (see DEAD-CODE finding on
/// `validateTaskTitle` vagueVerb branch).
final class TaskExtractionFiltersTests: XCTestCase {

    // MARK: - isGenericNoise

    func test_genericNoise_respondToMessages_isNoise() {
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Respond to messages"))
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Respond to message"))
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Reply to messages"))
    }

    func test_genericNoise_sendDaily_isNoise() {
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Send daily"))
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Send message"))
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Create music"))
    }

    func test_genericNoise_caseInsensitive() {
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("RESPOND TO MESSAGES"))
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Send Daily"))
    }

    func test_genericNoise_leadingTrailingWhitespace() {
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("   send daily   "))
    }

    func test_genericNoise_concreteSubject_isNotNoise() {
        XCTAssertFalse(TaskExtractionFilters.isGenericNoise("Respond to Mike about the contract"))
        XCTAssertFalse(TaskExtractionFilters.isGenericNoise("Create music video for the launch"))
        XCTAssertFalse(TaskExtractionFilters.isGenericNoise("Send the quarterly invoice to finance"))
    }

    func test_genericNoise_emptyString_isNotNoise() {
        XCTAssertFalse(TaskExtractionFilters.isGenericNoise(""))
    }

    func test_genericNoise_askAboutFreeSlots_isNoise() {
        // Matches `^ask about free slots?$` and `^ask about [word] slots?$`.
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Ask about free slots"))
        XCTAssertTrue(TaskExtractionFilters.isGenericNoise("Ask about meeting slots"))
    }

    /// COVERAGE GAP (documented, not a bug): bare "Ask about slots" (no word
    /// between "about" and "slots") does NOT match genericRejectPatterns —
    /// the patterns require a filler word. It's harmless because it's only
    /// 3 words → caught by `validateTaskTitle` .tooShort instead.
    func test_genericNoise_bareAskAboutSlots_notMatchedByPatterns() {
        XCTAssertFalse(TaskExtractionFilters.isGenericNoise("Ask about slots"))
        // …but the title validator catches it:
        guard case .tooShort = TaskExtractionFilters.validateTaskTitle("Ask about slots") else {
            return XCTFail("3-word title should hit tooShort")
        }
    }

    // MARK: - validateTaskTitle

    func test_validateTitle_empty_rejected() {
        guard case .empty = TaskExtractionFilters.validateTaskTitle("") else {
            return XCTFail("empty title should reject with .empty")
        }
    }

    func test_validateTitle_whitespaceOnly_rejected() {
        guard case .empty = TaskExtractionFilters.validateTaskTitle("   \t  ") else {
            return XCTFail("whitespace-only title should reject with .empty")
        }
    }

    func test_validateTitle_singleWord_tooShort() {
        guard case .tooShort(let n) = TaskExtractionFilters.validateTaskTitle("Fix") else {
            return XCTFail("single word should be tooShort")
        }
        XCTAssertEqual(n, 1)
    }

    func test_validateTitle_threeWords_tooShort() {
        guard case .tooShort(let n) = TaskExtractionFilters.validateTaskTitle("Update the homepage") else {
            return XCTFail("3 words should be tooShort")
        }
        XCTAssertEqual(n, 3)
    }

    func test_validateTitle_fourWords_valid() {
        XCTAssertNil(TaskExtractionFilters.validateTaskTitle("Update the homepage design"))
    }

    func test_validateTitle_russianFourWords_valid() {
        XCTAssertNil(TaskExtractionFilters.validateTaskTitle("Отправить контракт Майку срочно"))
    }

    func test_validateTitle_russianTwoWords_tooShort() {
        guard case .tooShort = TaskExtractionFilters.validateTaskTitle("написать письмо") else {
            return XCTFail("2 RU words should be tooShort")
        }
    }

    /// DEAD-CODE FINDING (2026-05-28): the `vagueVerb` rejection requires
    /// `wordCount <= 3`, but `wordCount < 4` already returns `.tooShort`
    /// earlier in the function — so the vagueVerb branch is UNREACHABLE.
    /// A 4+ word title that starts with a banned solo verb ("Check the auth
    /// logs now") is NOT rejected as vagueVerb — it passes as valid.
    /// This test pins that current (buggy) behaviour so the fix is explicit.
    /// FIX OPTIONS: (a) remove dead vagueVerb code; (b) change its guard to
    /// fire on 4+ word titles led by a vague verb with no concrete object.
    func test_validateTitle_vagueVerbBranch_isDeadCode_currentlyPasses() {
        // 5 words, starts with banned verb "check" → SHOULD arguably be
        // vagueVerb, but currently returns nil (valid) because the branch
        // is unreachable.
        XCTAssertNil(
            TaskExtractionFilters.validateTaskTitle("Check the auth logs now"),
            "Documents dead-code bug: vagueVerb never fires for 4+ word titles"
        )
    }

    /// A <4 word banned-verb title is caught by tooShort, not vagueVerb.
    func test_validateTitle_shortBannedVerb_caughtByTooShort_notVagueVerb() {
        // "Check logs" = 2 words → tooShort wins (vagueVerb dead).
        guard case .tooShort = TaskExtractionFilters.validateTaskTitle("Check logs") else {
            return XCTFail("2-word banned-verb title hits tooShort, not vagueVerb")
        }
    }

    // MARK: - isTaskAllowed (ITER-057.5 whitelist)

    func test_allowed_messengers() {
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "Telegram", windowTitle: nil))
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "Slack", windowTitle: nil))
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "Mattermost", windowTitle: nil))
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "Messages", windowTitle: nil))
    }

    func test_allowed_whatsApp_withLeadingLTRMark() {
        // WhatsApp reports "\u{200E}WhatsApp" — the invisible mark must not break the match.
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "\u{200E}WhatsApp", windowTitle: nil))
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "WhatsApp", windowTitle: nil))
    }

    func test_allowed_bundleIdMatch() {
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "X", windowTitle: nil, bundleId: "com.tinyspeck.slackmacgap"))
    }

    func test_allowed_caseInsensitiveFallback() {
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "telegram", windowTitle: nil))
    }

    func test_notAllowed_selfAIAssistantsIDEs() {
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "MetaWhisp", windowTitle: nil))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "Claude", windowTitle: nil))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "ChatGPT", windowTitle: nil))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "Xcode", windowTitle: nil))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "Cursor", windowTitle: nil))
    }

    func test_notAllowed_systemDialogs() {
        // The exact junk sources found in the founder's DB ("Allow keychain access for xctest").
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "SecurityAgent", windowTitle: "xctest"))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "UserNotificationCenter", windowTitle: nil))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "Finder", windowTitle: "Downloads"))
    }

    func test_browser_requiresWorkSignalTitle() {
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "Google Chrome", windowTitle: "Inbox (3) - Gmail"))
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "Safari", windowTitle: "MW-42 fix promo — Jira"))
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "Arc", windowTitle: "Telegram Web"))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "Google Chrome", windowTitle: "YouTube"))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "Google Chrome", windowTitle: nil))
        XCTAssertFalse(TaskExtractionFilters.isTaskAllowed(appName: "Safari", windowTitle: "   "))
    }

    func test_browser_titleKeywordCaseInsensitive() {
        XCTAssertTrue(TaskExtractionFilters.isTaskAllowed(appName: "Google Chrome", windowTitle: "my GITHUB pull requests"))
    }

    // MARK: - isNearDuplicate

    func test_nearDup_exactMatch() {
        XCTAssertTrue(TaskExtractionFilters.isNearDuplicate("Fix the SEO issue", against: ["Fix the SEO issue"]))
    }

    func test_nearDup_fuzzyWordOverlap() {
        // "Fix Example Project SEO" vs "Fix Example Project SEO issue" → high overlap
        XCTAssertTrue(TaskExtractionFilters.isNearDuplicate(
            "Fix Example Project SEO",
            against: ["Fix Example Project SEO issue"]
        ))
    }

    func test_nearDup_belowThreshold_notDuplicate() {
        XCTAssertFalse(TaskExtractionFilters.isNearDuplicate(
            "Deploy the backend service",
            against: ["Write marketing copy"]
        ))
    }

    func test_nearDup_emptyCandidate_notDuplicate() {
        XCTAssertFalse(TaskExtractionFilters.isNearDuplicate("", against: ["anything here"]))
    }

    func test_nearDup_emptyAgainstList_notDuplicate() {
        XCTAssertFalse(TaskExtractionFilters.isNearDuplicate("Fix the thing", against: []))
    }

    func test_nearDup_stopwordsOnly_notDuplicate() {
        // "the and for" tokenizes to empty (all stopwords) → not duplicate.
        XCTAssertFalse(TaskExtractionFilters.isNearDuplicate("the and for", against: ["the and for"]))
    }

    func test_nearDup_russianOverlap() {
        XCTAssertTrue(TaskExtractionFilters.isNearDuplicate(
            "Отправить контракт клиенту",
            against: ["Отправить контракт клиенту сегодня"]
        ))
    }

    func test_nearDup_customThreshold() {
        // 50% overlap fires at threshold 0.5 but not 0.7.
        let candidate = "alpha beta gamma delta"
        let existing = ["alpha beta epsilon zeta"]  // 2/4 = 0.5 overlap
        XCTAssertTrue(TaskExtractionFilters.isNearDuplicate(candidate, against: existing, threshold: 0.5))
        XCTAssertFalse(TaskExtractionFilters.isNearDuplicate(candidate, against: existing, threshold: 0.7))
    }

    // MARK: - Constants sanity

    func test_thresholdConstants() {
        XCTAssertEqual(TaskExtractionFilters.minRelevanceScore, 75)
        XCTAssertEqual(TaskExtractionFilters.minEvidenceChars, 20)
    }
}

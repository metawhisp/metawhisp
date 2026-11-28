import XCTest
@testable import MetaWhisp

/// FEAT-0005 §4 — what an automatic task suggestion must pass after the model answers.
/// The audit of 551 automatic tasks on the owner's Mac (2026-11-25) found 44 real ones: instructions to AI tools,
/// repeats, screen text and invented owners made the rest. These pin each rule on cases of those shapes.
@MainActor
final class TaskCandidateRulesTests: XCTestCase {

    private typealias Rules = TaskCandidateRules
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private var t0: Date { now.addingTimeInterval(-3_600) }

    private func item(_ description: String,
                      kind: String? = "mine",
                      evidence: String? = nil,
                      dueAt: Date? = nil,
                      assignee: String? = nil,
                      capture: Double? = 0.9,
                      ownership: Double? = 0.9,
                      concrete: Bool? = true,
                      realWorld: Bool? = true) -> Rules.Candidate {
        Rules.Candidate(description: description, kind: kind, evidence: evidence, dueAt: dueAt, assignee: assignee,
                        captureConfidence: capture, ownershipConfidence: ownership,
                        concreteDeliverable: concrete, realWorld: realWorld)
    }

    private func run(_ candidates: [Rules.Candidate],
                     source: Rules.Source = .dictation,
                     fragments: [String],
                     existing: [Rules.Existing] = []) -> Rules.Outcome {
        let spoken = fragments.enumerated().map {
            Rules.Fragment(text: $0.element, at: t0.addingTimeInterval(Double($0.offset) * 60))
        }
        return Rules.apply(candidates, source: source, fragments: spoken, existing: existing, now: now)
    }

    private func reasons(_ outcome: Rules.Outcome) -> [Rules.DropReason] { outcome.dropped.map(\.reason) }

    // MARK: - K1 confidence floors and a concrete deliverable

    func testBothConfidencesAtTheFloorWithAConcreteDeliverablePass() {
        let o = run([item("Send the signed contract to Sam", evidence: "send Sam the signed contract",
                           capture: 0.8, ownership: 0.8)],
                    fragments: ["Remind me to send Sam the signed contract tomorrow."])
        XCTAssertEqual(o.kept.count, 1)
    }

    func testAConfidenceBelowTheFloorIsDropped() {
        let o = run([item("Send the signed contract to Sam", evidence: "send Sam the signed contract",
                           capture: 0.9, ownership: 0.79)],
                    fragments: ["Remind me to send Sam the signed contract tomorrow."])
        XCTAssertEqual(reasons(o), [.belowFloor])
    }

    func testAVagueCommitmentWithoutADeliverableIsDropped() {
        let o = run([item("Handle the Sarah thing", evidence: "handle the Sarah thing", concrete: false)],
                    source: .call, fragments: ["Me: I will handle the Sarah thing."])
        XCTAssertEqual(reasons(o), [.belowFloor])
    }

    /// An answer in the old shape (no confidences, no flags) parses but gives nothing.
    func testAnItemWithoutTheNewFieldsIsDropped() {
        let o = run([item("Call the dentist", kind: nil, evidence: nil, capture: nil, ownership: nil,
                           concrete: nil, realWorld: nil)],
                    fragments: ["I need to call the dentist."])
        XCTAssertEqual(reasons(o), [.unknownKind])
        let o2 = run([item("Call the dentist about the appointment", evidence: "call the dentist",
                            capture: nil, ownership: nil, concrete: nil)],
                     fragments: ["I need to call the dentist."])
        XCTAssertEqual(reasons(o2), [.belowFloor])
    }

    func testAnUnknownKindIsDropped() {
        let o = run([item("Send the deck to the board", kind: "maybe", evidence: "send the deck to the board")],
                    fragments: ["I should send the deck to the board."])
        XCTAssertEqual(reasons(o), [.unknownKind])
    }

    // MARK: - R4 dictation keeps requests, promises and real-world actions

    func testAnInstructionToAnAIToolInADictationIsDropped() {
        let o = run([item("Make the header text larger on the landing page", evidence: "make the header text larger",
                           realWorld: false)],
                    fragments: ["Make the header text larger and fix the layout of the pricing cards."])
        XCTAssertEqual(reasons(o), [.dictationNotRealWorld])
    }

    func testARealWorldActionInADictationStays() {
        let o = run([item("Pay the invoice for the ad account", evidence: "pay the invoice for the ad account",
                           realWorld: true)],
                    fragments: ["Tomorrow I have to pay the invoice for the ad account."])
        XCTAssertEqual(o.kept.count, 1)
    }

    func testAnExplicitRequestInADictationStaysEvenWithoutARealWorldFlag() {
        let o = run([item("Check the build logs after the release", kind: "asked_by_user",
                           evidence: "remind me to check the build logs", realWorld: false)],
                    fragments: ["Remind me to check the build logs after the release."])
        XCTAssertEqual(o.kept.map(\.kind), [.askedByUser])
    }

    /// In a call, `mine` does not need the real-world flag: a call is between people.
    func testAMineItemInACallDoesNotNeedTheRealWorldFlag() {
        let o = run([item("Send the pricing sheet to the client", evidence: "I'll send the pricing sheet",
                           realWorld: false)],
                    source: .call, fragments: ["Them: Can you share prices?\nMe: Sure, I'll send the pricing sheet today."])
        XCTAssertEqual(o.kept.count, 1)
    }

    // MARK: - R2 / K17 evidence is the spoken words, in the spoken language

    func testEvidenceMatchesIgnoringCaseSpacesPunctuationAndDiacritics() {
        let o = run([item("Book the cafe for Friday", evidence: "BOOK the  cafe, for friday")],
                    fragments: ["Remind me: book the café for Friday!"])
        XCTAssertEqual(o.kept.count, 1)
    }

    func testEvidenceNotInAnyFragmentIsDropped() {
        let o = run([item("Reply to the landlord about the lease", evidence: "reply to the landlord about the lease")],
                    fragments: ["The weather is nice today and I'm going for a walk."])
        XCTAssertEqual(reasons(o), [.evidenceNotSpoken])
    }

    /// The model must copy, not translate: evidence in another language than the fragment is not spoken words.
    func testTranslatedEvidenceIsDropped() {
        let o = run([item("Call the bank about the card", evidence: "call the bank about the card")],
                    fragments: ["Llamar al banco por la tarjeta mañana."])
        XCTAssertEqual(reasons(o), [.evidenceNotSpoken])
    }

    func testMissingOrTinyEvidenceIsDropped() {
        let o = run([item("Call the bank about the card", evidence: nil),
                     item("Call the bank about the new card", evidence: "ok")],
                    fragments: ["ok call the bank about the card"])
        XCTAssertEqual(reasons(o), [.evidenceNotSpoken, .evidenceNotSpoken])
    }

    func testTheMentionTimeIsTheFragmentTheEvidenceWasFoundIn() {
        let o = run([item("Renew the passport before the trip", evidence: "renew the passport")],
                    fragments: ["Morning notes.", "Lunch.", "Remind me to renew the passport before the trip."])
        XCTAssertEqual(o.kept.first?.mentionedAt, t0.addingTimeInterval(120))
        XCTAssertEqual(o.kept.first?.fragmentIndex, 2)
    }

    // MARK: - K7 someone else's "remind me" in a call

    func testInACallTheUsersRequestMustBeOnAMeLine() {
        let theirs = run([item("Call the moving company tomorrow", kind: "asked_by_user",
                               evidence: "remind me to call the moving company")],
                         source: .call,
                         fragments: ["Me: Let's see.\nThem: Remind me to call the moving company tomorrow."])
        XCTAssertEqual(reasons(theirs), [.notTheUsersRequest])

        let mine = run([item("Call the moving company tomorrow", kind: "asked_by_user",
                             evidence: "remind me to call the moving company")],
                       source: .call,
                       fragments: ["Them: Let's see.\nMe: Remind me to call the moving company tomorrow."])
        XCTAssertEqual(mine.kept.count, 1)
    }

    // MARK: - R2 / K3 placeholders and speaker labels

    func testABracketPlaceholderIsDropped() {
        let o = run([item("Call [name] about the offer", evidence: "call them about the offer")],
                    fragments: ["I need to call them about the offer."])
        XCTAssertEqual(reasons(o), [.placeholder])
    }

    // MARK: - P7 no "waiting on" items (owner, 2026-11-26)

    /// What someone else promised the user is not the user's task, named or not, in a call or a dictation.
    func testAWaitingOnItemIsNeverKept() {
        let call = run([item("Send the revised budget", kind: "waiting_on",
                             evidence: "I'll send the revised budget", assignee: "Maya")],
                       source: .call, fragments: ["Them: Maya here, I'll send the revised budget by Friday."])
        XCTAssertEqual(reasons(call), [.unknownKind])
        let dictation = run([item("Send the revised budget", kind: "waiting_on",
                                  evidence: "Maya promised to send the revised budget", assignee: "Maya")],
                            fragments: ["Maya promised to send the revised budget by Friday."])
        XCTAssertEqual(reasons(dictation), [.unknownKind])
    }

    func testTheUsersOwnItemsCarryNoOwner() {
        let o = run([item("Send the invoice to the client", kind: "mine", evidence: "send the invoice to the client",
                           assignee: "Team")],
                    fragments: ["I have to send the invoice to the client today, the team knows."])
        XCTAssertEqual(o.kept.count, 1)
        XCTAssertNil(o.kept.first?.candidate.assignee)
    }

    // MARK: - R6 the title filters

    func testAVagueTitleIsDropped() {
        let o = run([item("Respond to messages", evidence: "respond to messages")],
                    fragments: ["I should respond to messages later."])
        XCTAssertEqual(reasons(o), [.vagueTitle])
    }

    func testATitleOverFifteenWordsIsDropped() {
        let long = "Send the full quarterly report with all the charts and the notes to the finance team before Friday"
        let o = run([item(long, evidence: "send the full quarterly report")],
                    fragments: ["I have to send the full quarterly report."])
        XCTAssertEqual(reasons(o), [.vagueTitle])
    }

    // MARK: - K13 a past due date

    func testADueDateLessThanADayPastIsKept() {
        let due = now.addingTimeInterval(-3_600)
        let o = run([item("Pay the electricity bill online", evidence: "pay the electricity bill", dueAt: due)],
                    fragments: ["Pay the electricity bill today at noon."])
        XCTAssertEqual(o.kept.first?.candidate.dueAt, due)
    }

    func testADueDateMoreThanADayPastIsClearedAndTheItemKept() {
        let o = run([item("Pay the electricity bill online", evidence: "pay the electricity bill",
                           dueAt: now.addingTimeInterval(-90_000))],
                    fragments: ["Pay the electricity bill."])
        XCTAssertEqual(o.kept.count, 1)
        XCTAssertNil(o.kept.first?.candidate.dueAt)
    }

    // MARK: - K8 near-duplicates

    func testTheSameWordsInAnotherOrderAreARepeat() {
        XCTAssertTrue(Rules.isNearDuplicate("Send the budget to Sam", nil, "send Sam, the budget to!", nil))
    }

    func testAnotherRecipientIsNotARepeat() {
        XCTAssertFalse(Rules.isNearDuplicate("Send budget to Nina", nil, "Send budget to Nora", nil))
    }

    func testAnAddedWordIsNotARepeat() {
        XCTAssertFalse(Rules.isNearDuplicate("Call Sam about the contract", nil, "Do not call Sam about the contract", nil))
        XCTAssertFalse(Rules.isNearDuplicate("Pay 100 for the ads", nil, "Pay 200 for the ads", nil))
    }

    func testAnotherOwnerIsNotARepeat() {
        XCTAssertFalse(Rules.isNearDuplicate("Send the report", "Sam", "Send the report", "Alex"))
        XCTAssertTrue(Rules.isNearDuplicate("Send the report", "sam", "Send the report", "Sam"))
    }

    // MARK: - R1 / K9 the lifecycle of what already exists

    private func existing(_ description: String, resolvedAt: Date) -> Rules.Existing {
        Rules.Existing(description: description, assignee: nil, resolvedAt: resolvedAt)
    }

    func testAnOpenTaskAbsorbsARepeat() {
        let o = run([item("Renew the car insurance policy", evidence: "renew the car insurance")],
                    fragments: ["Remind me to renew the car insurance policy."],
                    existing: [existing("Renew the car insurance policy", resolvedAt: .distantFuture)])
        XCTAssertEqual(reasons(o), [.repeat])
    }

    func testADismissalHidesAnOlderMentionButNotANewOne() {
        let fragment = ["Remind me to renew the car insurance policy."]   // said at t0
        let droppedAfter = run([item("Renew the car insurance policy", evidence: "renew the car insurance")],
                               fragments: fragment,
                               existing: [existing("Renew the car insurance policy", resolvedAt: t0.addingTimeInterval(60))])
        XCTAssertEqual(reasons(droppedAfter), [.repeat], "re-extracting the same talk must not bring it back")

        let droppedBefore = run([item("Renew the car insurance policy", evidence: "renew the car insurance")],
                                fragments: fragment,
                                existing: [existing("Renew the car insurance policy", resolvedAt: t0.addingTimeInterval(-60))])
        XCTAssertEqual(droppedBefore.kept.count, 1, "said again after the drop, it may come back")
    }

    func testTwoItemsOfOneAnswerThatRepeatKeepTheFirst() {
        let o = run([item("Send the deck to the board", evidence: "send the deck to the board"),
                     item("send the deck to the board.", evidence: "send the deck to the board")],
                    fragments: ["I have to send the deck to the board."])
        XCTAssertEqual(o.kept.count, 1)
        XCTAssertEqual(reasons(o), [.repeat])
    }

    /// The row → lifecycle mapping (K9): open tasks and fresh drafts block for good; terminal rows until they ended.
    func testExistingRowsMapToTheirResolution() {
        let open = TaskItem(taskDescription: "Open one")
        XCTAssertEqual(Rules.existing(from: open, now: now)?.resolvedAt, .distantFuture)

        let draft = TaskItem(taskDescription: "Fresh draft", status: "staged")
        draft.createdAt = now.addingTimeInterval(-86_400)
        XCTAssertEqual(Rules.existing(from: draft, now: now)?.resolvedAt, .distantFuture)

        let expired = TaskItem(taskDescription: "Old draft", status: "staged")
        expired.createdAt = now.addingTimeInterval(-8 * 86_400)
        XCTAssertEqual(Rules.existing(from: expired, now: now)?.resolvedAt,
                       expired.createdAt.addingTimeInterval(7 * 86_400))

        let dismissed = TaskItem(taskDescription: "Dropped", status: "dismissed")
        dismissed.isDismissed = true
        dismissed.updatedAt = now.addingTimeInterval(-500)
        XCTAssertEqual(Rules.existing(from: dismissed, now: now)?.resolvedAt, dismissed.updatedAt)

        let done = TaskItem(taskDescription: "Done")
        done.completed = true
        done.completedAt = now.addingTimeInterval(-700)
        XCTAssertEqual(Rules.existing(from: done, now: now)?.resolvedAt, done.completedAt)
    }

    // MARK: - R3 phantom fragments never reach the model

    func testAPhantomFragmentIsNotSent() {
        XCTAssertNil(Rules.sendable("Subtitles by DimaTorzok"))
        XCTAssertNil(Rules.sendable("   "))
        XCTAssertEqual(Rules.sendable("Call the bank tomorrow. To be continued..."), "Call the bank tomorrow.")
        XCTAssertEqual(Rules.sendable("  Call the bank tomorrow.  "), "Call the bank tomorrow.")
    }

    /// The model may shorten a long quote with an ellipsis: the pieces are still the spoken words, in that order.
    func testEvidenceShortenedWithAnEllipsisMatchesPieceByPiece() {
        let o = run([item("Email the twenty users we fixed issues for", evidence: "prepare up to 20 users ... write them an apology")],
                    fragments: ["So, prepare up to 20 users we already fixed something for, and write them an apology with a code."])
        XCTAssertEqual(o.kept.count, 1)
        let reordered = run([item("Email the twenty users we fixed issues for", evidence: "write them an apology … prepare up to 20 users")],
                            fragments: ["So, prepare up to 20 users we already fixed something for, and write them an apology with a code."])
        XCTAssertEqual(reasons(reordered), [.evidenceNotSpoken], "the pieces must come in the spoken order")
    }

    /// R3 is the phantom-phrase list, not the short-chunk gibberish check: a long call part that mixes three
    /// scripts is real speech and is sent.
    func testALongPartMixingScriptsIsSent() {
        let part = "Them: We met in Athens, the Ελλάδα office, and the مرحبا banner. Me: I'll send the signed contract to Sam tomorrow."
        XCTAssertEqual(Rules.sendable(part), part)
    }

    /// A speech model's typo the task model "fixed" in its quote is still the spoken words: up to one letter in
    /// twenty may differ. A paraphrase or a shuffle differs far more and is still refused.
    func testEvidenceWithTheTyposFixedStillMatches() {
        let o = run([item("Write to Nora today about the phone number", evidence: "please write to Nora today about this number")],
                    source: .call, fragments: ["Them: Anything else?\nMe: Only one, please writ to Nora today about this number."])
        XCTAssertEqual(o.kept.count, 1)
        let paraphrase = run([item("Finish the table and fix the issue", evidence: "we need to fix it and finish the table")],
                             fragments: ["Today we should sort this out and then finish the table."])
        XCTAssertEqual(reasons(paraphrase), [.evidenceNotSpoken])
        let short = run([item("Call the bank about the card", evidence: "call the bonk")],
                        fragments: ["I will call the bank about the card."])
        XCTAssertEqual(reasons(short), [.evidenceNotSpoken], "under twenty letters the quote must be exact")
    }


    /// The model may copy the line's label with the words: the user's own request is still on the user's line.
    func testEvidenceThatKeepsTheLineLabelStillCounts() {
        let o = run([item("Call the bank about the new card", kind: "asked_by_user",
                           evidence: "Me: remind me to call the bank about the new card")],
                    source: .call, fragments: ["Them: Anything else?\nMe: Remind me to call the bank about the new card."])
        XCTAssertEqual(o.kept.count, 1)
    }


    /// Ellipsis pieces cannot be stitched from words spread over a long call: each piece is a real stretch of speech
    /// and the next one follows close by.
    func testEllipsisPiecesMustEachBeLongAndClose() {
        let filler = String(repeating: "We went through the agenda point by point. ", count: 12)
        let stitched = run([item("Call the bank about the card", evidence: "call … bank … card")],
                           source: .call, fragments: ["Me: I had a call. " + filler + "The bank is closed. " + filler + "My card works."])
        XCTAssertEqual(reasons(stitched), [.evidenceNotSpoken])
        let farApart = run([item("Email the twenty users we fixed issues for", evidence: "prepare up to twenty users ... write them an apology")],
                           fragments: ["So, prepare up to twenty users. " + filler + "Then write them an apology with a code."])
        XCTAssertEqual(reasons(farApart), [.evidenceNotSpoken])
    }

    /// One letter at most: dropping a two-letter negation from a long quote is not a typo.
    func testTypoToleranceNeverSwallowsANegation() {
        let o = run([item("Send the signed contract to Nina tomorrow", evidence: "quiero enviar el contrato firmado a Nina mañana por la mañana")],
                    fragments: ["No quiero enviar el contrato firmado a Nina mañana por la mañana."])
        XCTAssertEqual(o.kept.count, 1, "the quote itself is there word for word")
        let flipped = run([item("Send the signed contract to Nina tomorrow", evidence: "yo quiero enviar el contrato firmado a Nina mañana por la mañana")],
                          fragments: ["Yo no quiero enviar el contrato firmado a Nina mañana por la mañana."])
        XCTAssertEqual(reasons(flipped), [.evidenceNotSpoken], "the quote without its 'no' is another sentence")
    }

    /// Under twenty letters a quote is exact, even with its edges intact.
    func testAShortQuoteGetsNoTypoTolerance() {
        let o = run([item("Send the deck to Sam tonight", evidence: "send the dek to Sam")],
                    fragments: ["I'll send the deck to Sam tonight."])
        XCTAssertEqual(reasons(o), [.evidenceNotSpoken])
    }

    /// Each ellipsis piece is a stretch of speech, not a single short word.
    func testShortEllipsisPiecesAreRefusedEvenClose() {
        let o = run([item("Call the bank about the card", evidence: "call … bank")],
                    fragments: ["I need to call the big bank today about the card."])
        XCTAssertEqual(reasons(o), [.evidenceNotSpoken])
    }
}

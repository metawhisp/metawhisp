#!/usr/bin/env bash
# scripts/regression.sh
#
# The check that runs after EVERY iteration, before anything is called done.
#
# It exists because a green `swift test` is not by itself evidence that the
# working product still works: a suite can be deleted, renamed, skipped, or
# quietly emptied, and the run stays green while a shipped flow is broken.
# So this asserts what a bare test run does not:
#
#   1. no test was REMOVED: the number of tests has not dropped below the
#      floor, and every test of the critical suites recorded in the inventory
#      still exists — whatever this Mac can run today;
#   2. every test that must run RAN: a skipped test counts only when it is
#      named below as allowed to skip (DESIGN_SKIPS, SCREEN_SKIPS, and the
#      CHROME_TESTS, those only with MW_ALLOW_NO_CHROME=1), and a critical
#      test that skips otherwise fails the gate;
#   3. the layout corpus has not regressed.
#
# The gate first checks itself on saved runs (scripts/test-regression-gate.sh).
#
# Usage:
#   bash scripts/regression.sh              # run the gates
#   bash scripts/regression.sh --update     # accept the current tests as the floor and the inventory
#   MW_ALLOW_NO_CHROME=1 bash scripts/regression.sh
#                                           # on purpose, on a Mac without Chrome:
#                                           # the live Chrome tests may skip, and
#                                           # the output says so
#
# Exit 0 = safe to continue. Any non-zero = do not report the iteration done.
# Sourced (as the gate's own checks do), it only defines what it decides by.

set -uo pipefail

FLOOR_FILE="scripts/.regression-baseline"
INVENTORY_FILE="scripts/.regression-inventory"

# The flows a user would notice within a minute of them breaking. Adding a
# feature here is cheap; the point is that renaming or deleting one of these
# suites is loud instead of silent.
CRITICAL_SUITES=(
    # dictation: record → transcribe → recover
    TranscriptionCoordinatorRecoveryTests
    TranscriptionConfidenceGateTests
    CloudTransientErrorTests
    HallucinationStripTests
    # the text actually landing in the user's app
    TextInsertionClipboardTests
    FocusedTextGatewayTests
    # layout fix (flagship)
    LayoutCorpusBenchmarkTests
    LayoutKeystrokeReplacementTests
    LayoutClipboardOwnershipTests
    SelectionTranslateClipboardTests
    SelectionTranslateFeedbackTests
    LayoutTypingRaceTests
    # meetings
    MeetingChunkTextGateTests
    MeetingChunkBudgetTests
    CloudRequestTimeoutTests
    MeetingChunkRetryPolicyTests
    MeetingRecorderSilenceTests
    MeetingAudioSilenceCutterTests
    DualStreamMergerTests
    MeetingTranscriptSanitizerTests
    # microphone health
    DeadMicDetectorTests
    MicRecoveryTests
    MicDeviceFollowTests
    MeetingStartPolicyTests
    MeetingAutoStartGateTests
    CalendarAutoStartRetryTests
    CalendarRetryRespectsARefusalTests
    StopReasonIsARefusalTests
    GateRespectsAManualStopTests
    BrowserIdentityTests
    SystemChannelPlacementTests
    LogRotationTests
    MeetingShutdownTests
    StructuredRegenerateTests
    MemoryProposalConfirmationTests
    HotkeyRearmTests
    MemoryPromptBudgetTests
    WindowSpaceResidencyTests
    WindowBehaviorGuardTests
    MicOutageReportTests
    MicTimelinePlacementTests
    # the app survives a framework's exception (2026-10-12 wake crash)
    ObjCRaiseTests
    ExceptionPolicyTests
    EngineRaiseTests
    # screen capture privacy + freshness
    ScreenContextPolicyTests
    ContextVisitCoordinatorTests
    ScreenAgentRunQueueTests
    FocusedWindowSelectionTests
    ScreenAgentTimingPolicyTests
    ScreenContentFingerprintTests
    ScreenCaptureOutcomeTests
    ScreenOCRTests
    ScreenAgentDeliveryTests
    ScreenAgentThreadAnchorTests
    ScreenAgentEvidenceTests
    ScreenAgentDirectorTests
    InsightReferentTests
    ScreenAgentSpatialClaimGuardTests
    ScreenAgentVisionTests
    ScreenAgentRetrievalTests
    ScreenAgentReplayTests
    ScreenAgentFeedbackTests
    ScreenExtractorVisitGroupingTests
    ScreenAgentHealthTests
    ActiveAppCaptureFilterTests
    ContextVisitRecordTests
    ScreenContextFanoutTests
    ScreenExtractorVisitIndexTests
    ScreenRetentionTests
    # user data must survive an update
    SchemaMigrationTests
    StoreBackupTests
    # agent actions cannot fire without confirmation
    MutationServiceTests
    ChatToolExecutorSB2Tests
    # agent layer (ITER-074)
    AutomationPermissionTests
    DiaScriptTests
    WebViewBridgeTests
    ObservedPageTests
    ObserverScriptTests
    ObserverFormsTests
    ObserverValuesTests
    SheetCellsTests
    SafetyGuardTests
    CandidateBuilderTests
    AgentPolicyTests
    AgentQueueTests
    ActionScriptTests
    AgentPlanTests
    ScratchpadTests
    ErrandRecordTests
    ExcerptScriptTests
    FixtureSheetTests
    AgentRunTests
    # the agent's hands in the user's Chrome (ITER-076 3.1)
    DevToolsPortLocatorTests
    CDPValueTests
    WebSocketFrameTests
    CDPSocketLiveTests
    CDPConnectionStopTests
    ChromeBridgeStopTests
    ChromeConnectionLiveTests
    ChromeLinkTests
    ChromeBridgeLiveTests
    # the agent's one way to the language model (ITER-076 A1)
    ProLLMClientTests
    # Jev through the Pro server, and every agent call kept to its limit and to Stop (ITER-076 1.2, A1b)
    JevEngineTests
    DeadlineTests
    # the loop asks Jev each step with the approved questions (ITER-076 A2)
    JevDecisionEngineTests
    AgentRunJevTests
    # the errand service: queue, Stop, questions, keep-awake, sleep, quit, records (ITER-076 B1)
    ErrandContractTests
    KeepAwakeTests
    ErrandLeaseTests
    ErrandRecordStoreTests
    AgentServiceTests
    AgentServiceBrowserTests
    AgentServiceStopTests
    AgentServiceQueueTests
    AgentServiceQuestionTests
    AgentServiceKeepAwakeTests
    AgentServiceRecordTests
    AgentServiceSleepTests
    AgentServiceQuitTests
    # MetaChat starts an errand with runErrand, and its result comes back (ITER-076 B2)
    ChatErrandToolTests
    AgentServiceReentryTests
    AgentServiceLinkTests
    AgentServiceCeilingTests
    # the questions the owner approved for Jev, and their wire form (ITER-076 1.2, 1.3)
    JevQuestionsTests
    JevWireTests
    # what MetaChat offers the model and how it reads a tool call back (ITER-076 B2)
    ChatToolSchemaSyncTests
    ChatToolParsingTests
    # a voice question reaches MetaChat and always ends in an answer or an error (ITER-079, ITER-076 B2)
    VoiceQuestionFlowTests
    VoiceQuestionStateTests
    # MetaChat offers an errand only while one can run (ITER-076 I-04)
    ChatErrandOfferTests
    # the run the errand service drives: progress, rows kept live, honest endings, the factory (ITER-076 I-05)
    AgentRunErrandTests
    AgentServiceRunTests
    ErrandEndToEndTests
    ErrandStopLiveTests
    # a failed errand reaches the owner: one report of kinds and numbers, a queue on disk (ITER-076 I-06b)
    ErrandReportTests
    # the agent's brain, step 1: the plan, the sub-goals, a field's text, the search without a Yes (ITER-076 brain)
    ErrandModelTests
    AgentRunBrainTests
    AgentReadCacheTests
    # "find 10 jokes" end to end in the app's own run, the verifier deciding done (ITER-076 stage 1)
    ErrandBrainEndToEndTests
    # the hands, part 1: a page read once quiet, typing that lands, an overlay closed by its own control (ITER-076 I-07)
    ChromeHandsLiveTests
    # the hands, part 2: made-up dropdowns, see-through boxes, script-only controls, read-only and file fields (ITER-076 I-08)
    ChromeWidgetsLiveTests
    # the hands, part 3: frames, the page's dialogs, no download, no private address, the agent's tab marked (ITER-076 I-09)
    ChromeFramesLiveTests
    # a frame's point, each axis by its own ratio: the only catcher of a press scaled wrong (Claude review c7 of I-09, #24)
    ChromeFramePointTests
    ChromeTabGuardLiveTests
    ChromeTabGuardTests
    # the hands, part 3, the act and the page's secrets: a page's dialogs, the payment policy at the act, what Jev
    # sees, the acts in real Chrome (ITER-076 I-09, round 5; Claude review c10, #17)
    ChromePolicyLiveTests
    ChromeSecrecyLiveTests
    ChromeActsLiveTests
    # the hands, part 4: script links, no window, back through history, text cut, panels, controls in view, rows for Jev (ITER-076 I-10)
    ChromeReachLiveTests
    # the user's part waits instead of ending the errand: Continue, its window, Stop, Show tab, a CAPTCHA by its
    # widget's frame, the user's windows left alone (ITER-076 stage 3)
    AgentServicePauseTests
    AgentRunPauseTests
    ChromePauseLiveTests
    # a cookie window: its least consent clicked without a Yes, none of it waits for the user (ITER-076 stage 3)
    AgentRunCookieTests
    # a search without a Yes goes to the address its form builds, never by a click; only a search field (stage 3, D4)
    AgentRunSearchTests
    # typing safety: the Yes is for the text typed, a No keeps the field, no send repeated when its delivery is unknown
    AgentRunTypingTests
    # the Sheet only when asked: rows from the answer, read back; its failure keeps the answer; Stop closes its tab
    # and writes nothing more; nothing pasted outside its own tab (ITER-076 stage 6)
    AgentRunSheetTests
    GoogleSheetTests
    # whatever the Mac does, the errand ends honestly (ITER-076 stage 9d): the quit waits for the agent's tab, a
    # cancelled quit lifts its latch, a tab a crash or a sleep left is closed on the next connection, an update waits
    # for the running errand, the owner's switch stops it unreported
    QuitReplyTests
    AgentTabLedgerTests
    ChromeStrayTabLiveTests
    UpdateGateTests
    # the agent's own Chrome window by default, the user's Chrome the other way: started with no setup, one Chrome
    # per profile, the user's profiles never read in the own way, closed by the app's quit (ITER-076 stage 4b)
    AgentChromeTests
    AgentChromeLiveTests
    # a new user reaches the first errand alone (ITER-076 stage 8b): no browser before the user's Allow, Not now this
    # time only, the agent's switch and Pro, the browser Settings → Agent names from the next errand, a cleared
    # MetaChat forgets the agent's own Chrome, the disclosure's panel and words, MetaChat's live card and the quote
    AgentServiceConsentTests
    AgentServiceSwitchTests
    AgentServiceWayTests
    AgentDisclosureTests
    ChatErrandRowTests
    # a web form from the user's own details: one Yes to Fill, Send bound to the values shown, no secret field
    # typed, nothing after Stop, the endings MetaChat says (ITER-076 stage 7)
    FormFactsTests
    FormFillTests
    AgentRunFormTests
    ErrandCardFormTests
    ChromeFormsLiveTests
    # the agent in the window the user looks at (ITER-076 stage 11): the eyes (labels, what is left alone), the hands
    # (focus, one ⌘V, read back, an option pressed only when it appeared — no other key, no button), doHere's texts
    # and result, MetaChat's tool and line, and the live fill of the test's own form through real input events
    HereEyesTests
    HereHandsTests
    DoHereTests
    DoHereLiveTests
    ChatHereToolTests
    # the errand card on screen: every state, Yes/No, Stop and Stop all, in the notification column (ITER-076 I-11)
    ErrandCardTests
    ErrandCardStackTests
    ErrandCardViewTests
    ErrandCardColumnTests
    ErrandResultMessageTests
    # installs never break the working app (ITER-075)
    ActivityLeaseTrackerTests
    SwapInstallScriptTests
    SelfCheckTests
    # every meeting recorded once, whole (ITER-075 step 1)
    CalendarOccurrenceTests
    CalendarEndStopScheduleTests
    CalendarLookupGuardTests
    ProjectBackfillLedgerTests
    StructuredShortTranscriptTests
    ConversationBlankingGuardTests
    ProjectBackfillTests
    RunTurnsTests
    StructuredQueueTests
    StructuredUntitledSweepTests
    ExtractionQueueOrderTests
    StructuredServiceErrorTests
    CloudAccessTriggerTests
    StructuredTurnsGuardTests
    ConversationCloseOrderGuardTests
    ConversationLinkSavedTests
    # first run (1.4.0): no prompt before a button, the practice keeps nothing,
    # the model folder and readiness, the language, Pro's engine choice and its
    # end, the sign-in link, the Ultra switch, the onboarding flow and window
    LaunchPermissionGuardTests
    AutomaticStartPermissionTests
    MicrophoneFirstUseTests
    PracticeRecorderTests
    CaptureArbiterTests
    ModelFolderTests
    ModelPreparerTests
    TranscriptionLanguageLaunchTests
    StatusLineTests
    EngineInUseTests
    ProCloudDefaultTests
    SignInLinkTests
    LinkInboxTests
    LicenseActivationTests
    UltraFeaturesTests
    OnboardingFlowTests
    OnboardingWindowTests
    TryVoiceTests
    DashboardReadyCardTests
    AccountPageTests
    ApplicationsMoveTests
    MeetingEngineInUseTests
    DeviceFollowStopTests
)

# Tests that skip by design, as Suite.test: each needs something set up on
# purpose that a gate run does not have. They are counted, and may skip.
DESIGN_SKIPS=(
    # the live bench: real errands on real sites, only with METAWHISP_BENCH=1 (ITER-076 stage 3C)
    AgentLiveBenchTests.testTheTrialErrandsOnTheTestChrome
    # how MetaChat's model calls an errand, live, only with METAWHISP_CHAT_PROBE=1 (2026-10-06)
    ChatErrandFormatProbeTests.testHowTheModelCallsAnErrand
    # the fill's eyes on a real, visible Chrome window, only with METAWHISP_LIVE_CHROME_AX=1 (2026-10-13): a fresh
    # Chrome sometimes never shows its page to the Accessibility API (1 in 5-8 runs), which no gate should depend on
    HereEyesChromeLiveTests.testTheEyesSeeAChromePagesFieldsNotItsToolbar
    # a proof against a copy of the user's real store, run by hand before shipping
    SchemaMigrationTests.testRealStoreCopyOpensUnderLatest
    # an optional preflight over external word lists that are never in the repo
    LayoutCorpusBenchmarkTests.test_externalFrequencyCorporaHaveNoObservedFalseCorrections
    # the on-device model with its real weights, only with MW_LOCAL_STRESS=1
    LocalLLMQualityTests.testRealisticDictationQualityAndLatency
    LocalLLMStressTests.testF11LocalDictationPathUnderLoad
    LocalLLMTokenizerDiagTests.testTokenizerIdsMatchReference
    # one real step call on the product's arm through the live Pro server, only with METAWHISP_LIVE_SERVER=1 and
    # the owner's licence (2026-10-20): the gate must not depend on the network, the server or a licence
    ServerBrainLiveTests.testTheProductArmAnswersAStepWithTheAgentOutputTool
)

# Tests that need a screen that is awake and unlocked: they skip on a locked
# Mac. Counted either way, so the floor is the same locked or not.
SCREEN_SKIPS=(
    IslandWindowTests.testAnErrorLandsWhereItBelongs
    IslandWindowTests.testAnErrorRightAfterAMoveLandsWhereItBelongs
    IslandWindowTests.testAShakeStillRunningNeverMovesTheNextQuestion
    # also needs the Accessibility permission and a test runner that macOS never makes the active app (ITER-076 stage 11)
    DoHereLiveTests.testFillsTheTestsOwnFormThroughRealInputEventsAndSendsNothing
)

# The live Chrome tests, as Suite (every test in it) or Suite.test: they skip
# with NO_CHROME_REASON where Google Chrome is missing. That is allowed, and
# counted, only with MW_ALLOW_NO_CHROME=1 — for these tests and no other.
CHROME_TESTS=(
    ChromeConnectionLiveTests
    ChromeBridgeLiveTests
    ChromeHandsLiveTests
    ChromeWidgetsLiveTests
    ChromeFramesLiveTests
    ChromeTabGuardLiveTests
    ChromePolicyLiveTests
    ChromeSecrecyLiveTests
    ChromeActsLiveTests
    ChromeReachLiveTests
    ChromePauseLiveTests
    ChromeStrayTabLiveTests
    AgentChromeLiveTests
    ChromeFormsLiveTests
    ErrandEndToEndTests
    ErrandStopLiveTests
    ChromeLinkTests.testConnectsOnceAndKeepsTheConnection
    ChromeLinkTests.testAConnectionThatEndedIsOpenedAgain
    ChromeLinkTests.testAPortNothingAnswersOnIsPassedForTheNextBrowser
    ChromeLinkTests.testAPortThatAnswersNotFoundIsPassedForTheNextBrowser
)
NO_CHROME_REASON="needs Google Chrome"

FAILED=0

fail() { echo "  ❌ $*"; FAILED=1; }
ok()   { echo "  ✅ $*"; }
note() { echo "  ⚠️  $*"; }

# listed ITEM LIST... — whether ITEM is one of LIST.
listed() {
    local item="$1" entry
    shift
    for entry in "$@"; do [ "$entry" = "$item" ] && return 0; done
    return 1
}

is_critical()    { listed "$1" "${CRITICAL_SUITES[@]}"; }
is_chrome_test() { listed "$1" "${CHROME_TESTS[@]}" || listed "$1.$2" "${CHROME_TESTS[@]}"; }

# The tests in LOG that ended (passed, failed or skipped), as "Suite test", one a line.
ended_tests() {
    grep -aoE "Test Case '-\[MetaWhispTests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+\]' (passed|failed|skipped)" "$1" \
        | sed -E "s/^Test Case '-\[MetaWhispTests\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (passed|failed|skipped)$/\1 \2 \3/"
}

# Why SUITE TEST skipped in LOG.
skip_reason() {
    grep -aF -- "-[MetaWhispTests.$2 $3] : Test skipped - " "$1" | head -1 | sed 's/.*: Test skipped - //'
}

# mw_verdict LOG TEST_EXIT MODE — what the run in LOG, whose `swift test`
# exited with TEST_EXIT, comes to. MODE `update` records its floor and its
# inventory, `check` compares with them. Prints each finding; returns 1 when
# one fails.
mw_verdict() {
    local log="$1" test_exit="$2" mode="$3"
    local summary total skipped fails
    summary=$(grep -aE "Executed [0-9]+ tests, with" "$log" | tail -1)
    # Two shapes: "Executed N tests, with F failures" and
    # "Executed N tests, with S tests skipped and F failures".
    total=$(echo "$summary" | grep -oE "Executed [0-9]+ tests" | head -1 | awk '{print $2}')
    skipped=$(echo "$summary" | grep -oE "[0-9]+ tests? skipped" | head -1 | awk '{print $1}')
    fails=$(echo "$summary" | grep -oE "[0-9]+ failures" | head -1 | awk '{print $1}')
    [ -z "${total:-}" ] && total=0
    [ -z "${skipped:-}" ] && skipped=0
    [ -z "${fails:-}" ] && fails=0
    if [ "$test_exit" -eq 0 ] && [ "$fails" = "0" ]; then
        ok "$total tests, 0 failures ($((total - skipped)) ran, $skipped skipped)"
    else
        fail "$summary"
        grep -aE "error: -\[" "$log" | head -15
    fi

    # Every skip, judged by its test's name alone: allowed and counted, or not.
    local ended suite test outcome reason refused=0 chrome_excused=0 chrome_missing=0 excused_in="" refused_in=""
    ended=$(ended_tests "$log")
    while read -r suite test outcome; do
        [ "$outcome" = "skipped" ] || continue
        reason=$(skip_reason "$log" "$suite" "$test")
        if listed "$suite.$test" "${DESIGN_SKIPS[@]}" || listed "$suite.$test" "${SCREEN_SKIPS[@]}"; then
            excused_in="$excused_in $suite"
            continue
        fi
        if is_chrome_test "$suite" "$test" && [ "$reason" = "$NO_CHROME_REASON" ]; then
            if [ "${MW_ALLOW_NO_CHROME:-}" = "1" ]; then
                chrome_excused=$((chrome_excused + 1))
                excused_in="$excused_in $suite"
            else
                # One line below says it for all of them.
                chrome_missing=$((chrome_missing + 1))
                refused=$((refused + 1))
                refused_in="$refused_in $suite"
            fi
            continue
        fi
        refused=$((refused + 1))
        refused_in="$refused_in $suite"
        if is_critical "$suite"; then
            fail "$suite.$test was SKIPPED${reason:+ ($reason)} — a critical test must run"
        else
            note "$suite.$test skipped${reason:+ ($reason)} and is not counted: no one allowed it to skip"
        fi
    done <<< "$ended"

    echo "${MW_STEP_REMOVED:-▸ No test removed}"
    # Counted: every test but those that skipped without leave.
    local counted=$((total - refused)) counted_note="" floor
    [ "$chrome_excused" -gt 0 ] && \
        counted_note=" (MW_ALLOW_NO_CHROME=1 counts $chrome_excused live Chrome tests that did not run)"
    if [ "$mode" = "update" ]; then
        echo "$counted" > "$FLOOR_FILE"
        echo "  ↻ floor set to $counted"
    elif [ -f "$FLOOR_FILE" ]; then
        floor=$(cat "$FLOOR_FILE")
        if [ "$counted" -lt "$floor" ]; then
            fail "test count dropped: $counted < $floor — tests were removed, or skipped without leave"
            echo "     If the removal is deliberate: bash scripts/regression.sh --update"
        else
            ok "count $counted ≥ floor $floor$counted_note"
        fi
    else
        echo "$counted" > "$FLOOR_FILE"
        echo "  ↻ floor created at $counted"
    fi

    # The critical tests that exist in this run, whether they ran or skipped.
    local present gone added
    present=$(while read -r suite test outcome; do
        is_critical "$suite" && echo "$suite.$test"
    done <<< "$ended" | sort -u)
    if [ "$mode" = "update" ] || [ ! -f "$INVENTORY_FILE" ]; then
        printf '%s\n' "$present" > "$INVENTORY_FILE"
        echo "  ↻ inventory: $(grep -c . "$INVENTORY_FILE") critical tests recorded"
    else
        gone=$(comm -23 "$INVENTORY_FILE" <(printf '%s\n' "$present"))
        added=$(comm -13 "$INVENTORY_FILE" <(printf '%s\n' "$present") | grep -c .)
        if [ -n "$gone" ]; then
            while read -r test; do
                fail "$test no longer exists — a critical test was removed or renamed"
            done <<< "$gone"
            echo "     If the removal is deliberate: bash scripts/regression.sh --update"
        else
            [ "$added" = "0" ] && added="" || added=" ($added new since the inventory; --update records them)"
            ok "all $(grep -c . "$INVENTORY_FILE") recorded critical tests exist$added"
        fi
    fi

    echo "${MW_STEP_RAN:-▸ Every test that must run ran}"
    local ran missing=0
    for suite in "${CRITICAL_SUITES[@]}"; do
        ran=$(grep -cE "^$suite [A-Za-z0-9_]+ (passed|failed)$" <<< "$ended")
        [ "$ran" != "0" ] && continue
        # Its skips were judged above; a suite with no test at all fails here.
        if listed "$suite" $refused_in; then
            missing=1
        elif listed "$suite" $excused_in; then
            note "$suite: none of it ran — every test in it is allowed to skip here"
        else
            fail "$suite ran 0 tests"
            missing=1
        fi
    done
    [ "$missing" = "0" ] && [ "$refused" = "0" ] && \
        ok "${#CRITICAL_SUITES[@]} critical suites: every test ran or is allowed by name to skip"
    if [ "$chrome_missing" -gt 0 ]; then
        fail "no Google Chrome: $chrome_missing live Chrome tests did not run — install Chrome, or set MW_ALLOW_NO_CHROME=1 on purpose"
    elif [ "$chrome_excused" -gt 0 ]; then
        note "MW_ALLOW_NO_CHROME=1: $chrome_excused live Chrome tests did not run — no Google Chrome on this Mac"
    elif [ "${MW_ALLOW_NO_CHROME:-}" = "1" ]; then
        note "MW_ALLOW_NO_CHROME=1 is set, but no live Chrome test skipped for want of Chrome"
    fi

    local corpus
    corpus=$(grep -aE "recall|corpus" "$log" | grep -aiE "[0-9]+\.[0-9]+" | tail -1)
    if grep -aqE "Test Case '-\[MetaWhispTests\.LayoutCorpusBenchmarkTests [^]]+\]' (passed|failed)" "$log"; then
        if grep -aq "LayoutCorpusBenchmarkTests.*failed" "$log"; then
            fail "layout corpus REGRESSED below its floor"
        else
            ok "corpus within floor ${corpus:+($corpus)}"
        fi
    elif grep -aq "Test Case '-\[MetaWhispTests.LayoutCorpusBenchmarkTests" "$log"; then
        note "corpus not checked: its preflight skips by design without METAWHISP_EN_CORPUS and METAWHISP_RU_CORPUS"
    else
        fail "layout corpus benchmark did not run"
    fi

    MW_CHROME_EXCUSED=$chrome_excused
    return $FAILED
}

# Sourced: the lists and mw_verdict are all it brings.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

cd "$(cd "$(dirname "$0")/.." && pwd)"
LOG=$(mktemp -t mw-regression)
MODE=check
[ "${1:-}" = "--update" ] && MODE=update

echo "▸ 1/5  The gate checks itself"
if bash scripts/test-regression-gate.sh > "$LOG" 2>&1; then
    ok "$(tail -1 "$LOG")"
else
    fail "the gate decides a saved run wrongly — its verdict below would mean nothing"
    grep -E "✗" "$LOG" | head -10
    exit 1
fi

echo "▸ 2/5  Build"
if swift build > "$LOG" 2>&1; then
    ok "swift build"
else
    fail "swift build FAILED"
    grep -E ": error:" "$LOG" | head -10
    echo "Stopping: nothing below is meaningful against a broken build."
    exit 1
fi

echo "▸ 3/5  Full suite"
swift test > "$LOG" 2>&1
TEST_EXIT=$?
for suite in "${CRITICAL_SUITES[@]}"; do
    grep -rq "class ${suite}\b" Tests/ || fail "$suite — SUITE NO LONGER EXISTS"
done
MW_STEP_REMOVED="▸ 4/5  No test removed" MW_STEP_RAN="▸ 5/5  Every test that must run ran, and the corpus" \
    mw_verdict "$LOG" "$TEST_EXIT" "$MODE"
FAILED=$?

echo
if [ "$FAILED" = "0" ] && [ "${MW_CHROME_EXCUSED:-0}" -gt 0 ]; then
    echo "PASS without the live Chrome tests (MW_ALLOW_NO_CHROME=1) — safe to continue only where Chrome is not needed."
elif [ "$FAILED" = "0" ]; then
    echo "PASS — safe to continue."
else
    echo "FAIL — do not report the iteration done."
fi
rm -f "$LOG"
exit $FAILED

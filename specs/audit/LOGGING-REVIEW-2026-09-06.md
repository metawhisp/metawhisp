# Аудит логирования и дефектов — 2026-09-06

Прогон: 18 фич, по каждой независимый читатель + скептик (36 агентов). Ниже только то,
что скептик подтвердил по коду; сырые гипотезы отброшены.

- Пробелов в логах закрыто: 211 строк (см. коммит).
- Дефектов подтверждено: 139 (13 P1, 55 P2, 71 P3).
- Утечек содержимого в СУЩЕСТВУЮЩИХ логах: 136 — не тронуты, см. последний раздел.

Ни один дефект не чинился молча: это отчёт.


## P1 — Потеря данных и молчаливый отказ (13)

**[license-updates] `App/AppDelegate.swift:2034`** — The meeting transcript is persisted only AFTER the awaited quota-booking POST, so a retrying billing call holds a finished transcript in memory for up to ~51 seconds before it is saved.
  <br>Доказательство: Confirmed by reading the block: `if engine is CloudWhisperEngine, LicenseService.shared.isPro { await LicenseService.shared.logMeetingUsage(minutes: duration / 60.0) }` at AppDelegate.swift:2033-2035, and `self.persistMeetingTranscript(fullText:duration:elapsed:)` not reached until :2046. I checked for an earlier save on this path and there is none — the other persistMeetingTranscript calls (:1932 Deepgram BYOK, :195

**[local-llm] `Services/LLM/LocalLLMService.swift:733`** — completeChunked never passes onChunkSkipped, so on the local path a failed chunk is silently dropped and the partial result is returned as if complete — the Pro path explicitly refuses to do this.
  <br>Доказательство: LocalLLMService.swift:733-735 calls `ChunkedCompletion.run(system:user:chunkChars:concatPartials:)` — the `onChunkSkipped` parameter (ChunkedCompletion.swift:52) is omitted, so it defaults to nil. ChunkedCompletion.swift:70-78 catches the chunk error, logs 'chunk i/N failed — skipped', calls `onChunkSkipped?` (a no-op here) and continues; 90-97 joins the surviving partials. The Pro path does the opposite: StructuredG

**[meeting-recording] `App/AppDelegate.swift:2554`** — applicationWillTerminate neither stops nor flushes an in-flight meeting — Quit or Sparkle's Install-and-Relaunch drops the entire mic + system buffer.
  <br>Доказательство: App/AppDelegate.swift:2550-2555 — the whole handler is `layoutSwitchController.stop()`, a DEBUG probe stop, and `NSLog("[MetaWhisp] Terminating")`. No stopMeetingRecording, no meetingRecorder.stop(), no WAV flush. `grep -rn 'applicationShouldTerminate|willTerminateNotification' App Services Views` returns nothing, so there is no other hook either. Views/MenuBar/MenuBarView.swift:461 wires QUIT to `NSApplication.share

**[meeting-recording] `App/AppDelegate.swift:1972`** — 'engine not ready' at stop discards both channels with no recovery WAV, while the per-chunk failure path saves one.
  <br>Доказательство: App/AppDelegate.swift:1972-1977 — `guard let engine = coordinator.activeEngine, engine.isModelLoaded else { ...; NSLog("❌ Meeting transcribe: engine not ready"); return }`. micSamples/sysSamples are locals in the enclosing Task and go out of scope; nothing calls TranscriptionCoordinator.saveSamplesAsWav on this path. Contrast 2323-2327 on the chunk path: `let recovered = TranscriptionCoordinator.saveSamplesAsWav(rawC

**[meeting-recording] `App/AppDelegate.swift:2494`** — persistMeetingTranscript silently drops the transcript when historyService.save returns nil, and line 2047 still logs '✅ Meeting transcribed'.
  <br>Доказательство: App/AppDelegate.swift:2494 `if let item = historyService.save(result) {` with no else. Services/Data/HistoryService.swift:67-70 returns nil when `!health.isHealthy` (ITER-049 temporary in-memory session) and :77-80 returns nil when `context.save()` throws — both logged only via `Self.log.error` (os.Logger), never NSLog, so nothing reaches MetaWhisp.log. Control then falls through to the adviceService call and back to

**[meeting-transcription] `App/AppDelegate.swift:1972`** — Engine-not-ready guard discards the entire meeting audio without writing a Recovery WAV
  <br>Доказательство: `guard let engine = coordinator.activeEngine, engine.isModelLoaded else { … coordinator.lastError = …; NSLog("❌ Meeting transcribe: engine not ready"); return }` (1972-1977). `micSamples`/`sysSamples` are locals of stopMeetingRecording and the only copy of the meeting; the guard returns without touching them. grep for `saveSamplesAsWav` shows exactly one meeting call site — App/AppDelegate.swift:2327, the per-chunk f

**[meeting-transcription] `App/AppDelegate.swift:2494`** — A failed history save leaves no line in MetaWhisp.log and no banner, while a ✅ line still claims success
  <br>Доказательство: Services/Data/HistoryService.swift:69 returns nil when `health.isHealthy` is false and :81 returns nil when `context.save()` throws; both log via `Self.log` = `Logger(subsystem: "com.metawhisp.app", category: "History")` (:8), i.e. os.Logger, which never reaches the stderr file FileLogger redirects (Services/System/FileLogger.swift:19-22). AppDelegate:2494 `if let item = historyService.save(result) {` silently skips 

**[memories] `Services/Intelligence/MemoryExtractor.swift:181`** — Confirm-by-saying-it never persists: the proposal is mutated in a throwaway ModelContext that is never saved, and the fact is skipped from this extraction as well.
  <br>Доказательство: fetchPendingProposals() creates its OWN context at :484 (`let ctx = ModelContext(container)`) and returns objects registered there. :181-182 sets `proposal.needsReview = false` / `updatedAt` on those objects, but the only save is `try ctx.save()` at :197 on the extraction context created at :105 — a different ModelContext; contexts created this way have autosave disabled, so the throwaway context's changes die with i

**[memories] `Services/Intelligence/MemoryExtractor.swift:458`** — On the Pro/BYOK routes a large confirmed-memory list can push the transcript entirely out of the prompt: the dedup list is written first and uncapped, then the whole prompt is truncated from the head at 20000 chars.
  <br>Доказательство: buildPrompt() appends the existing-memories block first (:421-437); the ITER-051 budget split at :423-430 is inside `if let budget = localBudget`, and localBudget is nil for both cloud routes (:122-123 passes it only when LocalLLMService.shared.isReady). The transcript is appended after (:439-455), then :458 `if combined.count > 20000 { return String(combined.prefix(20000)) }` cuts from the END. fetchExistingMemories

**[permissions-onboarding] `Services/System/HotkeyService.swift:66`** — Global hotkeys are registered with no Accessibility gate and no nil-check on the monitors, are never re-registered after a later grant, and the log claims success either way — the app's primary trigger can be dead for a whole session while the log reads "registered".
  <br>Доказательство: HotkeyService.register (:48-88) installs flagsMonitor/keyMonitor/localFlagsMonitor/localKeyMonitor (:66-86) and then unconditionally logs "[HotkeyService] Right ⌘, Right ⌥ (tap+long-press) registered (global+local)" (:87) — no AXIsProcessTrusted() check anywhere in the file, no nil-check on any of the four tokens. Whether addGlobalMonitorForEvents returns a token or nil on an untrusted process, macOS delivers no glob

**[structured-and-plan] `Services/Intelligence/StructuredGenerator.swift:199`** — regenerate() wipes all 11 structured fields and saves BEFORE generate() runs, with no snapshot and no restore; generate() has five bail-outs that write nothing, so a good title/overview/decisions/actions/participants/quotes/next-steps are lost permanently.
  <br>Доказательство: StructuredGenerator.swift:200-211 sets title/overview/category/emoji/primaryProject/topicsJSON/decisionsJSON/actionItemsJSON/participantsJSON/keyQuotesJSON/nextStepsJSON = nil and `try? ctx.save()` at :211, then calls generate() at :212. generate() returns without writing at :232 (isRunning), :234 (no LLM access), :243 (conv not found), :340 (no API key), :353 (parse failed) and :423-426 (LLM/network throw). Nothing 

**[translation] `Services/System/SelectionTranslator.swift:36`** — pasteboard.clearContents() destroys every clipboard representation, but only the .string flavour is snapshotted (:33) and nothing is restored on the success path.
  <br>Доказательство: SelectionTranslator.swift:33 `let previousContents = pasteboard.string(forType: .string)` then :36 `pasteboard.clearContents()`. Restore happens only at :62-66 (no selection) and :86-89 (failure), and only `if let prev = previousContents` — an image/file/rich-text clipboard yields nil there and is gone for good. On the success path (:76-81) there is no restore at all: textInserter.insert(text: translated) leaves the 

**[translation] `Services/System/SelectionTranslator.swift:83`** — A failed selection-translate gives the user zero feedback — the error sound is a no-op method and there is no banner channel.
  <br>Доказательство: SoundService.swift:69 `func playError() {}` — literally empty. SelectionTranslator.swift:82-90 logs the reason, calls soundService.playError(), hides the overlay and restores the clipboard string; the class has no lastError/@Published property (whole file read, 101 lines) and no reference to TranscriptionCoordinator.lastError. So a keyless free user, a 402 from the proxy, or a network drop yields: Morse sound + "tran


## P2 — Неверное поведение (55)

**[cards-surface] `Views/Notifications/MWNotificationStackController.swift:43`** — The panel is rendered from a Combine sink delivered on RunLoop.main (default mode only) while the 6-second auto-fade runs on the main-actor executor (dispatch main queue, all run-loop modes) — so a card pushed during event tracking is recorded as presented and then timed out without ever being drawn.
  <br>Доказательство: MWNotificationStackController.swift:42-46 `MWNotificationStack.shared.$items.receive(on: RunLoop.main).sink { self?.render(items:) }`. Combine's RunLoop scheduler routes through RunLoop.perform, which schedules in default mode only — it does not run in .eventTracking. The fade is armed at push time: MWNotificationStack.swift:86 armFade → :132 `Task { @MainActor ... Task.sleep(for: .seconds(life)) }` → :137 dismiss(re

**[cards-surface] `Views/Notifications/MWNotificationCardView.swift:356`** — The card fires its action on mouse-DOWN with no way to abort, so a card that appears in the top-right corner under the cursor can stop a live meeting recording on a click aimed at something else.
  <br>Доказательство: MWNotificationCardView.swift:356-362: `override func mouseDown(with event: NSEvent) { let point = convert(...); if closeButton.frame.contains(point) { return }; onTap?() }` — the action runs on mouse-down; there is no mouseUp override, no drag-off cancel, and no confirmation. AppDelegate.swift:3026-3035 pushes a .recordingOverrun card whose onTap calls `self.stopMeetingRecording(reason: "calendar-end-overrun-card-tap

**[cards-surface] `App/AppDelegate.swift:2836`** — The meeting auto-record countdown treats "the card is no longer in the stack" as "the user cancelled", so a FIFO eviction or fade-timer drift silently aborts auto-start and the log blames the user for an action they never took.
  <br>Доказательство: AppDelegate.swift:2831 pushes countdownNote; :2832-2841 loops five 1-second sleeps and each pass does `let stillVisible = MWNotificationStack.shared.items.contains { $0.id == cancelToken }` / `guard stillVisible else { NSLog("[CallDetect] %@ countdown cancelled by user", name); MeetingAutoStartGate.shared.reset(); return }`. Two non-user routes out of the stack: (a) MWNotificationStack.swift:69-76 evicts the oldest w

**[chat] `Services/Intelligence/ChatService.swift:47`** — A message sent while another send is in flight is dropped with no bubble, no error and no log; on the voice side this leaves the floating popup stuck in THINKING forever.
  <br>Доказательство: ChatService.swift:47 `guard !isSending else { return }` fires before lastError is cleared (56) and before the user row is persisted (60-64). ChatView's own @State isSending (ChatView.swift:14, set 362) only serialises typed sends against each other — the voice path enters through TranscriptionCoordinator.swift:451-453 without touching it. Typed-during-voice: ChatView.swift:351 already cleared inputText, then ChatView

**[chat] `Services/Intelligence/ChatService.swift:273`** — A voice question that produces a mutation shows only the model's preamble in the popup; the YES/CANCEL confirm exists solely in the MetaChat window, so the popup reads as done while nothing was executed.
  <br>Доказательство: ChatService.swift:273-275 passes only aiText to VoiceQuestionState.answered(); the pending call lives on the ChatMessage row (250-255) and its confirm UI is built exclusively in ChatView.swift:180-206 (`if let preview = msg.pendingToolPreview` → 'YES, DO IT' / 'CANCEL'). Views/FloatingVoice/FloatingVoiceView.swift (283 lines) contains no match for pendingTool / confirm / toolResult / YES. TTS is additionally suppress

**[dictation] `Services/System/HotkeyService.swift:109`** — PTT start and stop thresholds disagree (0.15s vs 0.3s): a 0.15–0.3s hold opens the mic and never closes it.
  <br>Доказательство: HotkeyService.swift:107-113 — on key-down an asyncAfter(+0.15) fires onPTTStart while rightCmdDown is still true; :116-123 — on release, onPTTStop is called only when held >= 0.3, otherwise it logs "PTT ignored short tap" and returns. TranscriptionCoordinator.startPTT (:109-116) guards stage == .idle, so the next press is rejected ("PTT start ignored: stage=recording"), and the following release >= 0.3s runs stopPTT 

**[dictation] `Services/System/TranscriptionCoordinator.swift:515`** — saveSuspectToClipboard discards NSPasteboard.setString's Bool and never reads back, while its three callers return before the history save — a failed write loses the dictation entirely.
  <br>Доказательство: TranscriptionCoordinator.swift:511-517: pb.clearContents(); pb.setString(text, forType: .string) with the return value dropped, then logs "💾 Suspect text saved to clipboard (%d chars)" unconditionally. The same ownership race is documented and fixed in TextInsertionService.swift:151-162 and writeToClipboardVerified (:196-225: retry ×3 + 5ms read-back). Callers at :321, :350 and :369 each set lastError ("text saved to

**[dictation] `Services/System/TextInsertionService.swift:177`** — previousApp is only assigned when MetaWhisp is not frontmost and is never cleared, so a Dashboard-started dictation pastes into the target of the previous dictation.
  <br>Доказательство: TextInsertionService.swift:123-131 — the only assignment site (grep across Services/Views/App shows exactly three references: :123 declaration, :129 assignment, :177 read), guarded by app.bundleIdentifier != Bundle.main.bundleIdentifier, with no else and no nil-ing. MainWindowController.swift:159 and :219 call NSApp.setActivationPolicy(.regular), so with the Dashboard open MetaWhisp is frontmost and savePreviousApp()

**[integrations] `Services/Indexing/FileIndexerService.swift:90`** — Periodic file-indexer scans never run FileMemoryExtractor.runPass — file memories are only extracted from the two manual SCAN NOW buttons.
  <br>Доказательство: scanAll ends at line 90 with `await backfillContent()` and nothing else. grep for `runPass()` across the repo returns exactly two call sites: Views/Windows/FilesView.swift:280 and Views/Windows/MainSettingsView.swift:2920 (plus the declaration at FileMemoryExtractor.swift:31 and a doc comment at FileIndexerService.swift:200). A user who enables File Indexing and relies on the 6h timer gets IndexedFile rows and conten

**[integrations] `App/AppDelegate.swift:1389`** — Reader timers are armed only at launch; enabling Calendar / Apple Notes / File Indexing mid-session never calls startPeriodic.
  <br>Доказательство: grep for `startPeriodic` outside declarations returns only AppDelegate.swift:1360 (screen), 1367 (fileIndexer), 1373 (appleNotes), 1389 (calendar), all inside applicationDidFinishLaunching behind `if <enabled>, storeHealthy`. The Settings toggles at MainSettingsView.swift:1704 / 1719 / 2386 carry no .onChange — unlike mcpSection, which does exactly that at MainSettingsView.swift:1821-1823. DashboardView.connectCalend

**[integrations] `Services/Indexing/FileIndexerService.swift:111`** — The recursive folder walk and the content backfill both run synchronously on the main actor.
  <br>Доказательство: `@MainActor final class FileIndexerService` (lines 9-10). scanFolder calls `walk(rootURL, root:depth:onFile:)` (line 111), a plain synchronous recursive func (161-183) doing contentsOfDirectory plus attributesOfItem per file (115) with maxDepth 8 (line 34) — no Task.detached, no nonisolated hop. backfillContent loops up to 1000 rows calling `Data(contentsOf:)` on the main actor (line 229). The SCANNING… button state 

**[integrations] `Services/Indexing/AppleNotesReaderService.swift:196`** — AppleScript takes the first 40 notes in raw enumeration order with no sort, dedup is by note id only, and the parsed modification date is never used — edited notes are never re-extracted and, if enumeration order is stable, the tail of a >40-note library is never reached.
  <br>Доказательство: readNotesAppleScript (189-213) does `repeat with n in allNotes` with `if noteCount ≥ limit then exit repeat` — no `sort by`, no date filter. Dedup is `!processedIds.contains($0.id)` (line 83), where processedIds comes from the sourceFile FK 'apple-note:<id>'. modifiedAt is parsed at 244 and stored in AppleNotePayload (151, 245); grep shows no other reference to it in the file — it is never compared against anything, 

**[layout-switch] `Services/System/LayoutSwitchController.swift:537`** — The result of the input-source switch is discarded on both paths, so a failed switch is logged and displayed as a full success.
  <br>Доказательство: InputSourceService.select returns false whenever configuredSource(for:) finds no installed source with the exact identifier (InputSourceService.swift:34, :38-51) or TISSelectInputSource != noErr (:35). Both call sites discard it: `_ = inputSourceService.select(correction.targetLayout)` at LayoutSwitchController.swift:537 and `_ = self.inputSourceService.select(correction.targetLayout)` at :613. Line 539 then logs 'Au

**[layout-switch] `Services/System/FocusedTextGateway.swift:569`** — The manual path's failure line states the user's selection 'was recovered' when the recovery is conditional and is skipped in exactly the most common failure case.
  <br>Доказательство: LayoutSelectionTransaction.run restores the original selection only inside `if targetIsStillFocused() { _ = select(originalSelection) }` (FocusedTextGateway.swift:99-104), and targetIsStillFocused here is the `stillValid` closure (:539-542), which is false whenever focus moved or isStillCurrent() went false. So when the paste fails because focus changed — the dominant cause — the range selected at :97 is left as a LI

**[layout-switch] `App/AppDelegate.swift:2532`** — applicationDidBecomeActive discards the State returned by start(), so a re-arm that fails is invisible and leaves the feature dead for the session.
  <br>Доказательство: `_ = layoutSwitchController.start()` at AppDelegate.swift:2532 runs on every activation. start() (LayoutSwitchController.swift:306-342) calls stop() first — removing all four NSEvent monitors (:350-358) — and then returns .disabled / .needsAccessibility / .unavailable without installing anything. Revoke Accessibility in System Settings and switch back to MetaWhisp and the feature is dead, while the newest state line 

**[layout-switch] `Services/System/InputSourceService.swift:10`** — Only the two exact input-source IDs are recognised, and an unsupported source makes the whole feature inert with no log line and no UI signal.
  <br>Доказательство: InputSourceIDResolver.layout(for:) maps only com.apple.keylayout.US and com.apple.keylayout.Russian and returns nil for everything else (:7-8, :10-16) — a documented v1 scope limit, but its failure mode is silent. On 'Russian – PC' (com.apple.keylayout.RussianWin) or 'ABC' (com.apple.keylayout.ABC), currentLayout() returns nil, so handleKeyDown's guard at LayoutSwitchController.swift:400 falls through to wordBuffer.r

**[license-updates] `Services/License/LicenseService.swift:462`** — logMeetingUsage retries a non-idempotent POST after a timeout, so one meeting can be billed two or three times against the user's quota.
  <br>Доказательство: LicenseService.swift:456 builds the body as `["license_key": key, "minutes": minutes]` — no idempotency key, no meeting id. The loop `for attempt in 1...3` (:462) re-POSTs the identical body after ANY thrown error (:476-478), including a 15 s timeout, which can fire after the worker already committed the minutes. The user is charged 120 or 180 minutes for a 60-minute meeting and the log prints one reassuring '✅ Booke

**[license-updates] `Services/License/LicenseService.swift:203`** — The licence-key probe treats ANY 2xx from /api/usage as proof the subscription is active and refreshes the 72h stamp, so a transport-level 200 that is not an entitlement answer keeps a cached Pro alive indefinitely.
  <br>Доказательство: probeLicenseKey (:211-220) discards the body entirely — `let (_, resp) = try await URLSession.shared.data(for: req)` at :216 — and returns only the status code; licenseKeyFallbackAction (:203-207) then maps `(200 ..< 300)` straight to .keepCachedPro, and verify() (:278-282) sets isPro = true AND calls recordVerified(), refreshing the 72h stamp. I dropped the first reviewer's worker-shaped scenario (that /api/usage an

**[license-updates] `Services/License/LicenseService.swift:376`** — The `usage` meter is never cleared on signOut() or clearInactiveLicense(), so one account's minute balance is displayed under another account.
  <br>Доказательство: signOut() (:485-498) clears isPro, email, licenseKey, plan, renewalDate, cancelAtPeriodEnd and the stamp but never touches `usage`; clearInactiveLicense() (:376-386) likewise. MainSettingsView.swift:838 renders on `if license.isPro, let u = license.usage`. Scenario: account A (Pro) has fetched usage (120 of 600 left); user signs out — meter hides because isPro is false but the value survives — then signs in with Pro 

**[local-llm] `Services/LLM/MLXModelManager.swift:242`** — `catch is CancellationError` never matches a user cancel, so the ✕ button does not cancel: the retry loop restarts the download invisibly and the single-flight invariant breaks.
  <br>Доказательство: .build/checkouts/swift-transformers/Sources/Hub/HubApi.swift:587-605 wraps the transfer in `withTaskCancellationHandler { … } onCancel: { Task { await downloader.cancel() } }`; Downloader.swift:379-382 `cancel()` broadcasts `.failed(URLError(.cancelled))`, which the listen loop rethrows at HubApi.swift:594-595. So `try await task.value` (MLXModelManager.swift:239) throws a URLError, not a CancellationError — the `cat

**[local-llm] `Services/LLM/MLXModelManager.swift:185`** — Preflight and guard failures (notDownloadable / downloadInProgress / insufficientDiskSpace / incompatibleHost) throw before `lastError[spec.id]` is ever written, so the card shows no inline reason — the button just appears to do nothing.
  <br>Доказательство: download(_:) throws at 186, 189 and via validatePreflight(192 → 156/167) BEFORE `lastError.removeValue(forKey: spec.id)` at 198; the only write to `lastError[spec.id]` is at 273, after all network retries. The card renders `if let err = mlxManager.lastError[spec.id]` (MainSettingsView:2337), so on a disk-space refusal with no prior failure nothing appears — the catch at MainSettingsView:2331 only NSLogs the reason. (

**[local-llm] `Services/LLM/LocalLLMService.swift:125`** — loadModel is not fenced against an in-flight generation: the MLX build can run on one GCD thread while the decode loop runs on another, violating the file's own single-tenant invariant.
  <br>Доказательство: loadModel (125-140) checks only `isLoading`; performLoad (142-225) dispatches `buildModelSync` (quantize + loadArrays + eval) to `DispatchQueue.global` at 179-190. `pendingGeneration` — the FIFO fence — is touched only inside the two generate paths (438/457 and 500/544, confirmed by grep); neither loadModel nor performLoad nor unloadModel awaits `pendingGeneration?.value` or checks `isGenerating`. Meanwhile runGenera

**[meeting-coach] `Services/Intelligence/MeetingCoachService.swift:233`** — On the local-model path the coach prompt is silently cut to its first 2000 chars and the RECENT verbatim block is built LAST, so once summary + memory grow the model stops seeing the last two minutes — the exact input the feature exists to react to.
  <br>Доказательство: callLLM L232-235 calls LocalLLMService.completeBlocking(system:user:maxTokens:) without maxUserChars; the default is 2000 (LocalLLMService.swift:662) and the body is cut with `String(user.prefix(maxUserChars)) + "\n[local-LLM truncation]"` (L666-667). buildUserPrompt (L206-216) appends blocks in order EARLIER-summary → memory → "RECENT (last ~2 minutes verbatim)", so the prefix cut removes RECENT first. With a 4-chun

**[meeting-recording] `App/AppDelegate.swift:2650`** — Auto-start fallback path has no failure backoff: a start that never goes live re-shows a countdown card and retries roughly every 20s for as long as a call window stays frontmost.
  <br>Доказательство: Services/Audio/MeetingAutoStartGate.swift:165-171 — on `.fallbackReady` the gate clears its own streak and returns, so the streak simply rebuilds. AppDelegate.swift:2752-2754 fires the countdown on every fallbackReady. If MeetingRecorder.start fails (Screen Recording denied, SCK failing), the sniff loop's guard at 2903-2904 (`guard meetingRecorder.isRecording ...`) returns after the first 5s sleep, `meetingCountdownI

**[meeting-recording] `App/AppDelegate.swift:1936`** — BYOK Deepgram/Gemini paths return before the micChannelWasSilent check, so a mic that delivered bit-exact zeros all call saves a Them:-only transcript with nothing said about it.
  <br>Доказательство: AppDelegate.swift:1932-1936 (Deepgram) and 1959-1963 (Gemini) call persistMeetingTranscript and `return`. `grep -rn micChannelWasSilent App Services Views Tests` shows its only consumers are AppDelegate:2009 and :2021 — both AFTER those returns, in the Whisper dual-stream path. The earlier reportMicOutageIfAny (1917) cannot cover it: its Input (1839-1845) has no micChannelWasSilent field, and for an external mic deli

**[meeting-transcription] `App/AppDelegate.swift:1924`** — BYOK (Deepgram/Gemini) success paths skip the digital-silence mic warning the Whisper path was fixed for
  <br>Доказательство: Deepgram (1924-1943) and Gemini (1949-1969) call persistMeetingTranscript and `return` before the `if capture.micChannelWasSilent` warning at 2021. The recorder computes `micChannelWasSilent = tapSamples > 0 && Self.isDigitalSilence(rawMicSamples)` (MeetingRecorder.swift:586) — and Services/Audio/AudioRecordingService.swift:131-143 states the design explicitly: `.dead` is only reported for a built-in mic (`deadMic.is

**[memories] `Services/Intelligence/ProjectAggregator.swift:666`** — mergeAliases keeps comparing an alias after it has been merged away as the loser, so a later alias can be absorbed INTO an already-deleted row and its variants lost.
  <br>Доказательство: Stage 1 (:652-673): the inner loop only skips `b` (`if killed.contains(b.id) { continue }`, :657); when the winner/loser pick at :663 makes `a` the loser, `killed.insert(loser.id)` + `ctx.delete(loser)` run but there is no `break`, so iteration j+1 still evaluates `a`. If `a.aliases.count >= b.aliases.count` for that later pair, the deleted `a` becomes the winner: `winner.addAlias(v)` writes into a row that :674's sa

**[memories] `Services/Intelligence/ProjectAggregator.swift:238`** — Every user-facing project mutation swallows the save with `try?` and still logs and returns success; the view shows a confirmation for a change that may not have persisted.
  <br>Доказательство: deleteProject :238-241 (`try? ctx.save()` then "🗑 deleted project '%@' — %d conversations unlinked", `return unlinked`); renameCanonical :432-434; setCanonical :462-464; splitAlias :502-504 — all identical. Views/Windows/ProjectsView.swift:339-342 takes the returned count and shows "Removed. N conversations now uncategorized."; :308, :440, :451 branch on the returned true. A store failure produces a success log, a su

**[permissions-onboarding] `Views/Windows/MainSettingsView.swift:829`** — The "Show onboarding" button in Settings can never open the window — it builds a controller whose coordinator and modelManager are nil.
  <br>Доказательство: MainSettingsView.swift:828-830 is `Button { OnboardingWindowController().show() }`. OnboardingWindowController declares `var coordinator: TranscriptionCoordinator?` and `var modelManager: ModelManagerService?` (:8-9) with no initializer, so the fresh instance has both nil; show() hits `guard let coordinator, let modelManager else { NSLog("[Onboarding] No coordinator/modelManager — skipping"); return }` (:17-20) and n

**[permissions-onboarding] `Views/Windows/Onboarding/OnboardingPermissionsPage.swift:87`** — The onboarding Microphone row is a silent no-op once macOS has already recorded a decision: no dialog, no message, and no route to System Settings.
  <br>Доказательство: requestMic (:86-92) calls AVCaptureDevice.requestAccess(for: .audio) and only writes the result into @State (:89). requestAccess presents a dialog exclusively for .notDetermined; every other status calls back immediately with the stored answer. setupServices resolves the microphone at launch (AppDelegate.swift:913-918 → AudioRecordingService.requestPermission :243-288, whose strategies 1-3 each raise the prompt) whil

**[recap] `Services/Intelligence/WeeklyPatternDetector.swift:162`** — The weekly digest save is `try? ctx.save()` — a failed save is reported as ✅ Generated, a card is pushed, and the 5-min tick then finds no digest and repeats the whole LLM call plus the card until midnight.
  <br>Доказательство: Line 161-162 `ctx.insert(digest); try? ctx.save()` with no do/catch, then line 164 logs "✅ Generated" and 168-170 push the card unconditionally. The anti-spam check at 81 reads mostRecentDigest() from the store (408-416), so an unsaved digest never satisfies it and tick() (71-85) re-fires every 300 s while weekday == 1. The daily service fixed this exact shape in SB-7 — DailySummaryService.swift:256-261 uses do/catch

**[recap] `Services/Intelligence/WeeklyPatternDetector.swift:151`** — A parse failure is persisted as an all-empty digest; the week is then permanently recorded as QUIET, the 6-day anti-spam blocks a rerun, and no manual regenerate path exists.
  <br>Доказательство: parseResponse returns ParsedDigest(themes: [], people: [], stuckLoops: [], insights: []) on decode failure (297-301); 157-162 encode those empties (encodeArray returns nil for an empty array, 418-421) and save. PatternDigest.isEmpty is `themes.isEmpty && people.isEmpty && stuckLoops.isEmpty && insights.isEmpty` (Models/PatternDigest.swift:52-53), so WeeklyInsightsView renders the row as "QUIET" and disables expansion

**[recap] `Services/Intelligence/DailySummaryService.swift:225`** — When every agent call fails the recap is still saved and announced as a success, and hasSummary(for: today) then stops the timer from ever retrying that day.
  <br>Доказательство: runAgent/runStringAgent swallow the throw and return []/"" (280-283, 291-294). With all seven agents failing, learned/decided/shipped/unresolved are [], energy and dayEmoji are "", and headlineAgent's fallback at 492-497 produces "N conversations · 0 learnings". The row is inserted and saved at 251-257, ✅ Generated is logged at 263, and the card is pushed at 266-268. tick() then returns at line 65 (`if hasSummary(for

**[recap] `Services/Intelligence/DailySummaryService.swift:60`** — tick() only ever considers today, so a machine asleep across the scheduled hour and past midnight never generates yesterday's recap — silently, with no log line and no card.
  <br>Доказательство: tick() computes `let today = Calendar.current.startOfDay(for: now)` (63), checks `now >= scheduledFireTime(for: today)` (64) and `hasSummary(for: today)` (65) — yesterday is never a candidate. The header at line 8 advertises "On app launch (catch-up if the machine was asleep past the scheduled time)", which only covers today's own hour. Recovery requires the user to press ‹ then GENERATE on the Dashboard (DashboardVi

**[recap] `Views/Windows/MainSettingsView.swift:1216`** — The Settings toggle is a plain binding flip with no side effect, so enabling Daily Summary or Weekly Patterns during a session starts no scheduler; Weekly Patterns defaults OFF, so every user who turns it on gets nothing until a relaunch or a touch of the hour picker.
  <br>Доказательство: toggleRow (1205-1219) ends in `.onTapGesture { isOn.wrappedValue.toggle() }` — no service call. grep over the repo: startScheduler is called only at App/AppDelegate.swift:1250 and 1257 (both behind `if AppSettings.shared.<flag>Enabled` evaluated at launch) and from the two DatePicker setters at MainSettingsView.swift:2457 and 2497. No onChange handler exists on either flag, and stopScheduler has no callers at all. Ap

**[recap] `Services/Intelligence/DailySummaryService.swift:144`** — hasLLMAccess admits BYOK API-key users, the Pro gate 34 lines later rejects them, and the timer re-runs the whole data fetch plus the skip log every 5 minutes from the scheduled hour to midnight, every day — a gate with no ceiling.
  <br>Доказательство: hasLLMAccess is `!settings.activeAPIKey.isEmpty || LicenseService.shared.isPro` (952-954) and passes at 144; the full SwiftData sweep runs at 160-168 (conversations, memories, tasks×2, 500 ScreenObservations, goals) before `guard LicenseService.shared.isPro` rejects at 178 and logs "Non-Pro — skipping". No row is written, so tick()'s `hasSummary` check at 65 never becomes true and the 300 s loop repeats — ~24 passes 

**[recap] `Views/Windows/DashboardView.swift:1129`** — The GENERATE button has no failure state at all: generateForDate returns nil for six different reasons and the card just stops the spinner and re-shows the placeholder.
  <br>Доказательство: generate() (1125-1133) assigns `localSummary = result` and clears isGenerating with no error branch. generateForDate returns nil at DailySummaryService.swift:93 (future day), 143 (isRunning), 145 (no LLM access), 176 (empty day), 180 (non-Pro) and 260 (save failed). DailySummaryService.lastError is declared at line 27 and, per grep, is never assigned anywhere in the file — only WeeklyPatternDetector writes its own co

**[screen-agent] `Services/Screen/ScreenContextService.swift:754`** — captureActiveWindow overwrites the specific failure reason set by captureScreenshot with a generic .captureFailed, making the .ambiguousWindow health state unreachable and mislabelling a mid-session permission revoke.
  <br>Доказательство: captureScreenshot sets `lastCaptureOutcome = .permissionDenied` (796) or `.ambiguousWindow` (827) and returns nil; the caller's guard at 753-756 then unconditionally runs `lastCaptureOutcome = .captureFailed`. The only consumer is AppDelegate:182 → ScreenAgentHealth.evaluate, whose `if case .ambiguousWindow` branch (degraded: "cannot tell which window is focused", ScreenAgentHealth.swift) can therefore never fire fro

**[screen-agent] `Services/Intelligence/ScreenExtractor.swift:96`** — `lastRun` lives only in memory, so after every relaunch the first hourly pass covers just the preceding hour; ScreenContext rows between the previous session's last pass and (relaunch − 1 h) never get ScreenObservations.
  <br>Доказательство: `@Published var lastRun: Date?` (21) with no UserDefaults/AppStorage read anywhere — grep for `lastRun` across the repo shows only in-process assignments (108, 133, 371). `let since = lastRun ?? Date().addingTimeInterval(-3600)` (96), and startPeriodic sleeps BEFORE the first pass (46-49), so a launch at 09:00 fires at 10:00 with since = 09:00. The 17:30–18:00 captures from the previous session are never fetched and 

**[screen-agent] `Services/Intelligence/ProactiveContextService.swift:367`** — Run metrics under-report: seven Tally counters are never incremented anywhere in production code, so every ScreenAgentRunMetrics row records 0 for vision calls and all store searches.
  <br>Доказательство: grep across the repo: visionModelCallCount, providerFailureCount, fallbackCount, screenHistorySearchCount, screenTextReadCount, taskSearchCount, memorySearchCount appear ONLY as `row.X = tally.X` copies in ScreenAgentDeliveryService.swift:433-439 — no `+=` anywhere (only textModelCallCount and toolTurnCount are incremented, InsightAssistantService:157-158). The searchTasks/searchMemories closures in ProactiveContextS

**[structured-and-plan] `Services/Intelligence/StructuredGenerator.swift:232`** — `guard !isRunning else { return }` silently discards any concurrent generate() — no log, no queue, no retry — and the dropped conversation ends with title == nil, which the launch backfill predicate can never match, so it stays untitled forever.
  <br>Доказательство: isRunning is @Published on the @MainActor class (:13-14, :24), set at :318 and cleared only by `defer` at :319, so it stays true across the LLM await at :332-349; a second generate() entering during that window returns at :232 having written nothing. Conversation.title has no default value — Models/Conversation.swift:32 `var title: String?` and :143 `self.title = nil`. backfillPlaceholders' predicate (:121-124) match

**[structured-and-plan] `Services/Intelligence/StructuredGenerator.swift:780`** — The local-LLM action-plan path drops failed chunks silently: it calls LocalLLMService.completeChunked, which invokes ChunkedCompletion.run WITHOUT onChunkSkipped, so the 'a partial plan says so' guarantee exists only on the Pro path.
  <br>Доказательство: StructuredGenerator.swift:779-781 returns `LocalLLMService.shared.completeChunked(system:user:)`; LocalLLMService.swift:733-735 calls `ChunkedCompletion.run(system:user:chunkChars:concatPartials:)` with no onChunkSkipped argument (the parameter defaults to nil, ChunkedCompletion.swift:52). ChunkedCompletion.swift:70-78 catches a chunk failure, logs it and calls `onChunkSkipped?` — a no-op here — then folds the surviv

**[structured-and-plan] `Services/Intelligence/StructuredGenerator.swift:139`** — backfillPlaceholders marks structuredBackfillAttempted = true and wipes title/overview/category/emoji before generate(); because the predicate also matches rows whose title is REAL but overview == "(empty)", a failed regeneration converts a real (e.g. calendar-derived) title into nil, and the sticky flag guarantees it is never retried.
  <br>Доказательство: StructuredGenerator.swift:120-124 predicate matches `$0.title == "Quick note" || $0.overview == "(empty)"` — the second clause selects rows with a perfectly good title. :139 sets structuredBackfillAttempted = true BEFORE any LLM work; :149-153 sets title/overview/category/emoji = nil and saves; :158 calls generate(preferCloud: true). If generate() throws (:423) or bails (:232/:340/:353) nothing is restored — unlike P

**[tasks] `Services/Intelligence/TaskPrioritizationService.swift:68`** — The re-rank fetch applies no TaskHygiene window, so it ranks candidates the promotion loop can never use; with staged creation gated off, every staged row is now past the 7-day window and 100% of re-rank LLM calls are dead spend.
  <br>Доказательство: TaskPrioritizationService.swift:68-76 fetches status=="staged" with no TaskHygiene call, while TaskPromotionService.swift:104 filters the same pool through TaskHygiene.isStaleUnreviewedCandidate (window 7 days, TaskHygiene.swift:17). Both screen producers of staged rows are gated off: ScreenExtractor.swift:336 and RealtimeScreenReactor.swift:267 both `guard ScreenDerivedTaskPolicy.mayMutateWithoutConfirmation` and th

**[tasks] `Services/Intelligence/TaskExtractor.swift:501`** — buildPrompt truncates the assembled prompt to its first 20 000 chars, dropping the TAIL of long conversations — where late action items and 'already done' resolutions live — contradicting the AUD-035 comment that cloud routes get the full block.
  <br>Доказательство: buildPrompt appends the transcript LAST (parts order: time header 435-438, calendar 443-453, dedup list 456-480, then `parts.append(fragText)` at 498), then line 501: `if combined.count > 20000 { return String(combined.prefix(20000)) }` — a head-prefix, so the tail is discarded. This runs on the cloud path too (localBudget == nil), directly contradicting TaskExtractor.swift:109-110: "(Cloud paths get the full block; 

**[tasks] `Services/Intelligence/TaskExtractor.swift:216`** — Transport/environment errors thrown by the LLM call are returned as .failedAttempt — the counted 'content failure' outcome — so after 5 drains the conversation is permanently dropped with a log line blaming 'unparseable content'.
  <br>Доказательство: The do/catch at 143-217 wraps every route: LocalLLMService.completeBlocking (149), callProProxy (156, which throws ProcessingError.apiError on any non-200) and llm.complete (164). The catch at 213-217 returns `.failedAttempt` unconditionally. ExtractionQueueStore.swift:94-100 counts that outcome and at maxFailedAttempts (=5, line 42) calls remove(id) after logging "dropping %@ after %d failed attempts (unparseable co

**[tasks] `Views/Windows/TasksView.swift:459`** — The EXTRACT NOW outcome banner is derived solely from the @Query count delta, so every failure mode is presented to the user as 'No new tasks (nothing actionable in the last transcript)'; TaskExtractor.lastError is never read by the view.
  <br>Доказательство: TasksView.swift:449 `let before = tasks.count`, 456 `await appDelegate.taskExtractor.extractOnce()`, 457 a fixed 500 ms sleep, 458-461 the banner from `delta`. grep for `lastError` in TasksView.swift returns zero hits, though TaskExtractor.swift:25 publishes it. Silent-zero-delta paths verified: extractOnce returns early at 79-82 (no LLM access) and 89-93 (no conversation); drainQueue returns instantly at 65 (`guard 

**[translation] `Services/Processing/TextProcessor.swift:352`** — detectTargetLanguage can return "auto" as a target language, and treats undetectable text as already-in-target.
  <br>Доказательство: TextProcessor.swift:346 `let srcLang = settings.transcriptionLanguage`; Models/AppSettings.swift:21 defaults it to OnboardingLanguageDefault.freshInstallDefault = "auto" (OnboardingLanguageDefault.swift:19). :352 `if detected == dstLang || detected.hasPrefix(dstLang) || dstLang.hasPrefix(detected) { return srcLang }` — with detected == "" (NLLanguageRecognizer returns nil for short/numeric/emoji selections, :341) `"e

**[translation] `Views/Windows/MainSettingsView.swift:932`** — Settings advertises the Right ⌥ hold as live-mic auto-translation; it is actually selection-translate.
  <br>Доказательство: MainSettingsView.swift:932 `"AUTO-TRANSLATE (INPUT)", desc: "Hold Right ⌥ ≥ 1.5s — translates live mic input as you speak."`. The hold is wired HotkeyService.swift:186 `Task { @MainActor in self.onTranslateLongPress?() }` → AppDelegate.swift:935 `self?.selectionTranslator.translateSelection()`. translateSelection (SelectionTranslator.swift:23) never touches the recorder — it synthesizes ⌘C (:39, :92-101) and replaces

**[translation] `Services/System/SelectionTranslator.swift:24`** — Missing Accessibility permission aborts the hold flow silently — log only, no overlay, no sound, no prompt.
  <br>Доказательство: SelectionTranslator.swift:24-27: `guard AXIsProcessTrusted() else { NSLog("[SelectionTranslator] No accessibility permission"); return }`. Nothing else runs — the Morse sound and overlay.showTranslating() are further down at :71-72. Compare TranscriptionCoordinator.swift:176-183, which sets lastError and opens the System Settings pane URL for its mic-permission failure.

**[translation] `Services/Processing/TextProcessor.swift:268`** — Pro proxy failures surface to the user as a bare status code; the proxy's own error message is decoded nowhere on this path.
  <br>Доказательство: TextProcessor.swift:268 `throw ProcessingError.apiError("Server error: HTTP \(http.statusCode)")` — the body read at :266 is used only for the log line at :267 and then discarded. That message becomes lastError (TranscriptionCoordinator.swift:397) and the SelectionTranslator failure line (:83). StructuredGenerator.swift:877-883 `proxyReason(_:)` already decodes `{"error": "…"}` (capped at 200 chars) for the same work

**[translation] `Services/Processing/TextProcessor.swift:273`** — processViaProxy returns the decoded text with no emptiness guard, so an empty cloud answer replaces the user's selection with nothing.
  <br>Доказательство: TextProcessor.swift:271-273 decodes ProResponse and returns result.text unchecked. The local branch does guard (:312-314 `if !trimmed.isEmpty { return trimmed }` → falls back), and OpenAIService.swift:99-101 throws only when `choices.first?.message.content` is nil, not when it is "". SelectionTranslator.swift:76-78 then calls textInserter.insert(text: "") → TextInsertionService.writeToClipboardVerified("") (setString

**[voice-question] `Services/System/TranscriptionCoordinator.swift:177`** — A voice question whose recording never starts leaves the popup stuck at LISTENING and the mode flag set
  <br>Доказательство: startVoiceQuestion (151-160) sets voiceQuestionMode = true and VoiceQuestionState.startListening() BEFORE calling startRecording(). startRecording returns early at 177-186 (mic permission denied) and at 204-211 (recorder.start() throws); neither path calls abortVoiceQuestionIfActive — grep of the helper's callers shows only the stopAndTranscribe/transcribe abort paths (229, 247, 253, 272, 307, 324, 353, 372, 499). On

**[voice-question] `Services/Intelligence/ChatService.swift:47`** — send(_:source: .voice) early returns never fail the popup — it hangs at THINKING with no auto-dismiss
  <br>Доказательство: Three returns in send() leave VoiceQuestionState at .thinking (set by the coordinator at :447 before the Task): line 47 `guard !isSending else { return }`; lines 48-51 `guard hasLLMAccess` (1953-1958 — no API key, no Pro, no local model); lines 197-200 `guard !apiKey.isEmpty` on the non-Pro branch. None calls VoiceQuestionState.failed and none logs (47 and 197 log nothing at all). Only .answered/.error get an auto-di

**[voice-question] `Services/UI/VoiceQuestionState.swift:55`** — Esc during TRANSCRIBING does not cancel: thinking() has no .idle guard, so the popup resurrects and the question is sent and spoken
  <br>Доказательство: answered() (60-64) and failed() (66-69) both open with `guard phase != .idle else { return }`; thinking() (55-58) sets phase = .thinking unconditionally. The window is visible during .transcribing (showWindow is called for every non-idle phase, FloatingVoiceWindowController.swift:52-54) so the Esc monitors (229, 241) are installed; dismiss() (74-81) sets .idle and activeSendTask is still nil at that point (it is only


## P3 — мелкое (71)

- [cards-surface] `Views/Notifications/MWNotificationStackController.swift:52` — render() returns early when the stack empties, so the card NSViews — each owning an NSVisualEffectView — stay attached to the hidden panel until the next push.
- [cards-surface] `Views/Notifications/MWNotificationStackController.swift:129` — The comment claims cards are re-measured on every layout, but measuredHeight is a cached value set once at init and never recomputed.
- [cards-surface] `Services/System/NotificationService.swift:43` — The DND early-return logs that the suppressed task "will land in recap", but the only caller is dictation-sourced and the meeting recap cannot carry dictation tasks.
- [cards-surface] `Services/Intelligence/TaskExtractor.swift:196` — One extraction posts one card per task in a tight synchronous loop against a 4-slot FIFO stack, so with five or more tasks the earliest cards are evicted before the panel ever renders.
- [chat] `Services/Intelligence/ChatService.swift:284` — Cancelling a voice question with Esc writes a permanent red 'Error: …' bubble into the typed MetaChat thread and logs it as a failure.
- [chat] `Views/Windows/ChatView.swift:58` — The .proactivePrefillChat listener with its 50ms auto-submit is unreachable — nothing in the codebase posts that notification.
- [chat] `Services/Intelligence/ChatService.swift:48` — When LLM access is missing the typed question is destroyed: ChatView clears the input before send() refuses, so the user must retype after adding a key or licence.
- [chat] `Services/Intelligence/ChatService.swift:303` — clearHistory() swallows both the delete and the save with try?, so a failed clear leaves the messages on screen with no error to the user and nothing in the log.
- [dictation] `Services/System/TextInsertionService.swift:190` — insertResult returns .autoPasted before the deferred simulatePaste runs; a CGEvent failure is logged only, so the coordinator reports success and leaves the user with no banner.
- [dictation] `Services/System/HotkeyService.swift:161` — Toggle-mode dead zone: a Right ⌘ press held between 0.4s and voiceQuestionHoldMs (500 ms default) does nothing and logs nothing.
- [dictation] `Services/System/HotkeyService.swift:102` — The PTT branch never consults otherKeysDuringRightCmd, so an ordinary Right ⌘ chord held ≥0.3s (⌘Tab, ⌘-drag) starts and completes a dictation.
- [dictation] `Services/Processing/TextProcessor.swift:51` — Clean mode without translation returns before applyTextStyle, so Pro text-style preferences are silently skipped in that one mode.
- [dictation] `Services/Processing/TextProcessor.swift:268` — The Pro proxy's error message is decoded for transcription but not for post-processing, so the dictation banner shows a bare HTTP status instead of the server's reason.
- [integrations] `Services/Export/ObsidianExporter.swift:549` — `stats = s` discards the error counter that write() incremented during the bulk run, so a bulk export always reports zero errors.
- [integrations] `Services/MCP/MCPSnapshotService.swift:94` — snapshotNow() has no debounce despite the header promising one; every committed mutation triggers a full re-fetch, JSON encode, atomic write and chmod on the main actor.
- [integrations] `Sources/MetaWhispMCP/main.swift:96` — loadSnapshot swallows decode errors with `try?`, the user-facing 'not available' message states a wait time that does not match the writer, and tool calls are never logged.
- [integrations] `Services/Indexing/MeetingObsidianWriter.swift:157` — ObsidianSyncService and MeetingObsidianWriter are dead but still compiled, and the calendar back-link they provided was dropped with no replacement.
- [integrations] `Services/Indexing/CalendarReaderService.swift:319` — scanNow calls requestAccess() on every run, including the background 6h timer, so a TCC dialog can appear from a timer.
- [integrations] `Services/Indexing/CalendarReaderService.swift:540` — Pro-proxy failures are thrown as a bare status code without the proxy's own error body, which the logging contract forbids.
- [integrations] `Views/Windows/MainSettingsView.swift:1724` — The manual scan buttons are not gated on store health, unlike every launch-time timer and every mutation.
- [layout-switch] `Services/Processing/CorrectionMonitor.swift:41` — The pasted text is located by first occurrence, so a field that already contains the same string yields the wrong prefix/suffix split and can teach the dictionary a bogus correction.
- [license-updates] `Models/AppSettings.swift:501` — KeychainHelper.save discards the SecItemAdd result, so a failed write silently loses the licence key and the user is Free on the next launch with no trace.
- [license-updates] `Services/License/LicenseService.swift:440` — fetchUsage swallows non-200 responses and every thrown error, presenting a stale meter as current with no staleness indicator.
- [local-llm] `Services/LLM/ChunkedCompletion.swift:70` — mapPass's bare catch swallows CancellationError too, so a cancelled job 'skips' every remaining chunk and ends with a generic NSError instead of CancellationError.
- [local-llm] `Services/LLM/MLXModelManager.swift:227` — bytesCompleted is a completed-FILE count, not bytes, so the download card's MB figure is always 0.
- [local-llm] `Services/LLM/LocalLLMService.swift:452` — fmGenerate swallows the Foundation Models error and finishes the stream empty; its consumer then blames a Phi-4 download the user may not even have.
- [local-llm] `Services/LLM/MLXModelManager.swift:218` — `for attempt in 1...maxRetries` makes 3 TOTAL attempts (initial + 2 retries, ~6 s of backoff), while the doc comment promises 'initial + 3 retries … ~14 s' and the UI labels the first retry 'Retry 2/3'.
- [local-llm] `Services/LLM/LocalLLMService.swift:773` — The instance method sampleToken(logits:temperature:) is dead code duplicating the categorical-expects-logits fix.
- [meeting-coach] `Services/Intelligence/MeetingCoachService.swift:265` — A Pro-proxy failure discards the worker's error body and throws "Proxy HTTP N", so the only reason ever written to the durable log is a bare status code.
- [meeting-coach] `Services/Intelligence/MeetingCoachService.swift:150` — reset() clears the inFlight guard while a process() task may still be awaiting the LLM: the stale call can push a suggestion from the previous meeting into the new meeting's overlay, and two LLM calls can run at once.
- [meeting-coach] `Services/Intelligence/LiveMeetingAdvisor.swift:96` — The overlay is armed and promises a suggestion regardless of LLM access; for a user with no key, no Pro and no local model, process() returns silently every tick and the promise is never kept or retracted — nothing is logged.
- [meeting-coach] `Services/Intelligence/LiveMeetingAdvisor.swift:288` — Every 30s partial also triggers a full AdviceService generate (gate + medium-tier LLM + SwiftData insert) whose only user-visible output is suppressed for the entire recording — and the cooldown the code comment relies on to justify this does not exist.
- [meeting-recording] `Services/Audio/MeetingRecorder.swift:543` — stop() during startup reuses the previous meeting's micClockStart and producedByTapThisRecording, opening a phantom 'down at stop' outage in the log.
- [meeting-recording] `Services/Audio/MicRecovery.swift:305` — A mic that was never granted permission opens its outage with the reason 'microphone permission revoked'.
- [meeting-recording] `Services/Audio/SystemAudioCaptureService.swift:111` — stop() schedules `Task { try? await stream?.stopCapture() }` then nils the stream synchronously, so the task reads nil and stopCapture is never called on the normal stop path.
- [meeting-recording] `Services/Audio/MeetingRecorder.swift:401` — The 5s system-audio budget also has to cover the Screen Recording TCC prompt, so a user who takes longer than ~5s to answer gets the start aborted.
- [meeting-transcription] `Services/Transcription/GeminiMeetingTranscriber.swift:290` — Gemini HTTP error bodies are logged unbounded, unlike Deepgram's 300-byte cap
- [meeting-transcription] `App/AppDelegate.swift:2047` — Logged finalize duration and word count are misleading after a BYOK fallback / with the incomplete note
- [meeting-transcription] `Services/Transcription/GeminiMeetingTranscriber.swift:220` — One failed Gemini slice throws away every successful slice and re-bills the whole meeting on the Pro proxy
- [memories] `Services/Intelligence/MutationService.swift:121` — MutationError does not conform to LocalizedError, so every degraded-store refusal is logged and shown to the user as a framework placeholder instead of a reason.
- [memories] `Services/Intelligence/EmbeddingService.swift:136` — Embedding writes swallow the save with `try?` and log success unconditionally on the next line.
- [memories] `Services/Intelligence/ProjectAggregator.swift:618` — backfillProjects counts conversations whose generate() failed and had to be restored as successfully classified.
- [memories] `Services/Intelligence/MemoryExtractor.swift:97` — EXTRACT NOW can no-op silently and still tell the user "No new memories this cycle".
- [memories] `Services/Intelligence/ChatToolExecutor.swift:398` — Memories created through the chat addMemory tool are never scheduled for embedding.
- [permissions-onboarding] `Services/System/PermissionsService.swift:75` — PermissionsService's request and observation surface is dead code: requestMicrophone and requestAccessibility have no callers, and the three @Published flags have no observers.
- [permissions-onboarding] `Views/Windows/Onboarding/OnboardingPermissionsPage.swift:12` — allGranted is documented as the container's NEXT gate but is referenced nowhere; onboarding can be completed with neither permission granted.
- [permissions-onboarding] `Views/Windows/Onboarding/OnboardingTryItPage.swift:226` — The try-it aura timer (and the 3-second finish timer) are never invalidated when the page is left mid-recording — the repeating timer then fires for the life of the process.
- [recap] `Services/Intelligence/WeeklyPatternDetector.swift:119` — The quiet-window branch runs before the Pro gate and saves with `try? ctx.save()`, so a BYOK non-Pro user with fewer than 3 conversations gets an empty digest and a 'Quiet week' card while one with 3+ gets nothing; a failed save there repeats the card every 5 minutes until midnight.
- [recap] `Services/Intelligence/DailySummaryService.swift:143` — `guard !isRunning else { return nil }` returns silently with no log, so a GENERATE tap landing on top of an in-flight timer run is a no-op with no trace anywhere.
- [recap] `Views/Windows/DashboardView.swift:295` — DailySummaryCard (295-426) is dead code — never instantiated — yet still carries a second GENERATE NOW path, and the file header sizes the layout around it.
- [recap] `Views/Windows/DashboardView.swift:153` — The comment claims ScreenTimeAggregator is shared with DailySummary so the two surfaces cannot diverge, but the recap never calls it; and the TODAY tile counts conversations by createdAt while the recap counts by startedAt.
- [recap] `Services/Intelligence/DailySummaryService.swift:671` — fetchConversationExcerpts fetches EVERY HistoryItem that has a conversationId — no date predicate, no fetchLimit — and filters in Swift on every recap generation.
- [recap] `Views/Windows/MainSettingsView.swift:2435` — User-facing Settings copy promises macOS notification delivery that no longer exists, and the weekly service header advertises a manual Insights-tab trigger that has no caller.
- [screen-agent] `Services/Intelligence/RealtimeScreenReactor.swift:77` — `guard !isProcessing else { return }` drops every context that arrives during an in-flight reactor call, with no log line; the 60 s per-app cooldown then also skips the next capture of that app, so the newest screen is the one discarded.
- [screen-agent] `Services/Intelligence/ScreenExtractor.swift:196` — When the model returns fewer observations than visits, the unmatched visits get no ScreenObservation and the checkpoint still advances — the shortfall is only visible as a mismatch between two numbers on the success line.
- [screen-agent] `Services/Intelligence/ProactiveContextService.swift:495` — `storage.save` (UserMemory + Obsidian vault export) runs before `delivery.deliver`; when deliver returns nil the memory and the vault file exist with no Inbox item behind them.
- [screen-agent] `Services/Intelligence/ScreenAgentDeliveryService.swift:486` — `unreadCount` reads a failed fetch as zero unread, so a store error clears the menu-bar badge exactly like a user who has read everything — silently.
- [screen-agent] `Services/Intelligence/RealtimeScreenReactor.swift:285` — `try? ctx.save()` swallows the staged-task insert failure, then the code logs '✅ Staged candidate', stamps lastFireAt and schedules embeddings for a row that may not exist.
- [structured-and-plan] `Services/Intelligence/StructuredGenerator.swift:930` — callLocalLLM caps the structured response at 384 tokens while the schema it requests can require substantially more, and a truncated JSON fails to parse into a completely silent no-write path.
- [structured-and-plan] `Views/Windows/ConversationDetailView.swift:659` — regenerate()'s failure detection only recognises title == "Quick note" or overview == "(empty)", so every real failure path (which leaves title nil) shows "Untitled" with no banner; and StructuredGenerator.lastError, the one place the reason is captured, is read by no view at all.
- [tasks] `Services/Intelligence/TaskExtractor.swift:151` — The local route caps output at maxTokens: 384, so a conversation with many action items yields truncated JSON → parseResponse nil → .failedAttempt, regenerated on every drain trigger until the 5-attempt drop.
- [tasks] `Services/Intelligence/TaskExtractor.swift:541` — Latent while the screen policy flag is off: the dedup context passed to the LLM includes staged (unreviewed, invisible) candidates labelled '[pending]', so a spoken commitment matching a hidden staged twin can be suppressed as a duplicate although no visible task exists.
- [tasks] `Services/System/TranscriptionCoordinator.swift:56` — weak var taskExtractor is assigned but never read anywhere in TranscriptionCoordinator — dead wiring left from the pre-conversation-close trigger.
- [translation] `Services/System/SelectionTranslator.swift:78` — The insert result is discarded: a failed clipboard write still plays the done sound and logs "✅ Done".
- [translation] `Services/System/TranscriptionCoordinator.swift:221` — translateNext is cleared before stage becomes .postProcessing, so every postProcessing UI branch keyed on it is dead for the tap flow.
- [translation] `Services/Processing/TextProcessor.swift:36` — The processing start line reports the OpenAI key length even when a different provider's key is in use.
- [translation] `Services/System/SelectionTranslator.swift:23` — The hold flow never checks the coordinator stage, so it fires ⌘C and clears the clipboard in the middle of a running dictation.
- [translation] `Services/System/SelectionTranslator.swift:6` — Doc drift: three doc comments and BRIEF.md say the hold threshold is 2s; the constant is 1.5s.
- [voice-question] `Services/Intelligence/ChatService.swift:284` — Cancellation from Esc is treated as a failure: a CancellationError bubble is persisted into MetaChat history
- [voice-question] `Services/Intelligence/ChatService.swift:282` — Reply can be spoken after the popup was dismissed, with no STOP control available
- [voice-question] `Services/System/HotkeyService.swift:100` — Voice question is unreachable in push-to-talk hotkey mode while Settings copy promises it unconditionally

## Содержимое в существующих логах (136)

Файл лога живёт на диске бессрочно. Эти строки пишут в него пользовательский текст.
Не правились в этом проходе — отдельная задача, чтобы не смешивать с добавлением логов.


### cards-surface (3)
- `Services/Intelligence/AdviceService.swift:165` — MISSED BY THE FIRST REVIEWER and the worst of the three. `NSLog("[Advice] ✅ Generated (%d chars): %@", advice.content.count, advice.content)` writes the ENTIRE LLM-generated advice text — unbounded, n
- `Services/System/NotificationService.swift:60` — `NSLog("[Notifications] ✅ Posted task: %@", String(task.taskDescription.prefix(60)))` writes up to 60 characters of the extracted task text — the user's own words from a dictation transcript — into th
- `Services/Intelligence/TaskPromotionService.swift:117` — `NSLog("[TaskPromotion] ⬆️ promoted: %@", String(candidate.taskDescription.prefix(60)))` — the same violation one hop upstream of this surface: line 118-120 immediately calls postPromotionNotification

### chat (5)
- `Services/Intelligence/ChatService.swift:223` — CONFIRMED — `NSLog("[ChatService] 🔧 Tool call queued: %@ → %@", call.tool, preview)` writes the validate() preview verbatim. ChatToolExecutor.validate builds those strings from live user data: 'Dismis
- `Services/Intelligence/ChatService.swift:269` — CONFIRMED — '✅ Got response (%d chars, pendingTool=%@, nativeId=%@)' passes `pendingPreview ?? "—"` (line 270), i.e. the same validate() preview string as line 223. The char count is fine; the second 
- `Services/Intelligence/ChatService.swift:587` — CONFIRMED — '🔧 Tool executed: %@ → %@ (audit=%@)' passes result.summary (588). ChatToolExecutor.execute composes it from the mutated rows: 'Dismissed task: \(task.taskDescription)' (241), 'Marked done
- `Services/Intelligence/ChatService.swift:704` — CONFIRMED — '🔁 followup inserted (text=%d chars, anotherTool=%@)' passes `pendingPreview ?? "—"` (705), which was set from executor.validate(nextCall) at 677-679 — the same task/memory/goal text as li
- `Services/Intelligence/ChatService.swift:727` — CONFIRMED — '↩︎ Undo: %@' passes undoMsg, returned by ChatToolExecutor.undo as 'Reverted: \(entry.resultSummary)' (ChatToolExecutor.swift:816). AuditLog.resultSummary is the stored execute() summary (

### dictation (6)
- `Services/Transcription/WhisperKitEngine.swift:100` — Writes up to 200 chars of a dropped segment's transcript verbatim: NSLog("[WhisperKit] [%d] ❌ dropped (hallucination): '%@'", i, String(t.prefix(200))). The hallucination filter has documented false p
- `Services/Transcription/WhisperKitEngine.swift:102` — Writes the last 60 chars of a segment that is KEPT and pasted: String(result.suffix(60)) — transcript content of the user's actual dictation.
- `Services/Transcription/WhisperKitEngine.swift:115` — Writes up to 100 chars of a de-duplicated segment verbatim: String(segment.prefix(100)) — transcript content.
- `Services/Processing/CorrectionMonitor.swift:122` — Writes 50 chars of the pasted transcript AND 50 chars of the user's edited text in one line ('%@' → '%@'): transcript content plus text the user typed into another application's field.
- `Services/Processing/CorrectionMonitor.swift:52` — Writes the focused field's placeholder verbatim (placeholder='%@'), read from another app's UI over the Accessibility API — screen text by the contract's definition (e.g. a recipient or channel name i
- `Services/Audio/AudioRecordingService.swift:632` — Writes the bound input device's name verbatim via AudioInputCatalog.boundInputDescription (also at :452 and :456, and inside the watchdog lines :668/:674). Not transcript or screen content, but Blueto

### integrations (10)
- `Services/Indexing/CalendarReaderService.swift:213` — Logs the matched calendar event's title verbatim: NSLog("[Calendar] ✅ linked conv %@ → event '%@' (score %.2f)", …, matched.title ?? "(untitled)", score). Meeting subjects routinely carry people, comp
- `Services/Indexing/AppleNotesReaderService.swift:240` — Logs the Apple Note title verbatim on the attachment-only skip: NSLog("[AppleNotes] skip attachment-only note '%@'", title).
- `Services/Indexing/FileMemoryExtractor.swift:222` — Logs the first 200 characters of the LLM response — model output derived from the user's file content: NSLog("[FileMemoryExtractor] ⚠️ Parse failed: %@", String(extracted.prefix(200))).
- `Services/Indexing/FileMemoryExtractor.swift:126` — Logs the user's filename on a per-file LLM failure: NSLog("[FileMemoryExtractor] ❌ %@: %@", file.filename, …). Personal-note filenames are user data.
- `Services/Indexing/FileIndexerService.swift:156` — Logs the full indexed folder path (NSLog("[FileIndexer] %@ → +%d new, %d updated", folderPath, …)); line 99 logs rootURL.path the same way. Both expose user-named folders and the home-directory userna
- `Services/Export/ObsidianExporter.swift:438` — Logs the full vault path of the deleted task file, whose filename embeds a slug of the task description (T-xxxxxxxx--<slug>.md): NSLog("[ObsidianExporter] 🗑 Deleted task file %@", f.path).
- `Services/Export/ObsidianExporter.swift:464` — Same for memories: logs f.path, where the filename is <day>--<slug-of-memory-content>--<shortID>.md under a project-named folder (Memories/<project>/…).
- `Services/Export/ObsidianExporter.swift:804` — Logs the project name via the stub path: NSLog("[ObsidianExporter] ✅ created project stub: %@", stubRel) where stubRel is Projects/<Project>.md; line 806 repeats it on failure. Project names are user 
- `App/AppDelegate.swift:2756` — Logs the calendar event title as `name`: NSLog("[CallDetect] gate calendar ready for %@ (eventID=%@) …", name, eventID). Traced: MeetingAutoStartGate.swift:99 builds .calendarReady(name: ev.title, eve
- `App/AppDelegate.swift:2852` — Logs the same calendar-derived title at auto-start: NSLog("[CallDetect] ▶️ %@ auto-start (%@, eventID=%@)", name, source, …); line 2846 logs it again in the 'already recording, skip auto-start' branch

### layout-switch (2)
- `Services/Processing/CorrectionMonitor.swift:122` — CONFIRMED content leak. `NSLog("[CorrectionMonitor] Detected edit: '%@' → '%@'", String(pastedText.prefix(50)), String(editedText.prefix(50)))` at :122-123 writes up to 50 characters of the pasted TRA
- `Services/Processing/CorrectionMonitor.swift:52` — CONFIRMED content leak. `NSLog("[CorrectionMonitor] Watching: prefix=%d, pasted=%d, suffix=%d, placeholder='%@'", ..., placeholder)` writes the placeholder string verbatim. It is read straight off the

### license-updates (4)
- `Services/License/LicenseService.swift:148` — Writes the account EMAIL to the durable log: NSLog("[License] ✅ Pro activated: %@ (%@)", result.email, license.plan). Confirmed content, not a length or a count — the contract names emails explicitly.
- `Services/License/LicenseService.swift:153` — Writes the account EMAIL: NSLog("[License] Signed in as %@ — no active subscription", result.email). Should be a state-only line ('signed in, no active subscription').
- `Services/License/LicenseService.swift:363` — Writes the account EMAIL on every successful verification: NSLog("[License] Verified: %@, pro=%@", result.email, isPro ? "YES" : "NO"). This is the worst of the three: it runs at launch AND on every 1
- `Services/License/LicenseService.swift:117` — Dumps the ENTIRE raw response body of the auth endpoint into the log: NSLog("[License] ❌ HTTP error: %@", body), where body is the unbounded UTF-8 of /api/auth/session (:116). This is content, not a s

### local-llm (10)
- `Services/LLM/GateClient.swift:118` — CONFIRMED CONTENT — `String(parsed.reasoning.prefix(80))`: 80 chars of the gate model's reasoning about the user's current screen/meeting context. LLM output, not a count. Owning directory (Services/L
- `Services/Intelligence/AdviceService.swift:151` — CONFIRMED CONTENT — `String(response.prefix(300))`: 300 chars of the raw LLM response on parse failure. When the route is local this is this feature's own model output, derived from the user's meeting
- `Services/Intelligence/AdviceService.swift:122` — CONFIRMED CONTENT — `String(gate.reasoning.prefix(80))`: model output describing the user's context, logged on every gate-skip.
- `Services/Intelligence/MemoryExtractor.swift:520` — CONFIRMED CONTENT — `String(extracted.prefix(200))`: 200 chars of the model's memory-extraction output (memory text about the user) on JSON parse failure. Consumer on this feature's traced path.
- `Services/Intelligence/InsightAssistantService.swift:178` — CONFIRMED CONTENT — `String(reason.prefix(120))`: model output explaining why no advice was given, derived from the user's screen context.
- `Services/Intelligence/TaskPromotionService.swift:117` — CONFIRMED CONTENT, outside this feature — `String(candidate.taskDescription.prefix(60))`: task text, explicitly named in the never-log list.
- `Services/Intelligence/ScreenExtractor.swift:327` — CONFIRMED CONTENT, outside this feature — `String(trimmedDesc.prefix(60))`: a task description extracted from screen text.
- `Services/Transcription/WhisperKitEngine.swift:62` — CONFIRMED CONTENT, outside this feature (transcription) — `String(promptText.prefix(80))`: user-supplied prompt text.
- `Services/Transcription/WhisperKitEngine.swift:100` — CONFIRMED CONTENT, outside this feature — `String(t.prefix(200))` on a dropped hallucination segment (and `String(result.suffix(60))` at 102): transcript text written to a durable log file.
- `Services/Transcription/WhisperKitEngine.swift:115` — CONFIRMED CONTENT, outside this feature — `String(segment.prefix(100))`: 100 chars of a dropped duplicate transcript segment.

### meeting-coach (10)
- `Services/Intelligence/LiveMeetingAdvisor.swift:250` — Writes the first 80 chars of the raw meeting transcript to the durable log: NSLog("[LiveAdvise] 🧹 partial emptied by strip (was '%@')", String(rawText.prefix(80))). Present in ~/Library/Logs/MetaWhisp
- `Services/Intelligence/MeetingCoachService.swift:133` — Writes the suggestion text — LLM output that quotes or paraphrases what was said in the meeting — first 80 chars: String(suggestion.text.prefix(80)).
- `Services/Intelligence/MeetingCoachService.swift:137` — Writes the raw LLM response, first 160 chars: String(response.prefix(160)). The response is generated over the transcript, the rolling meeting summary and stored memories.
- `Services/Intelligence/MeetingCoachService.swift:123` — Writes the local model's raw output before the cloud retry, first 120 chars: String(response.prefix(120)).
- `Services/Intelligence/LiveMeetingAdvisor.swift:280` — Writes the gate's 'reasoning' — model output describing the content of the 30s meeting partial — first 80 chars: String(gate.reasoning.prefix(80)).
- `Services/LLM/GateClient.swift:116` — Writes gate 'reasoning' (model output about the user's transcript or screen context) for every purpose including meeting_coach and advice, first 80 chars: String(parsed.reasoning.prefix(80)). 45 [Gate
- `Services/Intelligence/AdviceService.swift:122` — Writes gate 'reasoning' (model output about screen OCR + transcript), first 80 chars: String(gate.reasoning.prefix(80)).
- `Services/Intelligence/AdviceService.swift:146` — Writes the LLM's no_advice 'reason' in full — model prose describing what the user is doing on screen (parseNoAdvice returns parsed.reason, AdviceService.swift:539).
- `Services/Intelligence/AdviceService.swift:151` — Writes the raw LLM response, first 300 chars: String(response.prefix(300)).
- `Services/Intelligence/AdviceService.swift:165` — Writes the FULL advice content with no prefix cap: NSLog("[Advice] ✅ Generated (%d chars): %@", advice.content.count, advice.content) — LLM output derived from screen OCR, window titles and meeting tr

### meeting-recording (15)
- `App/AppDelegate.swift:2085` — `NSLog("[MetaWhisp] 🧹 sanitize: dropped (%@): '%@'", drop.reason, String(drop.segment.text.prefix(60)))` — 60 characters of a dropped meeting transcript segment written verbatim to the durable log. Th
- `App/AppDelegate.swift:2217` — `"⚠️ %@ chunk %d: dropped as %@ (RMS=%.4f): '%@'"` with `String(text.prefix(60))` — 60 characters of chunk transcript text; also mirrored into SuspectTranscriptLog on line 2219.
- `App/AppDelegate.swift:2257` — `"🧹 %@ chunk %d: emptied by strip (was '%@')"` with `String(text.prefix(80))` — 80 characters of raw chunk transcript text.
- `App/AppDelegate.swift:2295` — `"🎚️ %@ chunk %d utt: dropped (%@): '%@'"` with `String(rawUtterance.prefix(80))` — 80 characters of a Whisper utterance, i.e. meeting speech.
- `App/AppDelegate.swift:2301` — `"🧹 %@ chunk %d utt: emptied by strip (was '%@')"` with `String(rawUtterance.prefix(80))` — 80 characters of a raw utterance.
- `App/AppDelegate.swift:2463` — `"Meeting tail emptied by strip (was '%@')"` with `String(rawText.prefix(80))` — 80 characters of transcript text. In assembleMeetingTranscriptFromLive, which is dormant per the 2026-05-31 comment but
- `App/AppDelegate.swift:2756` — `"gate calendar ready for %@ (eventID=%@)"` — `name` here is the calendar event title, built at 2697 from `ev.title` and carried through MeetingAutoStartGate.Decision.calendarReady (MeetingAutoStartGa
- `App/AppDelegate.swift:2727` — `"back-to-back via eventID: newID=%@ ('%@') != recordedID=%@"` — the quoted `newName` is the next calendar event's title.
- `App/AppDelegate.swift:2837` — `"%@ countdown cancelled by user"` — `name` is the calendar event title whenever runCountdownAndStartRecording was entered from the calendar path (2757); on the fallback path it is only the app name.
- `App/AppDelegate.swift:2846` — `"%@ countdown end — but already recording, skip auto-start"` — same `name`, calendar event title on the calendar path.
- `App/AppDelegate.swift:2852` — `"▶️ %@ auto-start (%@, eventID=%@)"` — same `name`, calendar event title on the calendar path, written on every auto-start.
- `App/AppDelegate.swift:2877` — `"[CalendarEndStop] skip arming for '%@' (duration %.0fs > 6h, treated as all-day)"` — the quoted string is the calendar event title.
- `App/AppDelegate.swift:2919` — `"%@ post-start sniff inconclusive — mic had an outage, keeping the recording"` — same `name`, calendar event title on the calendar path.
- `App/AppDelegate.swift:2921` — `"⚠️ %@ post-start sniff — 60s of silence (rawRMS=%.4f), stopping discardly"` — same `name`, calendar event title on the calendar path.
- `Services/Audio/AudioRecordingService.swift:632` — Borderline but real: `"bind → %@ | %.0f Hz, %d ch, layout=%@"` writes AudioInputCatalog.boundInputDescription (device name plus UID) on every start, and lines 452 / 456 write `builtIn.name` / `dev.nam

### meeting-transcription (11)
- `App/AppDelegate.swift:2085` — «🧹 sanitize: dropped (%@): '%@'» writes `String(drop.segment.text.prefix(60))` — 60 characters of real meeting speech whenever the echo / foreign-fragment rule false-positives. Redundant: line 2086 al
- `App/AppDelegate.swift:2217` — «⚠️ %@ chunk %d: dropped as %@ (RMS=%.4f): '%@'» writes `String(text.prefix(60))` — 60 characters of chunk transcript text (format string at 2217, text argument at 2218); SuspectTranscriptLog.append o
- `App/AppDelegate.swift:2257` — «🧹 %@ chunk %d: emptied by strip (was '%@')» writes `String(text.prefix(80))` — 80 characters of chunk transcript text.
- `App/AppDelegate.swift:2295` — «🎚️ %@ chunk %d utt: dropped (%@): '%@'» writes `String(rawUtterance.prefix(80))` — 80 characters of an utterance judged low-confidence. The comment above it (TR-5, 2283) still justifies this as recov
- `App/AppDelegate.swift:2301` — «🧹 %@ chunk %d utt: emptied by strip (was '%@')» writes `String(rawUtterance.prefix(80))` — 80 characters of utterance text.
- `Services/Transcription/WhisperKitEngine.swift:100` — «[WhisperKit] [%d] ❌ dropped (hallucination): '%@'» writes `String(t.prefix(200))` — up to 200 characters of a decoded segment. Reached by the on-device meeting path (and dictation).
- `Services/Transcription/WhisperKitEngine.swift:102` — «[WhisperKit] [%d] ✂️ trimmed tail: '%@'» writes `String(result.suffix(60))` — the last 60 characters of a KEPT decoded segment, i.e. real speech, not just a discarded artifact.
- `Services/Transcription/WhisperKitEngine.swift:115` — «[WhisperKit] ❌ dropped duplicate segment: '%@'» writes `String(segment.prefix(100))` — 100 characters of a decoded segment.
- `Services/Transcription/WhisperKitEngine.swift:62` — «[WhisperKit] 📖 Prompt: %d words → %d tokens (%@)» writes `String(promptText.prefix(80))` — the decoder initial_prompt. Verified that today it is only the app-curated glossary (TranscriptionLanguageRe
- `App/AppDelegate.swift:2852` — «[CallDetect] ▶️ %@ auto-start (%@, eventID=%@)» prints `name`, which on the calendar path is the calendar event title — MeetingAutoStartGate.swift:99 returns `.calendarReady(name: ev.title, eventID: 
- `App/AppDelegate.swift:2727` — «[CallDetect] back-to-back via eventID: newID=%@ ('%@') != recordedID=%@ …» prints `newName`, the new calendar event's title — BackToBackTransition.swift:57 destructures `.calendarReady(name, eventID)

### memories (16)
- `Services/Intelligence/MemoryExtractor.swift:520` — CONFIRMED — `NSLog("[MemoryExtractor] ⚠️ JSON parse failed: %@", String(extracted.prefix(200)))` writes 200 chars of raw model output, which on this path quotes memory text and transcript-derived mate
- `Services/Intelligence/MemoryExtractor.swift:527` — CONFIRMED — `"⚠️ Rejected memory (>15 words, %d): %@"` logs `json.content`, i.e. the candidate memory sentence in full.
- `Services/Intelligence/MemoryExtractor.swift:531` — CONFIRMED — `"⚠️ Rejected memory (bad category '%@'): %@"` logs `json.content` plus the raw category string.
- `Services/Intelligence/ProjectAggregator.swift:548` — CONFIRMED — `"+new project alias: %@"` writes the raw project name the LLM distilled from the user's conversations (a title quoting user data).
- `Services/Intelligence/ProjectAggregator.swift:539` — CONFIRMED — `"dedup: '%@' → '%@'"` writes both the incoming raw project name and the canonical name.
- `Services/Intelligence/ProjectAggregator.swift:433` — CONFIRMED — `"renameCanonical: '%@' → '%@'"` logs text the user TYPED into the RENAME field plus the previous project name (also :422 on the not-found path).
- `Services/Intelligence/ProjectAggregator.swift:463` — CONFIRMED — `"setCanonical: '%@' → '%@'"` logs two project names; :449 and :454 log them on the refusal paths as well.
- `Services/Intelligence/ProjectAggregator.swift:503` — CONFIRMED — `"splitAlias: '%@' extracted from '%@' as new alias"` logs both names; :475, :480 and :485 do the same on the refusal paths.
- `Services/Intelligence/ProjectAggregator.swift:239` — CONFIRMED — `"🗑 deleted project '%@' — %d conversations unlinked"` logs the project name (also :212 on the not-found no-op).
- `Services/Intelligence/ProjectAggregator.swift:376` — CONFIRMED — `"recanonicalize: '%@' → '%@'"` logs the old and newly promoted project-name variants.
- `Services/Intelligence/ProjectAggregator.swift:403` — CONFIRMED — `"prune: '%@' (0 conversations across %d variants)"` logs the project name of the pruned cluster.
- `Services/Intelligence/ProjectAggregator.swift:669` — CONFIRMED — `"deterministic merge: '%@' ← '%@'"` logs the winner and loser project names; :731 does the same for the embedding merge, plus the similarity score.
- `Services/Intelligence/StructuredGenerator.swift:394` — CONFIRMED — on the path that feeds resolveCanonical/embedConversationInBackground, the ✅ line logs `parsed.title` (the LLM-written conversation title, which quotes user data) and `conv.primaryProject`
- `Services/Export/ObsidianExporter.swift:464` — CONFIRMED — `"🗑 Deleted memory file %@", f.path` logs the full vault path, and ObsidianPath.memoryPath (ObsidianPath.swift:344-354) builds the filename as `<day>--slugForFilename(content)--<id>.md` in
- `Services/Intelligence/RealtimeScreenReactor.swift:447` — CONFIRMED — `"✅ Auto-completed fulfilled task: %@", String(task.taskDescription.prefix(60))` writes 60 chars of the task text; :288 logs a staged candidate's description prefix together with the app n
- `Services/Intelligence/TaskPromotionService.swift:117` — CONFIRMED — `"⬆️ promoted: %@", String(candidate.taskDescription.prefix(60))` writes 60 chars of the promoted task's text.

### permissions-onboarding (7)
- `App/AppDelegate.swift:2085` — Confirmed content: NSLog("[MetaWhisp] 🧹 sanitize: dropped (%@): '%@'", drop.reason, String(drop.segment.text.prefix(60))) — up to 60 characters of the user's meeting transcript, verbatim, not a length
- `App/AppDelegate.swift:2257` — Confirmed content: NSLog("[MetaWhisp] 🧹 %@ chunk %d: emptied by strip (was '%@')", label, i + 1, String(text.prefix(80))) — up to 80 characters of a raw transcript chunk.
- `App/AppDelegate.swift:2301` — Confirmed content: NSLog("[MetaWhisp] 🧹 %@ chunk %d utt: emptied by strip (was '%@')", label, i + 1, String(rawUtterance.prefix(80))) — the same pattern on the per-utterance path, up to 80 characters 
- `App/AppDelegate.swift:2463` — Confirmed content: NSLog("[MetaWhisp] Meeting tail emptied by strip (was '%@')", String(rawText.prefix(80))) — up to 80 characters of the raw meeting-tail transcript. (The sibling at :2465 is clean — 
- `App/AppDelegate.swift:2727` — Confirmed content: NSLog("[CallDetect] back-to-back via eventID: newID=%@ ('%@') != recordedID=%@ …", newEventID, newName, …) — quotes the incoming calendar event title on disk.
- `App/AppDelegate.swift:2756` — Confirmed content: NSLog("[CallDetect] gate calendar ready for %@ (eventID=%@) — running countdown", name, eventID). On the .calendarReady path `name` is EKEvent.title, read at :2696-2699, so the titl
- `App/AppDelegate.swift:2852` — Confirmed content: NSLog("[CallDetect] ▶️ %@ auto-start (%@, eventID=%@)", name, source, …) — the calendar event title again on the auto-start path. The same `name` is written at :2837 (countdown canc

### recap (4)
- `Services/Intelligence/DailySummaryService.swift:263` — CONFIRMED content. `NSLog("[DailySummary] ✅ Generated: %@ · L=%d …", headline, …)` writes the LLM headline verbatim to ~/Library/Logs/MetaWhisp.log. headline comes from headlineAgent (459-499), whose 
- `Services/Intelligence/DailySummaryService.swift:508` — CONFIRMED content. `NSLog("[DailySummary] %@ parse failed: %@", key, String(extracted.prefix(120)))` writes 120 characters of the raw model response — not a length. On a malformed answer that response
- `Services/Intelligence/DailySummaryService.swift:520` — CONFIRMED content. Identical leak in parseString for the energy / emoji / headline agents: `String(extracted.prefix(120))` of the raw model response. Delete the line.
- `Services/Intelligence/WeeklyPatternDetector.swift:298` — CONFIRMED content. `NSLog("[Pattern] ⚠️ Parse failed — raw response prefix: %@", String(extracted.prefix(200)))` (298-299) writes 200 characters of raw model output. Per the system prompt at 176-222 t

### screen-agent (15)
- `Services/Screen/ScreenContextService.swift:785` — Every successful capture writes the focused window title (prefix 40) to the durable log — document names, email subjects, chat/contact names, URLs.
- `Services/Intelligence/RealtimeScreenReactor.swift:139` — Gate reasoning (String(gate.reasoning.prefix(80))) — model prose about what is on the screen — logged on every gate skip.
- `Services/Intelligence/RealtimeScreenReactor.swift:165` — 200 chars of raw model output (a description of the user's screen) logged on parse failure.
- `Services/Intelligence/RealtimeScreenReactor.swift:183` — Window title (String(context.windowTitle.prefix(50))) logged on every 'No task' outcome — the most frequent reactor outcome.
- `Services/Intelligence/RealtimeScreenReactor.swift:196` — Task description derived from screen text logged at 196-197, 211-212, 216-217, 223 (full trimmedDesc), 230-231 (full trimmedDesc), 243-244, 250, 268-269, 288 — names, deliverables and quoted asks from
- `Services/Intelligence/RealtimeScreenReactor.swift:450` — The user's own task text (String(task.taskDescription.prefix(60))) logged on auto-completion.
- `Services/Intelligence/ScreenExtractor.swift:282` — Task descriptions derived from screen text logged at 282-283, 292-293, 302-303, 307-308, 313 (full trimmedDesc), 321-322 (full trimmedDesc), 327, 337-338.
- `Services/Intelligence/ScreenExtractor.swift:680` — 400 chars of raw model output (observations and memories about the user, e.g. 'User builds …', named colleagues) logged on JSON decode error.
- `Services/Intelligence/InsightAssistantService.swift:136` — Gate reasoning about the current screen (80 chars) logged on every proactive gate skip.
- `Services/Intelligence/InsightAssistantService.swift:178` — The investigator's 'no advice' reason is the model's context_summary (InsightInvestigator.swift:274) — one line describing what the user is doing — logged at 120 chars.
- `Services/Intelligence/InsightAssistantService.swift:204` — Single-pass 'no advice' reason is the model's context_summary / current_activity (InsightOutputParser.swift:93-97) — a description of the user's screen — logged in full.
- `Services/Intelligence/InsightAssistantService.swift:208` — 200 chars of raw model output logged on parse error.
- `Services/Intelligence/InsightAssistantService.swift:219` — Insight body — the comment text about the user's screen and history — logged at 219-221 (80 chars), 227-228 (80 chars) and 232-233 (100 chars, on every surfaced comment).
- `Services/Intelligence/InsightStorage.swift:101` — Insight body (80 chars) logged on every successful save.
- `Services/LLM/GateClient.swift:116` — Gate reasoning (80 chars) logged for every gate call, including proactive and reactor calls whose context is raw screen OCR (InsightAssistantService:117-121 builds it from app, window title and 2000 c

### structured-and-plan (3)
- `Services/Intelligence/StructuredGenerator.swift:394` — The success line writes `parsed.title` (LLM output built from the transcript — people, companies, project codenames) and `conv.primaryProject` plus the category to ~/Library/Logs/MetaWhisp.log for EVE
- `Services/Intelligence/StructuredGenerator.swift:955` — validateSFSymbol logs `trimmed` — the raw value the model put in the JSON `icon` field — whenever it is not a valid SF Symbol name. Verified: the valid case returns at :953 without logging, so the log
- `Services/Intelligence/ProjectAggregator.swift:548` — `NSLog("[ProjectAggregator] +new project alias: %@", trimmed)` writes the project name the LLM extracted from the transcript to the durable log on every newly seen project. Reached from this feature's

### tasks (8)
- `Services/Intelligence/TaskExtractor.swift:566` — CONFIRMED content: `NSLog("[TaskExtractor] ⚠️ JSON parse failed: %@", String(extracted.prefix(200)))` writes 200 chars of raw LLM output. On a prose or chain-of-thought response this quotes the transc
- `Services/Intelligence/TaskExtractor.swift:578` — CONFIRMED content: `NSLog("[TaskExtractor] ⚠️ Rejected task (>15 words): %@", json.description)` writes the FULL model-generated task description, derived verbatim from the user's speech. Replace with
- `Services/Intelligence/TaskPromotionService.swift:117` — CONFIRMED content: `NSLog("[TaskPromotion] ⬆️ promoted: %@", String(candidate.taskDescription.prefix(60)))` writes 60 chars of a screen-OCR-derived task description — names, chat contents. Content-fre
- `Services/Intelligence/TaskPrioritizationService.swift:112` — CONFIRMED content: the parse-failure log writes `String(response.prefix(200))` (arg on line 113). The comment at 109-111 justifies it with the 2026-07-17 gpt-oss incident, but the prompt it echoes con
- `Services/System/NotificationService.swift:60` — CONFIRMED content (first reviewer said 61; the statement is on line 60): `NSLog("[Notifications] ✅ Posted task: %@", String(task.taskDescription.prefix(60)))`. Called once per extracted task from Task
- `Services/Intelligence/ScreenExtractor.swift:337` — CONFIRMED content (adjacent producer of this feature's staged input): `NSLog("[ScreenExtractor] observed a task in the hour's work — not creating one: %@", String(trimmedDesc.prefix(60)))` (arg on 338
- `Services/Intelligence/ScreenExtractor.swift:327` — CONFIRMED content, MISSED by the first reviewer and reachable TODAY (it sits before the policy guard at 336): `NSLog("[ScreenExtractor] Near-duplicate task, skipping: %@", String(trimmedDesc.prefix(60
- `Services/Intelligence/RealtimeScreenReactor.swift:268` — CONFIRMED content (adjacent producer of this feature's staged input): `NSLog("[RealtimeReactor] observed a task on screen — not creating one: %@", …prefix(60))` (arg on 269). Same file leaks OCR-deriv

### translation (1)
- `Services/Cloud/OpenAIService.swift:90` — `NSLog("[LLM] ❌ Error: %@", bodyStr)` writes the provider's ENTIRE response body verbatim and uncapped (bodyStr is `String(data: data, encoding: .utf8)` from :89) into the durable ~/Library/Logs/MetaW

### voice-question (6)
- `Services/Intelligence/ChatService.swift:223` — NSLog("[ChatService] 🔧 Tool call queued: %@ → %@", call.tool, preview) — `preview` is ChatToolExecutor.validate's success string and quotes user data verbatim: 'Create task "<description>"' and '(wait
- `Services/Intelligence/ChatService.swift:587` — NSLog("[ChatService] 🔧 Tool executed: %@ → %@ (audit=%@)", call.tool, result.summary, …) — result.summary is built in ChatToolExecutor.execute as 'Added task: <desc> (waiting on <assignee>)', 'Dismiss
- `Services/Screen/ScreenContextService.swift:785` — NSLog("[ScreenContext] Captured: %@ — %@ (%d chars OCR)", appName, String(windowTitle.prefix(40)), …) — writes up to 40 chars of the frontmost window title (email subject, document name, chat partner)
- `Services/Transcription/WhisperKitEngine.swift:100` — NSLog("[WhisperKit] [%d] ❌ dropped (hallucination): '%@'", i, String(t.prefix(200))) — up to 200 characters of transcript segment text, i.e. what the user said into the voice question. The filter (cle
- `Services/Transcription/WhisperKitEngine.swift:102` — NSLog("[WhisperKit] [%d] ✂️ trimmed tail: '%@'", i, String(result.suffix(60))) — 60 characters of the KEPT transcript segment (the log fires on the branch that appends the text), so this is user speec
- `Services/Transcription/WhisperKitEngine.swift:115` — NSLog("[WhisperKit] ❌ dropped duplicate segment: '%@'", String(segment.prefix(100))) — 100 characters of transcript text; the duplicate of a segment whose twin was kept, so the same user speech is in 

---

## Что вычищено в коммите «no user content in the log» (2026-09-06)

Убрано из файла лога: адрес почты при активации Pro и при проверке лицензии;
весь текст совета; куски транскрипта (сегменты, отброшенные санитайзером,
галлюцинации WhisperKit, дубли, хвост встречи); тексты задач при постановке,
продвижении и дедупликации; текст памяти при отклонении; вывод модели при
ошибке разбора (шесть мест); превью инструментов чата; заголовок окна экрана;
заголовки заметок и событий календаря; пути к файлам хранилища, собранные из
названий задач и проектов; **набранный пользователем текст в `CorrectionMonitor`**
— он логировался вопреки прямому обещанию в соседнем файле.

Вместо содержимого пишутся длина, счётчик, идентификатор или причина словами.
Причина отказа от прокси разведена на два адресата: пользователю на экран
по-прежнему показывается фраза прокси (`StructuredGenerator.proxyReason`),
в долговечный файл идёт `LLMRequestBody.proxyReason` — разобранное поле
`error` или размер тела, но не тело.

### Осталось открытым (решение владельца)

**Названия проектов** — `ProjectAggregator` пишет их примерно в 20 строках
(`dedup: 'A' → 'B'`, `merge`, `renameCanonical`, `splitAlias`). Это данные
пользователя, но это же единственный способ отладить агрегатор, который
регулярно ошибается со слияниями. Не трогал: нужно твоё решение — вычистить
(и отлаживать вслепую) или оставить.

Безопасными считаю и оставил: коды языков, роли звуков, имена приложений,
`reasonCode`, `rawValue` перечислений, идентификаторы событий, UUID.

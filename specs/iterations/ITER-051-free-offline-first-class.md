# ITER-051 — Free + offline: first-class product (полное ревью 2026-07-06)

> 8-осевое многоагентное ревью free-плана с оффлайн-генерацией (онбординг →
> транскрибация созвонов), каждая багрепорт-находка адверсариально проверена.
> Итог: **41 подтверждённый баг + 23 улучшения**. Ни одна находка не отсеяна
> проверкой. Персоны: (a) свежий фри-юзер без ключей; (b) фри-юзер с локальной
> MLX-моделью.

## Сквозные темы (важнее отдельных багов)

1. **«Локальная модель» продана, но не подключена** — самый большой обман фри-тира:
   Settings/футер обещают structured/translate/chat/экстракцию на локальной модели,
   но TextProcessor, MetaChat, интеграционные ридеры и переводчик ходят ТОЛЬКО в
   openai/cerebras и молча падают/деградируют без ключа. Починить роутинг = поднять
   пол-продукта одним рычагом.
2. **Голосовой вопрос (Right ⌘) виснет в THINKING навсегда** у фри-юзера — найдено
   двумя осями независимо.
3. **Тихие провалы вместо ошибок** — переводы вставляют исходник, попытки диктовки
   молча выкидываются, пилюля не имеет состояния ошибки вообще.
4. **Модель-менеджмент врёт**: частичная закачка = «downloaded», Large V3 «скачана»
   когда на диске только Turbo, ACTIVE = выбрана-а-не-загружена, замёрзший прогресс
   без ретрая.
5. **Митинги: аудио 60+ минут живёт только в RAM** и теряется целиком при любом сбое
   транскрипции; смена наушников убивает захват молча.
6. **Дефолт languagе = Russian захардкожен** — для не-русского юзера продукт сломан
   из коробки (и нет опции Auto в UI).


## 1. Onboarding — путь до первой диктовки

**Вердикт:** The skeleton is genuinely first-class for a free user: real model downloads with live progress, real BYOK key validation, and a readiness gate (pinned by OnboardingReadinessTests) that makes it structurally impossible to finish with a dead engine unless you explicitly choose "set up later". What is second-class is everything that happens when a step doesn't go perfectly: the download→load seam is invisible (a failed or slow model load blocks NEXT forever with a ✓-marked model), the try-it page has no failure feedback and can lie that recording is active, permission prompts fire contextlessly at launch with a no-op ALLOW fallback, and the shortcuts screen teaches translate/rewrite that silently degrade to raw text on the free tier. Wispr Flow/Superwhisper parity needs the failure paths and copy honesty, not more happy-path polish.

- [ ] **[P1]** 🐛 Model load failure after download is swallowed — onboarding NEXT blocked forever with a ✓-marked model
      `App/AppDelegate.swift:481`
      _As a free user who just downloaded the 950 MB model, I want to know why NEXT is still disabled, so I don't conclude the app is broken._
      **Fix:** Publish a load state end-to-end: add a `.loading` phase (or a `@Published isLoadingModel` on the coordinator), set it around `engine.loadModel` in the auto-load sink, set `coordinator.lastError` in the catch, and have OnboardingModelPage render "Loading model — first time can take a few minutes…" plus a visible failure row with a RETRY that re-triggers the load (not the download).
- [ ] **[P2]** 🐛 Try-it page has no failure path — discarded/failed attempts leave it stuck claiming recording is active
      `Views/Windows/Onboarding/OnboardingTryItPage.swift:204`
      _As a free user testing my voice for the first time, I want the page to tell me when an attempt was discarded, so I can retry instead of staring at a fake 'recording' screen._
      **Fix:** In `handleStageChange`, on `.idle` while `phase == 1 || phase == 2` and no result arrived, reset to phase 0 and show `coordinator.lastError` (or a generic "Didn't catch that — tap Right ⌘ and try again") inline on the page.
- [ ] **[P2]** 🐛 Onboarding teaches Right ⌥ translate to free users, but their translation silently pastes untranslated text
      `Views/Windows/Onboarding/OnboardingDonePage.swift:141`
      _As a free user with no API key, I want the shortcuts screen to be honest about what works on my tier, so my first Right ⌥ tap doesn't paste my words un-translated with no explanation._
      **Fix:** Either badge TRANSLATE/Rewrite as "Pro or API key" on the features/done pages for non-ready users, or (owner-layer) route free translation/structuring through the active local LLM when one is loaded; at minimum, don't paste raw text pretending translation happened — surface the noAPIKey error where the user is looking.
- [ ] **[P2]** 🐛 Permissions page ALLOW button is a silent no-op once mic was denied — and the real prompts already fired contextlessly at launch
      `Views/Windows/Onboarding/OnboardingPermissionsPage.swift:87`
      _As a free user who dismissed the surprise mic prompt at launch, I want the ALLOW button to actually take me somewhere, so I can grant the permission the app needs._
      **Fix:** In `requestMic()`, branch on `authorizationStatus`: `.notDetermined` → requestAccess; `.denied/.restricted` → open `x-apple.systempreferences:...Privacy_Microphone` (same URL the coordinator uses). Root cause: move the launch-time mic/AX requests out of setupServices when `hasCompletedOnboarding == false` so onboarding owns the first prompt in context.
- [ ] **[P2]** 🐛 isDownloaded substring match falsely reports Large V3 as downloaded when only Turbo is on disk
      `Services/Transcription/ModelManagerService.swift:141`
      _As a free local-model user, I want the model list to reflect what is actually on disk, so switching models doesn't kick off a surprise gigabyte download or a dead engine._
      **Fix:** Match exactly: `downloadedModels.contains { $0 == info.variant }` (the prefix `contains` also matches nothing legitimate — WhisperKit folder names equal the variant), and add a regression test with turbo-on-disk asserting `isDownloaded("large-v3") == false`.
- [ ] **[P2]** ✨ Permissions step is not gated — `allGranted` is dead code whose comment claims the container uses it
      `Views/Windows/Onboarding/OnboardingPermissionsPage.swift:12`
      _As a free user, I want onboarding to stop me (or loudly warn me) before I continue without mic access, so my try-it moment doesn't fail mysteriously._
      **Fix:** Wire the existing `allGranted` (or at least the mic check) into `nextBlocked` for page 3 with the same "or skip" escape hatch used on page 2, and delete the stale comment if gating is intentionally omitted.
- [ ] **[P3]** ✨ Wizard forces an idle wait through the entire download+load instead of letting permissions proceed in parallel; no disk-space preflight
      `Views/Windows/Onboarding/OnboardingContainer.swift:64`
      _As a free user on hotel Wi-Fi, I want to grant permissions and learn the hotkeys while the 950 MB model downloads, so setup takes one pass instead of minutes of staring at a progress bar._
      **Fix:** Unblock NEXT on page 2 while `modelManager.isDownloading` for the selected model (keeping the existing final-page gate, and re-gating before try-it), show a compact live download status in the bottom bar, and preflight `volumeAvailableCapacityForImportantUsage` against the model size with a human-readable "Not enough disk space (need ~1 GB, have X)" message.
- [ ] **[P3]** ✨ Closing the onboarding window strands the first-launch user — no way to reopen it in-session
      `Views/Windows/OnboardingWindowController.swift:28`
      _As a free user who accidentally closed the welcome window, I want re-activating the app to bring onboarding back, so my first-run doesn't end as an invisible menu-bar process._
      **Fix:** Implement `applicationShouldHandleReopen` to call `onboardingWindow.show()` while `!hasCompletedOnboarding` (and open the main window otherwise); optionally also re-surface onboarding from the menu-bar popover while incomplete.

## 2. Whisper model management

**Вердикт:** The happy path is genuinely solid for a free app — real download progress with speed, an onboarding gate that waits for the model to actually load, auto-load on download completion, and RAM freed when switching to cloud. But it is one network blip away from lying: "downloaded" means "a folder exists" (partial downloads pass), "ACTIVE" means "selected in UserDefaults" (not loaded), a failed download in Settings is a frozen progress bar with no retry, and there is no model delete, no disk-space check, and no warm-up feedback. Off the happy path this is second-class vs Wispr Flow/Superwhisper; the fix is a small honest state machine keyed to on-disk completeness and actual engine load state, plus retry/delete affordances.

- [ ] **[P1]** 🐛 Partial/interrupted download passes as "downloaded" — model dead-ends with lying UI
      `/Users/android/Code/MetaWhisp/Services/Transcription/ModelManagerService.swift:139`
      _As a free user whose Mac slept or app quit mid-download, I relaunch and see the model as downloaded and ACTIVE, but dictation says "No model loaded. Go to Settings to download one" — and Settings offers me nothing to fix it._
      **Fix:** Make isDownloaded() verify completeness, not existence: check for the required file set (config.json, tokenizer, AudioEncoder.mlmodelc, TextDecoder.mlmodelc, MelSpectrogram.mlmodelc) inside the variant folder, or write a ".complete" marker only after WhisperKit.download returns and the phase-done disk check passes. Incomplete folders should render the DOWNLOAD button (HubApi resumes via etag, so re-download is cheap) and pass download: false / explicit modelFolder into WhisperKitConfig so load never silently re-downloads.
- [ ] **[P1]** 🐛 Failed download in Settings is a frozen progress bar with no retry — copy even says "tap to retry"
      `/Users/android/Code/MetaWhisp/Views/Windows/MainSettingsView.swift:348`
      _As a free user whose Wi-Fi dropped at 60% of the 950MB download, I want to tap retry, but the row shows a dead progress bar stuck at 60% and the only retry path is restarting the app._
      **Fix:** In modelAction, gate the progress branch on phase != .failed (e.g. `modelManager.currentDownloadModel == info.id && modelManager.isDownloading`), and render a RETRY BlocksButton calling startDownload(info.id) when phase is .failed for that model. In startDownload, reset currentDownloadModel at the top so stale failure state can't leak.
- [ ] **[P1]** 🐛 Variant prefix collision: Large V3 shows as downloaded when only Large V3 Turbo is on disk
      `/Users/android/Code/MetaWhisp/Services/Transcription/ModelManagerService.swift:141`
      _As a free user who downloaded the recommended Turbo model, I see Large V3 offering "USE" (implying it's already on my disk); clicking it silently kicks off an invisible ~950MB download — or offline, silently does nothing while showing ACTIVE._
      **Fix:** Match exactly against the directory name: `downloadedModels.contains { $0 == info.variant }` (dir names in the argmaxinc repo equal the variant string). Pin with a unit test asserting isDownloaded("large-v3") is false when downloadedModels == ["openai_whisper-large-v3_turbo"]. Also pass download:false (or explicit modelFolder) in WhisperKitEngine.loadModel so the engine can never start a hidden gigabyte download.
- [ ] **[P2]** 🐛 "ACTIVE" means selected, not loaded — model switch failures are silent and history misattributes the model
      `/Users/android/Code/MetaWhisp/Views/Windows/MainSettingsView.swift:339`
      _As a free user who clicked USE on a second downloaded model, I see ACTIVE instantly, but my next dictations still run on the old model (multi-second load, or a failed one), and my History claims they used the new model._
      **Fix:** Drive the row state from coordinator.loadedWhisperModelId: selected-and-loaded → ACTIVE; selected-but-loading → spinner "LOADING…"; selected-but-load-failed → red "FAILED — RETRY". Set coordinator.lastError in both silent catch blocks in AppDelegate, and stamp history with loadedWhisperModelId instead of selectedModel.
- [ ] **[P2]** ✨ No model warm-up communication anywhere — progressHandler is accepted and ignored
      `/Users/android/Code/MetaWhisp/Services/Transcription/WhisperKitEngine.swift:18`
      _As a fresh-install free user whose 950MB download just hit ✓, I stare at a disabled NEXT button (onboarding) or an "ACTIVE" label (Settings) for 30s-2min of CoreML first-load specialization with zero indication anything is happening._
      **Fix:** Publish a modelLoading: Bool (or loadingModelId) on the coordinator, set around every engine.loadModel call; show "Loading model — first load can take a minute…" in the onboarding blocked-bar and as the Settings row state; change the not-ready dictation error to distinguish "still loading, try again shortly" from "nothing downloaded". Optionally set prewarm to smooth peak RAM on low-RAM Macs.
- [ ] **[P2]** ✨ No way to delete a downloaded model or see disk usage
      `/Users/android/Code/MetaWhisp/Views/Windows/MainSettingsView.swift:184`
      _As a free user who tried Tiny, Small and Turbo before settling on one, I want to reclaim the ~1.3GB the losers occupy, but the app offers no delete — I don't even know the files live in ~/Documents/huggingface._
      **Fix:** Add a deleteModel(id:) on ModelManagerService (removeItem on the variant folder in both scan locations + refreshDownloaded, guarding the currently-loaded model by unloading first), and surface it as a small trash/context-menu action on downloaded non-active rows, with actual folder size shown next to the catalog estimate.
- [ ] **[P2]** ✨ No disk-space preflight and raw error interpolation shown to the user
      `/Users/android/Code/MetaWhisp/Services/Transcription/ModelManagerService.swift:130`
      _As a free user with 2GB free disk, I start the 950MB recommended download, it dies near the end, and the UI shows me something like 'Error Domain=NSPOSIXErrorDomain Code=28 …' instead of telling me I'm out of space before wasting the bandwidth._
      **Fix:** Before download: query URLResourceValues.volumeAvailableCapacityForImportantUsage against a per-model byte estimate (add bytes to ModelInfo) and fail fast with "Not enough disk space — need ~1GB, you have X". In the catch, map URLError.notConnectedToInternet/timedOut and POSIX ENOSPC to short friendly strings, keeping the raw error in the os_log only.
- [ ] **[P3]** ✨ One-size-fits-all catalog: 950MB Turbo recommended to every Mac, device-aware recommendation API unused; "VERIFYING" phase verifies nothing
      `/Users/android/Code/MetaWhisp/Services/Transcription/ModelManagerService.swift:39`
      _As a free user on an 8GB M1 Air, I follow the RECOMMENDED badge onto large-v3-turbo and get a ~1.5GB-resident model that swaps my machine, when Small would have been the honest recommendation for my hardware._
      **Fix:** Use ProcessInfo.processInfo.physicalMemory (or WhisperKit.recommendedModels()) to pick the RECOMMENDED badge: Turbo for ≥16GB, Small for 8GB — and add Small as a third onboarding card. Rename the fake phase to "FINISHING…" or implement a real completeness check (required-file-set scan) so the label matches reality.

## 3. Dictation core (on-device)

**Вердикт:** The mid-pipeline is genuinely thoughtful — layered hallucination filters with clipboard recovery instead of silent discards, a precision-first confidence gate, WAV recovery on engine failure, and a well-reasoned language resolver — but the free path's entry and exit points are not first-class yet. A fresh install is pinned to Russian with no auto-detect in the UI, the "offline" model requires HuggingFace connectivity at every launch and isn't actually loaded until the first dictation, mid-recording device switches silently eat speech behind a lying pill, and all the carefully-written recovery messages are hidden in a popover nobody opens. Each fix is small and local (a config parameter, a default, one observer, one UI state), so the gap to Wispr/Superwhisper league is closable in one focused iteration.

- [ ] **[P1]** 🐛 Local model load requires HuggingFace network access even when the model is fully on disk — offline dictation dead
      `/Users/android/Code/MetaWhisp/Services/Transcription/WhisperKitEngine.swift:19`
      _As a free user who downloaded a Whisper model precisely so dictation works offline, I open my Mac on a plane (or with HuggingFace unreachable/blocked) and dictation is dead with 'No model loaded. Go to Settings to download one.' — even though the model IS downloaded._
      **Fix:** In WhisperKitEngine.loadModel, resolve the local folder first (ModelManagerService already knows the hub path: defaultHubPath/<variant>) and pass it as WhisperKitConfig(modelFolder:, download: false). Only fall back to the download path when the folder is missing. This makes launch fully offline-capable and removes the per-launch HF round-trip.
- [ ] **[P1]** 🐛 Fresh install pins transcription language to Russian and the Settings UI offers no Auto option
      `/Users/android/Code/MetaWhisp/Models/AppSettings.swift:9`
      _As a free user on a fresh install who speaks English (or any non-Russian language), I dictate and get garbage/mis-language output because the decoder is force-seeded with <|ru|>, and there is no way to pick auto-detect anywhere in the UI._
      **Fix:** Change the default to "auto", add an AUTO chip as the first option in the languages array in MainSettingsView, and add a language step (or auto default) to onboarding. The resolver and engine already fully support it — this is purely a default + one UI chip.
- [ ] **[P1]** 🐛 Audio device switch mid-recording (AirPods connect) silently kills capture while the pill keeps showing 'recording'
      `/Users/android/Code/MetaWhisp/Services/Audio/AudioRecordingService.swift:107`
      _As a free user dictating a long thought, my AirPods auto-connect mid-recording; the mic silently stops but the pill keeps showing recording, so everything I say after that moment is lost and the partial transcript pastes with no warning._
      **Fix:** Own-layer fix: on config change, either restart capture on the new device transparently (recreate engine + reinstall tap, preserving the samples buffer — best, Wispr-league behavior), or notify the coordinator (callback/Combine) to end the recording immediately, transcribe what was captured, and surface 'Input device changed — recording stopped' so the UI never lies.
- [ ] **[P2]** 🐛 Push-to-talk dead zone: hold between 0.15s and 0.3s starts recording but release never stops it — mic left hot
      `/Users/android/Code/MetaWhisp/Services/System/HotkeyService.swift:118`
      _As a free user in push-to-talk mode, I press Right ⌘ for ~0.2s and let go; recording starts but never stops — the mic stays hot and the pill stays up indefinitely until I figure out I must hold the key again for 0.3+ seconds._
      **Fix:** Make stop unconditional on whether start actually fired: track a 'pttStarted' flag set inside the delayed start closure; on key-up, if pttStarted → onPTTStop (regardless of held duration), else cancel the pending start work item. This removes the dead zone entirely instead of tuning thresholds.
- [ ] **[P2]** 🐛 "Model loaded successfully" is false — WhisperKit never loads the CoreML models at init, so the first dictation of every session pays the full model load and silently drops dictionary bias words
      `/Users/android/Code/MetaWhisp/Services/Transcription/WhisperKitEngine.swift:28`
      _As a free user with a downloaded model, my first dictation after launching the app hangs in 'processing' for many extra seconds (minutes after an OS update, when CoreML re-specializes large-v3-turbo) with no explanation — and my custom dictionary words don't bias that first transcription at all._
      **Fix:** Pass `load: true` (plus `prewarm: true` when RAM headroom allows) in WhisperKitConfig so loadModel genuinely loads before reporting readiness, and drive onboarding/settings 'loading…' UI off it via the existing progressHandler. This also makes isModelLoaded honest.
- [ ] **[P2]** 🐛 Stale previousApp: dictating while MetaWhisp's own window is focused auto-pastes the transcript into whatever app was targeted in a PREVIOUS dictation
      `/Users/android/Code/MetaWhisp/Services/System/TextInsertionService.swift:14`
      _As a free user, I dictated into Slack an hour ago, then open MetaWhisp's main window and hit the hotkey to dictate — my new transcript activates Slack and pastes there, leaking my dictation into the wrong app._
      **Fix:** In savePreviousApp, when frontmost is MetaWhisp explicitly set previousApp = nil (paste falls back to plain clipboard-only with the existing 'press ⌘V' hint instead of activating a stale app). For the race: before posting ⌘V, verify NSWorkspace.shared.frontmostApplication == previousApp (retry briefly, then degrade to clipboardOnly with the honest message).
- [ ] **[P2]** ✨ All dictation errors and clipboard-recovery hints are invisible unless the user opens the menu-bar popover — the pill has no error state
      `/Users/android/Code/MetaWhisp/Views/Components/RecordingOverlay.swift:70`
      _As a free user whose dictation got filtered as a hallucination ('text saved to clipboard, ⌘V to paste anyway') or whose transcription failed with audio saved to Recovery, I never see any of those recovery hints — the pill just fades out exactly like a success, so I think my speech vanished._
      **Fix:** Add an .error(String) presentation to the pill: on stage→idle with a fresh lastError, keep the panel up ~3s showing a compact one-line message ('Saved to clipboard — ⌘V', 'Transcription failed — audio saved'). Alternatively route these through the existing NotificationService. Small change, converts existing hidden honesty into visible honesty.
- [ ] **[P3]** ✨ No way to cancel a recording — every stop transcribes and auto-pastes, even accidental triggers
      `/Users/android/Code/MetaWhisp/Services/System/TranscriptionCoordinator.swift:139`
      _As a free user who triggered recording by accident (or changed my mind mid-sentence), I want to press Esc to discard the take — today my only option is to stop and watch the unwanted text transcribe and paste into my focused app._
      **Fix:** Add coordinator.cancelRecording() (recorder.stop() with samples discarded, stage→idle, distinct sound) wired to an Esc key monitor active only while stage == .recording, plus a click-to-cancel affordance on the pill. Optionally a soft max-duration (e.g. 10 min) that stops-and-transcribes with a notice.

## 4. Offline text processing (raw/clean/structured/translate)

**Вердикт:** Not first-class on the free path today. For the keyless fresh install (P-a), Raw works, but Clean — the only offline mode — is a Russian-only regex that no-ops for everyone else and can corrupt legitimate Russian sentences, while Structured and translate hard-fail into a menu-bar-only error. For the local-model user (P-b) the gap is worse because it is a broken promise: Settings advertises "structured text on-device for free", yet the structured dictation pipeline (TextProcessor) has no local branch at all — only conversation summaries run locally, and those are head-truncated to 2000 chars, parse-fragile on the 384-token cap, can strand conversations as permanent "Untitled", and never tell the user which engine ran. Closing the TextProcessor local branch and making Clean multilingual would move this from second-class to competitive with Wispr Flow/Superwhisper on the free tier.

- [ ] **[P1]** 🐛 Structured dictation and translate never route through the local MLX model, while Settings promises "structured text ... on-device for free"
      `Services/Processing/TextProcessor.swift:62`
      _As a free user who downloaded and activated a local model because Settings said AI features including structured text run on-device, I dictate in Structured mode and get raw text plus an 'API key not set' error._
      **Fix:** Add a local-first branch to TextProcessor.process() mirroring StructuredGenerator: if LocalLLMService.shared.isReady, route through LocalLLMService.shared.completeBlocking(system:user:) with the same detected-language-pinned system prompt (and same for translateOnly). If local structured cleanup is deliberately out of scope, change the AI Models copy at MainSettingsView.swift:1520 to stop listing 'structured text'.
- [ ] **[P2]** 🐛 StructuredGenerator failure paths strand conversations as permanent "Untitled" — backfill can never match nil titles
      `Services/Intelligence/StructuredGenerator.swift:351`
      _As a free user with a local model, my meeting shows 'Untitled' with no overview forever, and nothing retries it or tells me why._
      **Fix:** On parse failure and on catch, write the existing 'Quick note'/'(empty)' placeholder (leaving structuredBackfillAttempted unset) so the launch backfill picks the row up; replace the isRunning drop with queueing (LocalLLMService already serializes internally); optionally widen the backfill predicate to also match completed conversations with title == nil.
- [ ] **[P2]** 🐛 Clean mode — the only offline processing for keyless users — is Russian-only and silently no-ops on English speech
      `Helpers/TextAnalyzer.swift:8`
      _As an English-speaking free user with no API key, I select Clean ('Remove filler words (offline)') and every 'um, uh, like, you know' stays in my pasted text with no hint the feature only knows Russian fillers._
      **Fix:** Add an English filler set (um, uh, er, you know, I mean, kind of, sort of, basically) selected via NLLanguageRecognizer on the input text; return wasProcessed = (result != text); state language coverage in the mode description until parity exists.
- [ ] **[P2]** 🐛 Clean mode blanket regex deletes legitimate Russian words, corrupting meaning before paste
      `Helpers/TextAnalyzer.swift:67`
      _As a free user dictating in Russian with Clean mode, sentences where 'значит', 'допустим' or 'ладно' carry real meaning get silently mangled in the text that is pasted and saved to history._
      **Fix:** Restrict auto-removal to filler positions (word surrounded by commas, or at utterance start followed by a comma) and drop the high-collision words (значит, допустим, ладно, слушай) from the removal list — keep them in fillerWords() counting for stats only.
- [ ] **[P2]** ✨ Local-model conversation summaries silently built from only the first 2000 characters of the transcript
      `Services/Intelligence/StructuredGenerator.swift:857`
      _As a free user with a local model, my hour-long meeting recap, decisions and action items reflect only the opening minutes, and nothing tells me the rest was ignored._
      **Fix:** For transcripts over the cap, run a map-reduce pass on the local model (chunk → mini-summary → final structured merge), or at minimum persist a summaryTruncated flag on the Conversation and render a 'summary covers first N min' note in the recap and detail views.
- [ ] **[P3]** 🐛 Failed translations still stamped translatedTo and counted as translations in Statistics
      `Services/System/TranscriptionCoordinator.swift:428`
      _As a free keyless user, every failed Right-⌥ translation still shows up as a successful translation in my stats and history metadata._
      **Fix:** Track whether the processing call succeeded (e.g. a local var set inside the do-block) and only assign translatedTo when the translate branch actually completed.
- [ ] **[P3]** ✨ Selection-translate failure is an anonymous error beep — no reason, no pointer to Settings
      `Services/System/SelectionTranslator.swift:82`
      _As a fresh-install free user trying translate-selection with Right ⌥ long-press, I hear an error sound and nothing happens, with no clue that I need an API key._
      **Fix:** Surface the error where the user is looking: extend RecordingOverlayController with a brief failure state showing the localized error ('Add an API key in Settings → AI'), or route it into the coordinator's lastError so the menu bar shows the reason.
- [ ] **[P3]** ✨ No engine attribution anywhere — user cannot tell whether text was processed locally or in the cloud, and the routing indicator is disabled
      `Views/Windows/MainSettingsView.swift:1511`
      _As a free user who activated a local model for privacy, I can't tell whether a given cleanup or summary ran on-device or was sent to a cloud API with my key._
      **Fix:** Re-land the routing indicator with the simplified layout noted in the crash comment, and stamp an llmEngine string on HistoryItem/Conversation at processing time, rendered as a small badge (e.g. 'on-device · Phi-4' / 'OpenAI · your key') in Library rows and the recap header.

## 5. Local LLM runtime (MLX)

**Вердикт:** The local-LLM engine itself is real and surprisingly solid on the free path: Phi-4 Mini downloads with retry/resume/disk-preflight, loads with hard MLX memory bounds (512MB cache / 6GB ceiling + clearCache per generation — the 35GB incident is genuinely fixed), and actually powers the conversation-close pipeline (recap, memories, tasks, advice, meeting coach, screen reactor) with FIFO queueing. But the integration is dishonest and inconsistent: the app's single most-used AI feature — structured dictation cleanup — never touches the local model even though the Settings copy and the footer pip explicitly claim it does; the Apple Foundation Models card is fake-activatable on Tahoe; four sibling memory extractors arbitrarily exclude local; every local call is silently truncated to ~2000 chars; and the load lifecycle has no in-flight guard or user feedback. Verdict: a first-class engine wrapped in a second-class, occasionally lying integration — one honest iteration away from Wispr Flow / Superwhisper league, but not there today.

- [ ] **[P1]** 🐛 Structured dictation cleanup never uses the local model despite Settings copy and footer pip claiming it does
      `Services/Processing/TextProcessor.swift:62`
      _As a free user with an activated local model, I set processing mode to Structured expecting my dictations to be cleaned up on-device as Settings promised, but every dictation pastes raw._
      **Fix:** Add a local branch to TextProcessor.process(): if LocalLLMService.shared.isReady, route the structured-cleanup prompt through completeBlocking (the prompt at buildSystemPrompt is small; cap user text like other local callers and fall back to raw on failure). If local is deemed too weak for cleanup, remove 'structured text' from the Settings copy and stop counting structured mode as local in processingModeLabel — the pip and copy must match the code.
- [ ] **[P1]** 🐛 Apple Foundation Models card is fake-activatable on macOS 26 — ACTIVE badge with zero inference behind it
      `Views/Windows/MainSettingsView.swift:1764`
      _As a fresh free user on macOS Tahoe with no API key, I click 'Make active' on the 'Zero download, zero config' Apple Foundation Models card and believe AI features now work — but nothing ever generates._
      **Fix:** Until the ITER-044 adapter ships, render the Foundation Models card like the deferred MLX cards: disabled button labeled 'Coming soon' with a help tooltip, and refuse to persist localLLMActiveModelID for isFoundationModels specs. When the adapter lands, make 'Make active' go through the same loadModel/isReady lifecycle as MLX models.
- [ ] **[P2]** 🐛 Turning OFF 'Use local model for AI features' does not stop local routing or free the ~3 GB of RAM
      `Views/Windows/MainSettingsView.swift:1515`
      _As a free user unhappy with local output quality, I toggle off 'Use local model for AI features' and add my own API key — but the app keeps answering with the local model until I restart._
      **Fix:** Give the toggle an owner-layer side effect: on turn-off call LocalLLMService.shared.unloadModel() (isReady then gates all services correctly); on turn-on with a persisted ID, kick off loadModel. Optionally fold localLLMEnabled into a single shared 'localAvailable' gate so no service can bypass the setting.
- [ ] **[P2]** 🐛 No in-flight guard on loadModel and no loading feedback — 'Load now' stays clickable through the ~12 s load, double-click spawns concurrent multi-GB MLX builds
      `Services/LLM/LocalLLMService.swift:111`
      _As a free user activating my downloaded model, I click 'Load now', see nothing happen for 10+ seconds, click again — and my Mac grinds as two full weight loads run at once._
      **Fix:** Add @Published isLoading to LocalLLMService, guard loadModel with 'if isLoading or currentModelID == id && isReady, return', and have the card render a disabled 'Loading…' state (spinner + elapsed) while isLoading. Fix the stale auto-load comment.
- [ ] **[P2]** ✨ Notes/Calendar/Files/Screen memory extraction arbitrarily excludes the local model while the Memories screen tells the local user everything is unlocked
      `Services/Intelligence/ScreenExtractor.swift:527`
      _As a free user with a local model, I enable Apple Notes / Calendar / file indexing expecting memories to appear like they do from my dictations, but these sources silently never extract anything._
      **Fix:** Add the LocalLLMService.isReady clause plus a completeBlocking branch to all four extractors (mirroring MemoryExtractor's local branch — prompts and parsers are already compatible), or, where local is deliberately excluded, surface that in the source's Settings row ('Needs API key or Pro') instead of a silent guard-return.
- [ ] **[P2]** ✨ Every local call silently truncates user content to ~2000 chars — a 1-hour meeting's 'action plan' covers the first ~2 minutes with no notice
      `Services/LLM/LocalLLMService.swift:432`
      _As a free user, I generate an action plan for a long meeting on my local model and trust it as a summary of the whole meeting, when it actually saw only the opening minutes._
      **Fix:** For user-facing outputs (action plan, recap), either chunk long transcripts through the local model map-reduce style, or propagate a 'truncated: coveredChars/totalChars' flag from completeBlocking and render a one-line notice in the result UI ('Generated from the first N minutes — connect a key or Pro for full coverage').
- [ ] **[P3]** ✨ Settings copy sells 'chat' as an on-device local-model feature, but MetaChat deliberately excludes local
      `Views/Windows/MainSettingsView.swift:1520`
      _As a free user, I download a local model because Settings says chat runs on-device for free, then MetaChat still shows me the needs-API-key bar._
      **Fix:** Change the copy to list only what local actually powers today (memory, tasks, meeting coach, recaps, advice) and add 'chat requires an API key or Pro'; revisit if a local tool-call loop ever ships.
- [ ] **[P3]** ✨ Local generation is uncancellable — decode loop runs to maxTokens after the consumer is gone, delaying queued callers
      `Services/LLM/LocalLLMService.swift:370`
      _As a free user on a base M1, I want abandoned generations (cancelled caller, closed window, meeting reset) to stop burning my GPU and battery instead of blocking the next request._
      **Fix:** Set continuation.onTermination to flip a shared atomic cancel flag that runGenerationSync checks each decode iteration, and nil out pendingGeneration when the chain drains.

## 6. Second brain на фри (память/задачи/чат)

**Вердикт:** Not first-class yet — the free offline second brain is half-real, half-pretend. What genuinely works for a local-model user (P-b): memory/task extraction on conversation close, advice, and structured generation all route to the local model — but extraction silently collapses to zero output as data accumulates because the local prompt is capped at 2000 chars with dedup context ordered BEFORE the transcript, and every failure mode (JSON truncation, load failure, no-access queue) is invisible in the UI. What pretends: Settings explicitly sells local "chat", but MetaChat is hard-gated to API-key/Pro, and a free user's voice question hangs the popup in THINKING forever; for P-a (no key, no local) the red access bar is honest on the three main screens, but the empty-state copy still promises screen-activity extraction that is cloud-only.

- [ ] **[P1]** 🐛 Settings promises local-model "chat" but MetaChat deliberately excludes local models
      `Views/Windows/MainSettingsView.swift:1520`
      _As a free user, I downloaded a 2.3 GB local model because Settings said it runs chat on-device, so I expect MetaChat to answer offline._
      **Fix:** Either (a) ship a degraded local chat path — RAG userPrompt + LocalLLMService.completeBlocking with tools disabled and a one-line "local model: no actions, answers only" notice — or (b) fix the copy at line 1520 to "structured text, memory, tasks" and add an explicit "Chat requires an API key or Pro" line in the AI Models section.
- [ ] **[P1]** 🐛 Free user's voice question leaves the floating popup stuck in THINKING forever
      `Services/Intelligence/ChatService.swift:48`
      _As a free user, I long-press right ⌘ and ask a question aloud, so I expect an answer or a clear error — not a spinner that never resolves._
      **Fix:** In ChatService.send, on the hasLLMAccess guard (and the isSending/empty-text early returns) when source == .voice, call VoiceQuestionState.shared.failed("MetaChat needs an API key or Pro — Settings → AI") before returning.
- [ ] **[P1]** 🐛 Local extraction truncates the prompt to 2000 chars with dedup context first — transcript gets cut and extraction silently dies as memories/tasks accumulate
      `Services/Intelligence/MemoryExtractor.swift:132`
      _As a free user running everything on my local model, I expect memory/task extraction to keep working over time, not to silently stop once I have a few dozen memories._
      **Fix:** In the local branch, budget the prompt explicitly: reserve most of maxUserChars for the transcript (put fragments first or truncate the existing-items block, e.g. cap dedup context at 10 most-recent rows for local), and raise maxUserChars toward the model's real context (Phi-4-mini handles far more than 2000 chars) with the transcript tail preserved.
- [ ] **[P2]** 🐛 Truncated/garbage local-LLM JSON is treated as "nothing to extract" and the conversation is permanently dequeued
      `Services/Intelligence/MemoryExtractor.swift:444`
      _As a free local-model user, I expect a failed extraction attempt to be retried, not silently counted as "no memories in this conversation"._
      **Fix:** Return .retryLater on JSON parse failure (distinct from a parsed-but-empty result), with a small per-conversation attempt counter in ExtractionQueueStore to avoid a poison-item loop, and set/surface lastError so the failure is observable.
- [ ] **[P2]** 🐛 Free BYOK chat advertises search tools to the model but validate() rejects them as "Unknown tool"
      `Services/Intelligence/ChatToolExecutor.swift:178`
      _As a free user chatting with my own API key, I ask "remove the task about Mike" and expect the assistant to find and dismiss it, not to reply "Unknown tool: searchTasks"._
      **Fix:** In ChatService.send's non-Pro branch, when the parsed call isReadOnly, await executor.executeReadOnly() and run one follow-up LLM round with the result (mini text-loop), or at minimum strip the read-only tools section from the system prompt on the non-Pro path so the model never calls what the client can't run.
- [ ] **[P2]** 🐛 Startup backfill always no-ops for local-only users — it drains before the model finishes loading
      `App/AppDelegate.swift:684`
      _As a free local-model user, if the app quit before extracting my last meeting, I expect the extraction to happen on next launch — that is the queue's stated purpose._
      **Fix:** Trigger backfillPending after loadModel succeeds in the auto-load Task (or have LocalLLMService post a ready signal the extractors re-drain on), keeping the immediate backfill for key/Pro users.
- [ ] **[P2]** ✨ Access bar copy "Smart features are off" is wrong for local-model users on the MetaChat screen
      `Views/Components/LLMAccessBar.swift:16`
      _As a free user with an active local model, when MetaChat is gated I want to be told why my local model doesn't count — not that all smart features are off (they aren't)._
      **Fix:** Give LLMAccessBar a message parameter; ChatView passes chat-specific copy, e.g. "MetaChat needs an API key or Pro — your local model powers extraction, but chat requires a larger cloud model."
- [ ] **[P3]** ✨ Memories empty-state promises screen-activity extraction "every 10 minutes" — false on the entire free path
      `Views/Windows/MemoriesView.swift:179`
      _As a free user staring at an empty Memories screen, I want the copy to tell me what will actually populate it, so I don't wait for screen-based memories that can never arrive._
      **Fix:** Branch the copy on access state: for local-model users "Memories are extracted when a dictation or meeting conversation ends (10 min of silence closes it). Screen-based extraction needs an API key or Pro."; for no-access users defer to the access bar instead of promising automatic extraction.

## 7. Meeting recording + транскрибация созвонов

**Вердикт:** The core free-path mechanics are genuinely good — on-device dual-stream transcription with Me:/Them: pseudo-diarization, silence-boundary chunking, VAD trim, hallucination stripping, and honest partial-failure marking are Wispr/Superwhisper-league engineering, and a free user with a local MLX model even gets real summaries, tasks, and memories. But the feature is not first-class on robustness and feedback: the entire meeting lives only in RAM until one unguarded transcription pass (engine-not-ready, network failure, headset swap, or a quit during the invisible post-stop pass all destroy it), the silence/AFK guards compare mismatched units so auto-stop safety nets barely function, and the recap popup — the free user's payoff moment — shows an empty or stale card for exactly the free personas. Verdict: strong transcription core, second-class resilience and post-meeting experience; fixing audio persistence plus the recap timing/empty-state would move it most of the way to first-class.

- [ ] **[P1]** 🐛 Headset change mid-meeting silently kills mic capture AND discards all mic audio recorded before the change
      `Services/Audio/AudioRecordingService.swift:104`
      _As a free user recording a 60-min call on AirPods, I want my own voice to survive a headset battery death or device switch, so the transcript isn't reduced to only the other side with no warning._
      **Fix:** In MeetingRecorder, observe mic.$isRecording: on an unexpected false during an active meeting, (a) bank the already-captured samples (change AudioRecordingService to hand back samples on interruption or make stop() safe to call when not recording), (b) attempt mic restart after the config change settles (the observer already lazily re-inits on next start()), and (c) set micOnlyMode = true so the existing orange banner tells the user their voice is no longer captured.
- [ ] **[P1]** 🐛 Whole meeting is RAM-only and unrecoverable: engine-not-ready or full transcription failure at stop discards all audio with no retry
      `App/AppDelegate.swift:1373`
      _As a free user who just recorded an hour-long meeting, I want the recording to survive a failed transcription (model failed to load, BYOK network down, app quit), so one bad pass doesn't erase the meeting forever._
      **Fix:** Persist the raw PCM to a temp WAV in Application Support at stop (and ideally incrementally during capture), keyed by session id; delete only after historyService.save succeeds. On engine-not-ready or full-failure, keep the file and surface a 'Meeting saved as audio — retry transcription' card/action. Also pre-flight engine readiness at RECORD time so a P-a user without a loaded model is told before recording an hour of audio.
- [ ] **[P2]** 🐛 SystemAudioCaptureService.stop() nils the stream before the teardown Task runs — SCStream.stopCapture() is provably never called
      `Services/Audio/SystemAudioCaptureService.swift:108`
      _As a free user who presses STOP, I want screen/system-audio capture to actually terminate, so the macOS purple capture indicator turns off and capture doesn't linger on undocumented dealloc behavior._
      **Fix:** Capture the stream by value before clearing: `let s = stream; stream = nil; streamOutput = nil; Task { try? await s?.stopCapture() }` (or make stop() async and await stopCapture before clearing state).
- [ ] **[P2]** 🐛 Silence auto-stop and AFK sniff compare boosted UI level against raw-RMS-unit thresholds — auto-stop can never fire above near-digital silence
      `Services/Audio/MeetingRecorder.swift:74`
      _As a free user whose auto-started recording should stop a few minutes after the call ends, I want the silence guard to actually detect a normal quiet room, so I don't get 4-hour zombie recordings that then burn my CPU transcribing hours of room noise on-device._
      **Fix:** Publish a raw-RMS level alongside the boosted UI level (or invert the curve) and compare thresholds in one unit system; re-derive the silence threshold from the documented intent (raw RMS ≈ 0.01-0.025) and add a unit test that feeds synthetic room-tone RMS through the boost curve to pin the guard's firing behavior.
- [ ] **[P2]** 🐛 Calendar auto-start records ANY non-all-day event — solo/personal calendar entries with no call trigger mic + system recording
      `Services/Indexing/CalendarReaderService.swift:69`
      _As a free user with auto-start enabled, I want recording to begin only for actual calls, so my 'Focus time' or 'Dentist' calendar blocks don't start recording my room._
      **Fix:** For the calendar path require at least one of: ≥2 attendees, a conference/videocall URL on the event (EKEvent URL/notes/location matched against meet/zoom/teams/webex patterns), or a call window detected by detectCallContext within the last N seconds. Keep the ровно-в-два immediacy for events that pass the filter.
- [ ] **[P2]** ✨ Recap popup is an empty shell for no-LLM free users and permanently stale for local-model users (fixed 8s snapshot, no refresh)
      `App/AppDelegate.swift:1782`
      _As a free user finishing a meeting, I want the recap card to either show my summary when it's ready or tell me how to get summaries, so it doesn't pop up as a blank 'Meeting · 43 min' card that makes the feature look broken._
      **Fix:** Replace the fixed 8s with a bounded poll (e.g. check every 2s up to 60s for conv.title/overview to leave placeholder state, then present), or make the popup observe the Conversation and fill sections in live. For no-LLM users, render an explicit empty-state row in the card: 'Transcript saved. Add a local AI model or Pro to get summaries → Settings', plus a first-lines transcript preview (the payload already carries the transcript).
- [ ] **[P2]** ✨ Zero feedback during post-stop meeting transcription — strip flips to 'NO MEETING' while minutes of invisible work decide the meeting's fate
      `Views/MenuBar/MenuBarView.swift:145`
      _As a free user on on-device Whisper, I want to see that my hour-long meeting is being transcribed (and roughly how far along it is), so I don't assume it's done, quit the app, and lose the meeting._
      **Fix:** Add a published meetingTranscriptionInProgress (with chunk i/N progress from transcribeStreamChunked's existing loop) rendered as a 'TRANSCRIBING MEETING… 3/12' strip state, and register an app-termination guard (confirm dialog or delay-quit) while the pass is in flight.
- [ ] **[P3]** ✨ Long meetings hold ~0.5 GB/hour of Float32 PCM in RAM plus transient full copies at stop
      `Services/Audio/SystemAudioCaptureService.swift:44`
      _As a free user recording 2-hour calls on an 8 GB Mac, I want capture memory to stay modest, so the recorder doesn't balloon toward a gigabyte and pressure-swap my machine mid-meeting._
      **Fix:** Spill PCM incrementally to a temp WAV (which also fixes the P1 durability gap) or store Int16 (halves memory, Whisper input is converted anyway); replace the windowed-RMS Array slices with an index-based loop using withUnsafeBufferPointer; move sample accumulation off the MainActor onto the capture queue with a lock or actor.

## 8. Карта честности гейтинга

**Вердикт:** Not first-class yet: the gating core is honest (LicenseEntitlement TTL, SignInBannerDecision, 401/403-only sign-out, Text Style and Cloud-TTS gates with disabled controls + upsell copy, tier pill, onboarding readiness, LLMAccessBar on Tasks/Memories/Chat), but the free path is riddled with wrong signposting: default-on or freely-configurable toggles whose engines silently require Pro (Daily Summary, Proactive Chip, plus known Weekly Patterns/Dashboard GENERATE), local-model copy that over-promises (chat and structured dictation don't run locally; Apple Notes/Calendar/Files/Screen extractors exclude the local model), and 'Pro only' labels on features that actually work free (Realtime task detection, live-advice path). GATE MAP — (1) HONEST: Text Style (MainSettingsView:531-557 ↔ TextProcessor:84), Cloud Voice TTS (2150-2164 ↔ TTSService:79), Account/UPGRADE TO PRO (567-651), tier pill (MainWindowView:240-247), onboarding cloud path (OnboardingReadiness:28), LLMAccessBar gates matching TaskExtractor/MemoryExtractor incl. local, cloudFooter 'Raw/Clean work offline' (1171-1177), embeddings degrading silently to recency (no UI claim). (2) SILENT DEAD-END: Daily Summary settings toggle default-ON, Pro-guarded at DailySummaryService:162; Proactive Chip (ProactiveContextService:99 'quietly no-op'); Apple Notes/Calendar/File 'Scan now' with no feedback for P-a and P-b; voice question overlay stuck on thinking (ChatService:48); [known: Dashboard GENERATE, Weekly Patterns, Memories EXTRACT NOW, Library→Screen]. (3) MISCOMMUNICATED: AI MODELS copy claims chat + structured text + memory run on-device (1520) vs hasForChat/ChatService excluding local, TextProcessor having no local path, and ScreenExtractor/readers excluding local; 'Pro only' on Realtime task detection (1332) though it works BYOK/local; advice red key-hint shown to local-model users (2096); translation copy says 'OpenAI API key' though Cerebras key works; MainWindowView pip labels structured processing 'local' when it isn't (199-204). (4) LEAKY: live-advice non-Pro branch drives MeetingCoach/advice via local/BYOK despite 'Pro only' copy (LiveMeetingAdvisor:280-285 — user-favorable, known-adjacent); real infra leaks (gate fail-open, uncapped transcripts) already tracked.

- [ ] **[P1]** 🐛 Voice question (Right ⌘) hangs on 'thinking' forever for free users without LLM access
      `Services/Intelligence/ChatService.swift:48`
      _As a free user with only an on-device Whisper model, I hold Right ⌘ and ask a question, and the floating window spins on 'thinking' forever with no error and no hint of what to fix._
      **Fix:** In both early-return paths of ChatService.send, when source == .voice call VoiceQuestionState.shared.failed("Smart features need an API key or Pro — Settings → General"), mirroring the catch block at line 271-273. Optionally short-circuit in startVoiceQuestion() with the same message so the user never records a question that cannot be answered.
- [ ] **[P1]** 🐛 AI MODELS copy promises 'chat' runs on the local model, but MetaChat is hard-gated to cloud key / Pro
      `Views/Windows/MainSettingsView.swift:1520`
      _As a free user, I download a 2-4 GB MLX model because Settings says it runs 'AI features (structured text, memory, tasks, chat) on-device for free', then open MetaChat and get a red 'Smart features are off — add an API key or Pro' bar._
      **Fix:** Fix the copy at the source: remove 'chat' from the on-device feature list (or say 'chat still needs an API key or Pro — local models can't drive tools'), and make ChatView's LLMAccessBar variant for the local-model-active case say why chat specifically is excluded instead of the generic 'Smart features are off'.
- [ ] **[P1]** 🐛 Daily Summary toggle is ON by default and promises nightly recaps, but generation silently skips everyone who isn't Pro — including BYOK users
      `Views/Windows/MainSettingsView.swift:2003`
      _As a free user (even one paying for my own OpenAI key), I see 'Daily Summary' enabled with a schedule picker promising a nightly recap notification, and nothing ever arrives — no error, no Pro hint, ever._
      **Fix:** Owner-layer fix in the settings section: when !license.isPro, show a 'Pro required — daily recaps are generated in the cloud' hint under the toggle (same pattern as Cloud Voice at line 2162-2164) and disable the schedule picker; alternatively make generation work for BYOK since hasLLMAccess already admits it and all agents take a system+user prompt.
- [ ] **[P2]** 🐛 Proactive Chip section is fully configurable for free users but the service quietly no-ops without a license key
      `Services/Intelligence/ProactiveContextService.swift:99`
      _As a free user, I enable Proactive Chip, tune the cooldown slider and fill in a privacy blacklist, and no chip ever surfaces — the UI never tells me the feature is Pro-only._
      **Fix:** Add the same non-Pro hintRow used elsewhere ('Pro required — proactive insights run through the Pro proxy') directly under the Proactive Chip toggle, and disable the sub-controls when !license.isPro so configuration effort isn't wasted.
- [ ] **[P2]** 🐛 Dictation 'Structured' mode never uses the local model — sidebar pip claims 'on-device+local' while every structured dictation errors (P-b) or bills the user's cloud key (BYOK+local)
      `Services/Processing/TextProcessor.swift:58`
      _As a free user with an active local MLX model and Structured mode on, every dictation shows a post-processing error and pastes raw text, while the sidebar pip proudly says 'on-device+local'._
      **Fix:** Add the same local-first branch to TextProcessor.process and translateOnly (`if LocalLLMService.shared.isReady { LocalLLMService.shared.completeBlocking(...) }`) that StructuredGenerator/AdviceService/MeetingCoach already use, keeping the cloud paths as fallback. That single owner-layer change also makes the MainWindowView pip truthful.
- [ ] **[P2]** 🐛 Integration readers (Apple Notes, Calendar, File Indexing) exclude the local model from their access gate and their 'Scan now' buttons give zero feedback when gated
      `Services/Indexing/AppleNotesReaderService.swift:54`
      _As a free user with a local model active, I enable Apple Notes / Calendar / File Indexing and click 'Scan now', and literally nothing happens — no spinner, no result, no explanation._
      **Fix:** Align the gates: add `|| LocalLLMService.shared.isReady` plus a local call branch to the three readers and ScreenExtractor (copy the MemoryExtractor pattern), and give scanNowButton a running/result state fed from the services' existing isRunning/lastSummary/lastError publishers so a gated click at least says why nothing ran.
- [ ] **[P3]** ✨ 'Pro only' label on Realtime task detection is false — the feature works with BYOK and local models
      `Views/Windows/MainSettingsView.swift:1332`
      _As a free user with my own API key or a local model, I skip enabling Realtime task detection because Settings says 'Pro only', losing a feature that actually works for me._
      **Fix:** Change the Realtime task detection copy to 'Needs Pro, an API key, or a local model', and gate the advice API-key hint on `!LocalLLMService.shared.isReady` so it only warns users who genuinely have no path.
- [ ] **[P3]** ✨ The one honest 'where is my AI running' indicator exists but is commented out, leaving no global INACTIVE signal
      `Views/Windows/MainSettingsView.swift:1511`
      _As a fresh-install free user, I want one always-visible line telling me 'INACTIVE — no API key, no Pro, no local model — AI features silently disabled', so I don't discover each dead feature one by one._
      **Fix:** Reintroduce the indicator with a crash-safe layout (single Text with no infinity-frame-in-overlay nesting, or move it to the Dashboard header), since the resolver is already separated from the view; this is the cheapest single fix for gating honesty across both personas.


# ═══════════════ ПЛАН РЕАЛИЗАЦИИ ═══════════════

> Правила: батч = итерация. Внутри батча — по пункту за проход (TDD где есть
> seam: red → green → refactor), атомарный коммит на пункт. Конец батча: билд +
> все тесты + многоагентное ревью диффа + хот-свап + ручной прогон юзера по DoD.
> Следующий батч не начинаем, пока текущий не закрыт.

## Общий Definition of Done (каждый батч)
- [ ] Все user stories пункта закрыты по своим критериям приёмки.
- [ ] `swift build` + `swift test` зелёные; новые тесты на каждый пункт с seam'ом.
- [ ] Ревью диффа (multi-agent) — 0 неисправленных подтверждённых P1/P2.
- [ ] Хот-свап; юзер прогнал ручные DoD-проверки батча.
- [ ] Копия/лейблы в UI не обещают того, чего код не делает (проверка грепом
      по изменённым фичам).
- [ ] PROGRESS в этой спеке обновлён.

═══════════════════════════════════════════════════════════════════

## F1 — «Локальная модель работает по-настоящему» (~14 находок)

**Цель:** всё, что Settings обещает про on-device AI, реально исполняется
локальной моделью; что не исполняется — честно помечено.

### F1.1 LLM-роутер: local-first в TextProcessor (structured + translate)
**US:** Как фри-юзер с активной локальной моделью, я диктую в Structured-режиме
и получаю очищенный текст без ключа и интернета. / Как тот же юзер, я жму
Right ⌥ и получаю ПЕРЕВОД, а не свои же слова.
- [ ] `TextProcessor.process()`: ветка `if LocalLLMService.shared.isReady` →
      `completeBlocking(system:user:)` с тем же language-pinned промптом
      (`TextProcessor.swift:62`); cloud-путь = fallback.
- [ ] То же для `translateOnly`.
- [ ] Тест: с mock-локальным исполнителем structured/translate не ходят в сеть.
**Corner cases:** модель выгрузилась между isReady-проверкой и вызовом (→ catch
→ прежнее поведение, без крэша); пустой ответ модели (→ fallback на raw + ошибка,
не пустая вставка); очень длинный ввод (→ F1.2 бюджет); RU/EN code-switching
сохраняется (есть тест-набор ITER-фиксов — прогнать на локальном пути).
**DoD:** выключить Wi-Fi, локальная модель активна → Structured-диктовка даёт
чистый текст; Right ⌥ переводит. Футер-пип «on-device» теперь правдив.

### F1.2 Бюджет контекста вместо 2000-char обрезки
**US:** Как фри-юзер, после часового созвона я получаю recap/план по ВСЕМУ
митингу, а не по первым 2 минутам — или хотя бы честную пометку об охвате.
- [ ] `MemoryExtractor` local branch (`:132`): транскрипт-first бюджетирование
      (dedup-контекст ≤10 последних строк), `maxUserChars` → реальный контекст
      модели.
- [ ] `LocalLLMService.completeBlocking` (`:432`): флаг
      `truncated(covered/total)` наружу.
- [ ] Recap/action-plan длинных транскриптов: map-reduce чанкинг через локальную
      модель (`StructuredGenerator.swift:857`) ИЛИ (минимум) notice «Summary
      covers first N min» в recap и detail.
**Corner cases:** транскрипт меньше лимита (ноль изменений); модель с крошечным
контекстом (бюджет от модели, не константой); чанк-фейл посреди map-reduce
(частичный результат + пометка, не потеря всего).
**DoD:** митинг >30 мин на локалке → задачи из КОНЦА разговора попадают в
экстракцию; UI нигде молча не покрывает «первые 2 минуты».

### F1.3 Интеграционные ридеры получают локальную ветку
**US:** Как фри-юзер с локальной моделью, «Scan now» в Apple Notes / Calendar /
Files / Screen реально извлекает память, как обещает экран Memories.
- [ ] `AppleNotesReaderService:54`, CalendarReader, FileIndexing,
      `ScreenExtractor:527`: `|| LocalLLMService.shared.isReady` в гейт +
      local branch по образцу MemoryExtractor.
- [ ] «Scan now»: running/result state из существующих publisher'ов —
      гейтнутый клик объясняет, почему ничего не произошло.
**Corner cases:** модель занята очередью (скан ждёт, не молчит); ридер без
разрешений ОС (ошибка про разрешение, не про модель).
**DoD:** локалка активна, ключей нет → Scan now в Notes даёт memories; кнопка
никогда не «ничего не сделала».

### F1.4 Честный тумблер + загрузка без гонок
**US:** Как юзер, выключив «Use local model», я освобождаю ~3 ГБ RAM; включив —
вижу прогресс загрузки и не могу запустить её дважды.
- [ ] Тумблер (`MainSettingsView:1515`): OFF → `unloadModel()`; ON c persisted
      ID → `loadModel`.
- [ ] `LocalLLMService:111`: `@Published isLoading`, guard от повторного
      вызова; карточка — disabled «Loading…» + elapsed.
**Corner cases:** OFF во время генерации (докончить/отменить текущую, потом
выгрузить — без крэша); двойной клик по «Load now» (второй = no-op); OFF→ON
быстро подряд.
**DoD:** Activity Monitor показывает освобождение RAM после OFF; двойной клик
не спавнит вторую загрузку.

### F1.5 MetaChat и локалка — выбрать и сделать честно
**Решение за тобой (пункт-развилка):**
(a) деградированный локальный чат — RAG-контекст + `completeBlocking`, tools
отключены, плашка «local model: answers only, no actions»; или
(b) копия правится: из AI MODELS убирается «chat», LLMAccessBar на экране чата
объясняет «chat needs an API key or Pro».
- [ ] Реализовано (a) ИЛИ (b) везде согласованно (`MainSettingsView:1520`,
      `LLMAccessBar:16`, ChatView).
**Corner cases (для a):** вопрос, требующий tools («заверши задачу X») → ответ
объясняет ограничение, а не молчит/галлюцинирует действие.
**DoD:** ни одна строка UI не обещает локальный чат, если его нет; либо чат
работает оффлайн в объявленных рамках.

### F1.6 Apple Foundation Models — не фейк
**US:** Как юзер macOS 26, я не могу «активировать» карточку, за которой нет
инференса.
- [ ] `MainSettingsView:1764`: карточка → disabled «Coming soon» (как deferred
      MLX), persisted ID для FM-спеков не пишется. (Реальный адаптер = ITER-044.)
**DoD:** активировать нельзя; существующий фейково-активный ID мигрирует в
неактивный без крэша (corner case: у юзера уже сохранён FM id).

### F1.7 Кривой JSON от локалки ≠ «нечего извлекать»
**US:** Как фри-юзер, обрезанный/битый ответ модели не выкидывает мой разговор
из очереди экстракции навсегда.
- [ ] `MemoryExtractor:444`: parse-fail → `.retryLater` + attempt-counter в
      `ExtractionQueueStore` (анти-poison, например ≤3 попыток) + `lastError`.
- [ ] Тест: битый JSON → элемент остаётся в очереди с attempts+1; после
      max-attempts — дисквалификация С ошибкой в lastError.
**Corner cases:** валидный-но-пустой JSON (это честное «nothing» — dequeue);
поочерёдные успех/фейл.
**DoD:** искусственно битый ответ не теряет разговор.

### F1.8 Backfill стартует после готовности модели
**US:** Как local-only юзер, накопившаяся очередь экстракции дренится после
запуска, а не no-op'ится, пока модель грузится.
- [ ] `AppDelegate:684`: backfill после успешного `loadModel` (ready-signal),
      немедленный путь для key/Pro сохранён.
**Corner cases:** модель не загрузилась вовсе (очередь ждёт следующего запуска,
не теряется); Pro-юзер (поведение без изменений).
**DoD:** рестарт с непустой очередью на локалке → лог дренажа ПОСЛЕ load.

### F1.9 Отменяемая локальная генерация
- [ ] `LocalLLMService:370`: `continuation.onTermination` → atomic cancel-flag,
      decode-цикл проверяет каждый шаг; `pendingGeneration` чистится.
**DoD:** закрытие потребителя не жжёт CPU до maxTokens; очередь не копится.

═══════════════════════════════════════════════════════════════════

## F2 — «Ничего не падает молча» (~11)

**Цель:** каждый сбой виден там, куда юзер смотрит; никакой фейковой успешности.

### F2.1 Voice question: fail-fast вместо вечного THINKING
**US:** Как фри-юзер без доступа к LLM, задав голосовой вопрос, я вижу «нужен
ключ или Pro» через секунду, а не вечный THINKING.
- [ ] `ChatService.send` (`:48`): оба early-return при `source == .voice` →
      `VoiceQuestionState.shared.failed("MetaChat needs an API key or Pro — Settings → AI")`.
- [ ] Short-circuit в `startVoiceQuestion()` — не записывать вопрос, на который
      нечем ответить.
- [ ] Тест на маппинг early-return → failed-state.
**Corner cases:** isSending-гонка (второй вопрос при живом первом); пустой
транскрипт вопроса.
**DoD:** без ключей Right ⌘ → мгновенная честная ошибка в пилюле.

### F2.2 Пилюля умеет показывать ошибку
**US:** Как юзер, при сбое диктовки я вижу причину на пилюле, не раскапывая
меню-бар.
- [ ] `RecordingOverlay:70`: состояние `.error(String)` — stage→idle со свежим
      lastError держит панель ~3с («Saved to clipboard — ⌘V» / «Transcription
      failed»).
**Corner cases:** ошибка во время следующей записи (не перекрывать активную
запись); длинный текст ошибки (обрезка в одну строку).
**DoD:** выдернуть модель/сломать движок → пилюля объясняет, что случилось.

### F2.3 Онбординг: загрузка модели видима, фейл ретраится
**US:** Как новичок после 950 МБ закачки, я вижу «Loading model — first time
can take a few minutes…», а при фейле — RETRY, а не вечно disabled NEXT.
- [ ] `.loading`-состояние + `coordinator.lastError` в auto-load sink
      (`AppDelegate:481`); `OnboardingModelPage` рендерит loading + failure row
      с RETRY (перезагрузка, не перезакачка).
**Corner cases:** whisperEngine ещё nil (mic-permission гонка) → sink не
молчит, а откладывает/повторяет; повторный RETRY.
**DoD:** искусственно битая модель → видимый фейл + работающий RETRY.

### F2.4 Try-it страница: провал попытки виден
- [ ] `OnboardingTryItPage:204`: `.idle` в phase 1/2 без результата → phase 0 +
      «Didn't catch that — tap Right ⌘ and try again» (+lastError, если есть).
**Corner cases:** мгновенный double-tap (short-discard); тишина в микрофон.
**DoD:** двойной тап Right ⌘ на try-it → понятная подсказка, не фейковый
«recording».

### F2.5 Translate никогда не вставляет исходник молча
**US:** Как фри-юзер без ключей, Right ⌥ либо переводит (локалка — F1.1), либо
говорит, чего не хватает — но не притворяется.
- [ ] `TranscriptionCoordinator:397-400`: noAPIKey при translate → НЕ вставлять
      исходник как перевод; ошибка через пилюлю (F2.2).
- [ ] Онбординг (`OnboardingDonePage:141` + features page): бейдж «Pro / API
      key / local model» на translate/rewrite при отсутствии доступа.
- [ ] `translatedTo` ставится только при успехе (`TranscriptionCoordinator:428`)
      — статистика переводов не врёт.
**DoD:** без доступа Right ⌥ даёт видимую причину; Statistics не растит счётчик.

### F2.6 Permissions-страница: ALLOW всегда что-то делает
- [ ] `OnboardingPermissionsPage:87`: branch по authorizationStatus —
      `.notDetermined` → prompt; `.denied/.restricted` → открыть системную
      панель Privacy.
- [ ] Убрать contextless-промпты из запуска при `!hasCompletedOnboarding`
      (онбординг владеет первым промптом); подключить `allGranted` в
      `nextBlocked` с «or skip» (как на стр. 2).
**Corner cases:** юзер вернулся из System Settings (пере-чек статуса на
активации окна); отказ повторно.
**DoD:** ALLOW после «Don't Allow» ведёт в правильную панель настроек.

### F2.7 Selection-translate объясняет провал
- [ ] `SelectionTranslator:82`: ошибка → краткое состояние оверлея / lastError
      («Add an API key in Settings → AI»), не анонимный бип.

### F2.8 Атрибуция движка
**US:** Как юзер, я вижу, ЧТО обработало мой текст (on-device Phi-4 / OpenAI
my-key / Pro cloud).
- [ ] Штамп `llmEngine` на HistoryItem/Conversation в момент обработки; бейдж в
      Library и recap-хедере.
- [ ] Re-land routing-индикатора (`MainSettingsView:1511`) crash-safe layout'ом
      (single Text, без infinity-frame в overlay — причина прошлого крэша задокументирована).
**DoD:** для каждой записи истории можно сказать, где она обработана.

### F2.9 StructuredGenerator: не плодить вечные Untitled
- [ ] `StructuredGenerator:351`: parse-fail/catch → placeholder «Quick note»
      без `structuredBackfillAttempted`, чтобы backfill подобрал; isRunning-drop
      → очередь; backfill-предикат добирает `title == nil`.
**Corner cases:** двойной запуск генерации на одном id; conversation удалён к
моменту записи.
**DoD:** искусственный фейл → разговор получает тайтл при следующем backfill.

═══════════════════════════════════════════════════════════════════

## F3 — Model management честный (~7)

### F3.1 «Скачано» = проверенно скачано
**US:** Как юзер с оборванной закачкой, я вижу кнопку DOWNLOAD, а не ✓ у
мёртвой модели. / Large V3 не отображается скачанной, когда на диске Turbo.
- [ ] `ModelManagerService:139-141`: exact match варианта (`$0 == info.variant`)
      + проверка полноты (required file set: config.json, tokenizer,
      AudioEncoder/TextDecoder/MelSpectrogram .mlmodelc) или `.complete`-маркер
      после успешной закачки.
- [ ] Regression-тесты: turbo-on-disk → `isDownloaded("large-v3") == false`;
      неполная папка → false.
**Corner cases:** старые юзеры с уже-скачанными моделями без маркера (fallback
на file-set проверку — не заставлять перекачивать!); модель, скачанная внешним
инструментом.
**DoD:** kill -9 посреди закачки → после рестарта модель предлагает DOWNLOAD.

### F3.2 Упавшая закачка → RETRY
- [ ] `MainSettingsView:348`: progress-ветка гейтится `phase != .failed`;
      failed → кнопка RETRY (`startDownload`); `currentDownloadModel` резетится
      на старте.
**DoD:** обрыв сети во время закачки → RETRY виден и работает.

### F3.3 ACTIVE = загружена
**US:** Как юзер, переключив модель, я вижу LOADING… → ACTIVE, а при фейле —
FAILED + RETRY; история атрибутирует реальную модель.
- [ ] Row-state от `coordinator.loadedWhisperModelId`; лечим оба молчаливых
      catch в AppDelegate (lastError); history пишет loaded, не selected.
**Corner cases:** переключение во время загрузки предыдущей; фейл загрузки при
уже работающей старой (старая продолжает работать — состояние это отражает).
**DoD:** переключение модели видно пошагово; сорванный свитч не показывает
ACTIVE.

### F3.4 Честная загрузка + warm-up прогресс
- [ ] `WhisperKitEngine:28`: `load: true` (+`prewarm` при RAM-headroom) —
      «Model loaded» значит загружена; `progressHandler` → published state →
      онбординг/Settings «Loading model — first load can take a minute…»;
      ошибка «ещё грузится» ≠ «ничего не скачано».
**Corner cases:** первый лоад после обновления ОС (ANE-специализация долгая);
одновременный запрос диктовки во время лоада.
**DoD:** первая диктовка сессии не «зависает» необъяснимо.

### F3.5 Удаление моделей + размер на диске
- [ ] `deleteModel(id:)` (unload если активна; removeItem в обеих scan-локациях;
      refresh) + trash-действие на скачанных неактивных рядах + реальный размер
      папки.
**Corner cases:** удаление активной (сначала unload + предупреждение); удаление
во время закачки другой.

### F3.6 Disk-space preflight + человеческие ошибки
- [ ] `volumeAvailableCapacityForImportantUsage` vs bytes модели ДО закачки →
      «Not enough disk space (need ~1 GB, have X)»; catch маппит
      notConnectedToInternet/timedOut/ENOSPC в короткие фразы (raw — в os_log).

### F3.7 Рекомендация по железу
- [ ] RECOMMENDED от `physicalMemory` (Turbo ≥16GB / Small 8GB), Small-карточка
      в онбординге; фейковый «VERIFYING» → «FINISHING…» или реальная проверка.

═══════════════════════════════════════════════════════════════════

## F4 — Диктовка первоклассно (~7)

### F4.1 真 оффлайн: грузим модель с диска
**US:** Как юзер в самолёте со скачанной моделью, диктовка работает.
- [ ] `WhisperKitEngine:19`: `WhisperKitConfig(modelFolder: <hub path>/variant,
      download: false)` когда папка есть; download-путь — только fallback.
- [ ] Тест/проверка: launch без сети со скачанной моделью → лоад ок.
**Corner cases:** папка есть, но битая (F3.1 полнота решает — иначе честный
фейл + RETRY, не тихий download-заход).
**DoD:** Wi-Fi off → рестарт → диктовка работает.

### F4.2 Язык: auto по умолчанию
**US:** Как англоязычный новичок, я не получаю русскую транскрипцию из коробки.
- [ ] `AppSettings:9`: default `"auto"`; AUTO-чип первым в списке языков
      Settings; язык-шаг (или auto-умолчание) в онбординге.
**Corner cases:** существующие юзеры с явно выбранным ru (НЕ трогаем их
настройку — только default для новых); mixed RU/EN (авто-детект per-utterance —
прогнать существующие code-switch тесты).
**DoD:** свежий профиль → английская речь транскрибируется английским.

### F4.3 Смена аудио-устройства не убивает запись молча
**US:** Как юзер, чьи AirPods подключились посреди диктовки, я не теряю хвост
записи при «recording» на пилюле.
- [ ] `AudioRecordingService:107`: на config-change — рестарт захвата на новом
      устройстве с сохранением буфера (цель), либо немедленный честный стоп:
      транскрибировать захваченное + «Input device changed — recording stopped».
**Corner cases:** устройство исчезло вовсе (Bluetooth обрыв); смена
туда-обратно за секунду; смена во время митинга (см. F5.2 — общий механизм).
**DoD:** подключение AirPods в диктовке → либо бесшовно, либо честный стоп с
текстом; пилюля не врёт.

### F4.4 PTT: убрать мёртвую зону 0.15–0.3s
- [ ] `HotkeyService:118`: флаг `pttStarted` внутри delayed-start; key-up:
      started → stop (всегда), не started → cancel pending.
- [ ] Тест на тайминги (структура позволяет — чистая логика при
      инжектированных временах).
**DoD:** удержание любой длительности никогда не оставляет горячий микрофон.

### F4.5 Авто-паста не стреляет в чужое окно
- [ ] `TextInsertionService:14`: frontmost == MetaWhisp → `previousApp = nil`
      (clipboard-only + «press ⌘V»); перед ⌘V — verify frontmost == previousApp
      (retry кратко → degrade в clipboardOnly).
**Corner cases:** previousApp закрылся за время транскрипции; Spotlight/полноэкранный
переключатель в момент вставки.
**DoD:** диктовка из окна MetaWhisp не вставляет текст в прошлое приложение.

### F4.6 Отмена записи
**US:** Как юзер, случайно начав запись, я отменяю её Esc'ом — без транскрипции
и вставки.
- [ ] `coordinator.cancelRecording()` (discard, stage→idle, отдельный звук);
      Esc-монитор активен только при `stage == .recording`; click-to-cancel на
      пилюле; мягкий max-duration (10 мин) со стоп-и-транскрибировать + notice.
**Corner cases:** Esc-конфликт с voice-question монитором (F2.1/B2.4 — один
владелец Esc за раз); отмена в момент естественного стопа.
**DoD:** Esc в записи «съедает» её бесследно.

### F4.7 Онбординг-полировка (perm-gate, параллельная закачка, reopen)
- [ ] NEXT на модельной странице не блокируется на весь download (живой статус
      в нижней панели; финальный гейт остаётся); `allGranted` подключён;
      `applicationShouldHandleReopen` → onboarding при `!hasCompletedOnboarding`.
**DoD:** закрыл окно онбординга → клик по Dock/иконке возвращает онбординг.

═══════════════════════════════════════════════════════════════════

## F5 — Митинги: не терять часовой созвон (~7)

### F5.1 Durability: аудио переживает всё
**US:** Как юзер после часового созвона, при любом сбое транскрипции я не теряю
запись — есть «Meeting saved as audio — retry transcription».
- [ ] Инкрементальный spill PCM → temp WAV (Application Support, session id) —
      заодно решает ~0.5 ГБ/час RAM; удалять только после успешного
      `historyService.save`.
- [ ] Engine-not-ready/полный фейл на стопе (`AppDelegate:1373`) → файл
      остаётся + карточка retry.
- [ ] Preflight готовности движка на RECORD (P-a без модели узнаёт ДО записи).
**Corner cases:** диск кончился во время spill (fallback в RAM + предупреждение);
крэш аппки посреди митинга (orphan-файл подхватывается при старте — recovery
уже есть для других артефактов, паттерн повторить); два митинга подряд.
**DoD:** kill движка перед стопом → аудио-файл + retry-карточка вместо потери.

### F5.2 Смена гарнитуры посреди митинга
- [ ] `MeetingRecorder` наблюдает `mic.$isRecording`: неожиданный false →
      забанкать собранные сэмплы, попытка рестарта мика, при неудаче —
      честный `micOnlyMode` + notice. (Общий механизм с F4.3.)
**DoD:** AirPods подключились в митинге → мой голос не исчезает молча.

### F5.3 stopCapture реально вызывается
- [ ] `SystemAudioCaptureService:108`: `let s = stream; stream = nil; Task {
      try? await s?.stopCapture() }` — teardown не по nil'у.
- [ ] Тест-скелет: stop() → мок-стрим получил stopCapture.
**DoD:** после стопа SCK-стрим не живёт (нет фантомного индикатора записи).

### F5.4 Авто-стоп по тишине — в одних единицах
- [ ] `MeetingRecorder:74`: raw-RMS канал рядом с boosted-UI уровнем; пороги в
      одной системе; unit-тест с синтетическим room-tone пиннит поведение.
**Corner cases:** ручной режим (guards отключены — не регрессировать); тихий
спикер ≠ тишина.
**DoD:** искусственная тишина 15 мин → авто-стоп срабатывает.

### F5.5 Календарь не пишет одиночные события
- [ ] `CalendarReaderService:69`: авто-старт только при (≥2 участников) ∨
      (conference/videocall URL в event) ∨ (detectCallContext рядом).
**Corner cases:** событие «фокус-блок» с зумом в заметках (URL-матч решает);
рекуррентные события (учесть B1.4 из ITER-050 — правильная occurrence).
**DoD:** личное «сходить в зал» в календаре не включает запись.

### F5.6 Recap живой и честный для фри
- [ ] Вместо fixed 8s (`AppDelegate:1782`): bounded poll (2s × до 60s) или
      live-observe Conversation; для no-LLM: «Transcript saved. Add a local AI
      model or Pro for summaries → Settings» + первые строки транскрипта.
**DoD:** локалка (медленная) → recap заполняется, когда готов; без LLM — попап
не пустой.

### F5.7 «TRANSCRIBING MEETING… 3/12»
- [ ] Published progress из `transcribeStreamChunked` → строка в меню-баре;
      termination-guard (confirm/delay quit) пока идёт транскрипция.
**DoD:** после стопа митинга видно, что работа идёт; Quit предупреждает.

═══════════════════════════════════════════════════════════════════

## F6 — Карта честности гейтинга (~5, добить остатки)

### F6.1 Daily Summary не обещает того, чего не делает
- [ ] `MainSettingsView:2003`: при `!isPro` — hint «Pro required…» под тумблером
      + disabled schedule picker; ЛИБО открыть BYOK-путь (hasLLMAccess уже
      допускает — решение за тобой).
**DoD:** фри-юзер понимает статус фичи с одного взгляда.

### F6.2 Proactive Chip: не собирать мёртвый конфиг
- [ ] hint + disable суб-контролов при `!isPro` (`ProactiveContextService:99`).

### F6.3 Realtime task detection: копия по правде
- [ ] «Needs Pro, an API key, or a local model» (`MainSettingsView:1332`);
      advice-hint гейтится `!LocalLLMService.isReady`.

### F6.4 Финальный грep-аудит копии
- [ ] По всем изменённым фичам: грep «Pro only|on-device|local» ↔ фактические
      гейты; расхождений 0. (Автоматизировать тестом-стражем не пытаемся —
      слишком текстово; ручной чек-пункт в DoD.)

═══════════════════════════════════════════════════════════════════

## Master checklist
- [ ] **F1** — локальная модель по-настоящему (9 пунктов)
- [ ] **F2** — ничего не падает молча (9)
- [ ] **F3** — model management (7)
- [ ] **F4** — диктовка (7)
- [ ] **F5** — митинги (7)
- [ ] **F6** — гейтинг (4)

Открытые решения юзера ДО старта F1:
1. **F1.5** — локальный MetaChat: вариант (a) деградированный чат или (b) честная копия?
2. **F6.1** — Daily Summary: открыть BYOK-путь или Pro-hint?

## PROGRESS
- 2026-07-06: ревью завершено (49 агентов), полный план с US/чек-листами/DoD/corner
  cases написан. Реализация не начата. Ожидает: выбор юзера по 2 развилкам + добро
  на F1.

> **ДЕТАЛЬНЫЙ EXECUTION-ПЛАН** (чек-листы, DoD, corner cases, user stories по
> каждому пункту) — в `ITER-051-execution-plan.md`. Этот файл остаётся
> реестром находок-доказательств.

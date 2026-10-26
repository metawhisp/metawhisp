# ITER-075 Step 0 — code check (2026-09-25)

Read-only check of the current code, the app log and the keychain, made for the plan's Step 0. The
orchestrator re-checked some facts: the five Pro keychain items are absent (`security
find-generic-password`, attributes only), and the running app is Developer ID signed. Line numbers
are for commit 7d5748b. Logs are `~/Library/Logs/MetaWhisp.log` and `MetaWhisp.log.1`.

## 1. Current behaviour
- F1. `hot-swap.sh` runs in this order:
  - It looks up the Developer ID identity by team (:29-41). This only lists identities; the key is
    first used at :81.
  - It runs `pkill -x MetaWhisp` by process name, with no busy check (:44-46).
  - It edits `~/Applications/MetaWhisp.app` in place: binary :59, Info.plist :63, rpath :68.
  - It runs `rm -rf /Applications/MetaWhisp.app`, then `ditto`, with no backup (:72-73).
  - It signs the outer bundle with all output sent to /dev/null (:81-85), verifies (:88-91), and
    runs `open` (:93-97).
- F2. Under `set -euo pipefail` (:2), a codesign failure stops the script at :81 with no message.
  - By then /Applications holds the new binary and Info.plist, which no Developer ID signature
    covers. The app is dead and nothing relaunches it.
  - The verify at :88 also exits silently when the Developer ID authority is missing (no grep match
    plus pipefail), so the WARN at :89-91 can never be reached.
- F3. `build.sh`:
  - It falls back to ad-hoc signing when the certificate is missing (:166-171).
  - Its codesign output goes to the terminal (:199-203, :256-261), and a signing failure exits
    before any kill.
  - The identifier check only warns (:280-286). It passes even for ad-hoc, because `--identifier`
    is forced (:259).
  - `pkill -f "MetaWhisp.app"` (:300) also kills /Applications/MetaWhisp.app. The script then
    installs to ~/Applications (:311-312) and launches that copy (:318).
  - `release.sh:60` runs `pkill -x MetaWhisp`. No script checks for a recording or a transcription.
- F4. Nothing outside the process can see whether the app is busy.
  - The busy state lives in `MeetingRecorder.isRecording/isStarting` (MeetingRecorder.swift:14-15)
    and `TranscriptionCoordinator.stage` (:10-17). Meeting transcription runs in an untracked Task
    (AppDelegate.swift:1944).
  - There is no SIGTERM handler. The processes that ended at about 10:25, 11:25 and 11:51 logged
    neither "quit —" nor "Terminating" (AppDelegate.swift:2661, :2693), so the meeting rescue
    (:2654-2686) did not run.
- F5. These follow the bundle id, so a new id separates them with no code change: UserDefaults and
  @AppStorage (no suiteName anywhere), TCC, the login item via `SMAppService.mainApp`
  (LaunchAtLoginManager.swift:52, :84), and the single-instance guard (AppDelegate.swift:335).
- F6. Hardcoded identities:
  - Name, executable, icon, bundle id and URL scheme (Info.plist:7-18, :29-38). The Sparkle feed
    (Info.plist:66-71); the updater always starts (AppDelegate.swift:357).
  - The deep-link check `scheme == "metawhisp"` (AppDelegate.swift:3350).
  - The SwiftData store `Application Support/MetaWhisp.store`, opened via
    `ModelConfiguration("MetaWhisp")` (HistoryService.swift:17-21, :30).
  - Keychain service `com.metawhisp.secrets` and accounts `com.metawhisp.*` (AppSettings.swift:488,
    :401-433; LicenseService.swift:33, :58-61).
  - The log file (FileLogger.swift:29-38) and the os_log subsystem `com.metawhisp.app`.
- F7. Nine places build `Application Support/MetaWhisp` by hand:
  - models (AppSettings.swift:464) and the legacy .secrets file (:558-561);
  - Recovery WAVs (AppDelegate.swift:3234-3242; TranscriptionCoordinator.swift:537-541);
  - `mcp-snapshot.json` (MCPSnapshotService.swift:35-39), which the MCP CLI reads
    (Sources/MetaWhispMCP/main.swift:80-85);
  - queues (ExtractionQueueStore.swift:149-150), the suspect log (SuspectTranscriptLog.swift:25-26),
    corrections (CorrectionDictionary.swift:87-88) and sounds (MainSettingsView.swift:1177-1178).
- F8. Global input: hotkeys are always registered (AppDelegate.swift:944-952) and LayoutFix is on by
  default (AppSettings.swift:32-34). A second app would react to the same Right ⌘ press and rewrite
  the same word.
- F9. Hotkeys use four NSEvent monitors (HotkeyService.swift:67-87).
  - If the app is not trusted at registration, a 2 s poll (:238) reinstalls them when trust arrives
    (:242-247 → :260-267) and gives up after 600 s (HotkeyRearmPolicy.swift:18, :27-29;
    HotkeyService.swift:250-254).
  - If the app is trusted at launch there is no watcher at all (:233-234).
  - HotkeyRearmTests.swift:41-46 asserts the give-up.
- F10. LayoutFix: `start()` returns `.needsAccessibility` when the app is not trusted
  (LayoutSwitchController.swift:315-317), and it has no watcher.
  - It re-arms only at launch (AppDelegate.swift:957) and in `applicationDidBecomeActive` (:2607),
    which logs "Re-armed" whatever the result (:2608).
  - The app is LSUIElement, so it becomes active only when its own window gets focus.
- F11. Screen Recording is checked again only on activation plus 500 ms (AppDelegate.swift:2613-2623),
  after a request (PermissionsService.swift:55), and when system audio starts
  (SystemAudioCaptureService.swift:83-97).
- F12. KeychainHelper:
  - `keychainRead` returns nil for every status except errSecSuccess (AppSettings.swift:542-543).
  - `keychainWrite` deletes first (:526) and adds second (:530), and `save` throws the result away
    (:501). `save(value: "")` deletes the item (:500).
  - No OSStatus is logged anywhere.
- F13. `LicenseService.init`: when reads return nil, `isPro` becomes false and verify is skipped
  (LicenseService.swift:58-84). Nothing is deleted there.
- F14. Paths that delete Pro items:
  - `signOut()` (:496-510), called from MainSettingsView.swift:766, :792 and from verify at :291 and
    :316.
  - `clearInactiveLicense()` (:382-392), called at :157 and :366.
  - Every non-empty save deletes before it adds.
  - Hazard: when the token reads but the key does not, the probe is skipped (:280-281), and a
    401/403 then runs `signOut` (:316), which deletes the key it could not read.
- F15. The log shows:
  - the token and stamp were already missing on 2026-09-22 (MetaWhisp.log.1);
  - no "Sign-out START" or "NOT subscribed" since then;
  - at 10:58:53-54 the owner signed in and the log says "Pro activated";
  - at 11:25:07 and 11:51:40 it says key=none again.
- F16. Likely cause of today's loss: the delete-then-add writes in `activate()` at 10:58:54, while
  the login keychain was refusing access (fixed at 11:51 by lock/unlock). The add failed after the
  delete and its status was thrown away. Now none of the five items exists.

## 2. Changes
- C1. New `Services/System/AppIdentity.swift`:
  - `struct AppIdentity { enum Flavor { case production, dev } }`. Only the exact id
    `com.metawhisp.app` counts as production; the flavor is logged at launch.
  - Fields: supportDirectory, storeURL, keychainService, logFileURL, urlScheme, updaterEnabled,
    globalInputDefault, selfBundleIDs.
  - Production values equal today's literals. Dev values: a "MetaWhisp Dev" folder,
    "MetaWhisp Dev.store", `com.metawhisp.dev.secrets`, "MetaWhisp Dev.log", scheme
    `metawhisp-dev`, updater off, global input off.
- C2. Every literal in F6-F7 reads from `AppIdentity.current`:
  - HistoryService uses `ModelConfiguration(..., url: storeURL)`; FileLogger, KeychainHelper and the
    nine folder builders follow.
  - The deep-link check follows it, and Sparkle starts only when `updaterEnabled`.
  - A Dev badge goes on the menu-bar icon, and the screen-capture exclusions include the Dev app.
- C3. The Dev Info.plist is generated from `Resources/Info.plist` with PlistBuddy at install time:
  - bundle id `com.metawhisp.app.dev`, name "MetaWhisp Dev", executable `MetaWhispDev`;
  - its own icon and URL scheme, no Sparkle feed;
  - installed at `~/Applications/MetaWhisp Dev.app`.
- C4. A new `globalHotkeysEnabled` setting gates AppDelegate.swift:944. It and the LayoutFix
  defaults take `globalInputDefault`.
- C5. `hot-swap.sh` installs only MetaWhisp Dev:
  - It refuses any production target.
  - A preflight changes nothing: it signs a throwaway copy of /usr/bin/true with the team identity,
    verifies the authority and team, and prints codesign's stderr with the fix on failure.
  - Busy gate (C7). The bundle is assembled, signed and verified in a temp dir.
  - It sends SIGTERM to the Dev process only and waits up to 15 s. It never uses SIGKILL.
  - It moves the old bundle to a backup, installs, verifies in place and relaunches. An EXIT trap
    restores the backup on any failure.
  - Checks are written as `if !` blocks.
- C6. `build.sh`:
  - The ad-hoc fallback is removed, and the same preflight runs first.
  - The identity checks become errors.
  - `--dev` installs MetaWhisp Dev. A production build kills and launches nothing.
  - `release.sh` gets the busy gate and a graceful quit.
- C7. New `ActivityLease`: a pure `state(isRecording:isStarting:stage:meetingsInFlight:)`.
  - AppDelegate writes {pid, state, since} to `<supportDirectory>/activity.json`.
  - The script refuses while the pid is alive and the state is not idle. A dead pid releases the
    lease.
- C8. SIGTERM is handled with `DispatchSource.makeSignalSource` calling `NSApp.terminate`, so any
  kill goes through the meeting rescue.
- C9. KeychainHelper:
  - `enum KeychainRead { case value(String), notFound, failed(OSStatus) }`.
  - `write` uses SecItemUpdate, then SecItemAdd only on errSecItemNotFound; it never deletes first.
  - `delete` is explicit, and only sign-out and the key-clear buttons use it.
  - Every failure is logged with the account and status, never the value. An injected backend
    makes it testable.
- C10. LicenseService:
  - A pure `LicenseRestore.decide(...) -> .restored | .signedOut | .unreadable(account:status:)`.
    On `.unreadable` the service writes and deletes nothing, skips verify, and shows the problem.
  - `signOut(reason:)`. Verify can never sign out while any item was unreadable this launch.
  - `activate()` checks every write and reports a failed write instead of "Pro activated".
- C11. New `PermissionMonitor`, the only owner of the Accessibility and Screen Recording state:
  - It re-checks on `NSWorkspace.didActivateApplicationNotification`, on
    `NSApplication.didBecomeActiveNotification`, and on a backup timer. It never stops.
  - On `.granted` it reinstalls the hotkey monitors, starts LayoutFix and restarts screen context.
    On `.revoked` it stops them.
  - `watchCeilingSeconds` is deleted.

## 3. Tests to write first
- T1. The dev flavor shares no path, keychain service, scheme or log file with production.
- T2. A source scan finds none of the identity literals outside AppIdentity.swift.
- T3. KeychainHelper with a fake backend: not-found vs failed(status); a failed update never deletes.
- T4. An unreadable key is never "signed out"; a 401/403 while unreadable never signs out; a failed
  activation write is reported.
- T5. PermissionTransition: a grant is picked up at any elapsed time (replaces
  testTheWatchGivesUpEventually); revoke-then-grant re-arms again.
- T6. LayoutSwitchController with an injected trust check becomes active on `.granted`.
- T7. ActivityLease is busy while recording, starting, dictating or transcribing a meeting.
- T8. Dev defaults: updater off, global input off, own deep-link scheme only.
- T9. Script tests with a SIGN_CMD override:
  - a production target is refused;
  - a failing preflight changes nothing and kills nothing;
  - a busy live lease is refused, and a dead-pid lease proceeds.

## 4. Spec corrections
- The ad-hoc path is in build.sh (:166-171), not hot-swap.sh. build.sh:300 and release.sh:60 belong
  in "Where it changes".
- US-0.4: the Pro items were removed by the write path (delete-then-add in `activate()`), not only
  by reads. The token and stamp were already missing on 2026-09-22.
- US-0.3: "re-checks on every app activation" is not enough for an LSUIElement app. The monitor
  must re-check on any app switch and on a timer.
- US-0.1's list must add the URL scheme, Sparkle, the process name, the Application Support folder,
  and global input.
- US-0.2's busy refusal needs app code (C7). The owner also needs a one-time step: allow
  /usr/bin/codesign to use the Developer ID key.

## 5. Open questions
- Q2. Pro in the Dev app: the website's sign-in redirect targets `metawhisp://` (hypothesis).
  - Dev needs its own scheme support, BYOK keys, or no LLM.
  - Dev meetings would book minutes to the owner's quota.
- Q3. Share the speech and LLM model caches read-only with Dev, or keep separate copies?
- Q4. Hypothesis: macOS 26 may send a trust-change notification that could replace the backup timer.

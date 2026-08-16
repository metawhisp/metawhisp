import AppKit
import ApplicationServices
import Carbon
import Foundation

/// Boundary around the focused-text mutation path. It permits controller
/// dispatch to be tested without reading or changing any live editor text.
/// `isStillCurrent` answers "does this correction still belong to the keystroke
/// that asked for it?". The gateway holds a LIVE SELECTION in the user's
/// document across an async round trip, so it must ask again at every
/// checkpoint — before selecting, before copying, and immediately before the
/// paste is posted. See `LayoutTypingRaceTests`.
@MainActor
protocol LayoutTextCorrecting: AnyObject {
    func replaceTokenBeforeCaret(
        expectedToken: String,
        trailingText: String,
        replacement: String,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) async -> FocusedTextGateway.ReplacementOutcome

    func correctSelectedTextOrCurrentLine(
        typedIn source: KeyboardLayout,
        mapper: KeyboardLayoutMapper,
        isStillCurrent: @escaping @MainActor () -> Bool
    ) async -> FocusedTextGateway.ManualCorrectionOutcome
}

extension FocusedTextGateway: LayoutTextCorrecting {}

/// Boundary around the two supported macOS input sources. The production
/// implementation remains `InputSourceService`; tests use an in-memory spy.
@MainActor
protocol LayoutInputSourceManaging: AnyObject {
    func currentLayout() -> KeyboardLayout?
    @discardableResult func select(_ layout: KeyboardLayout) -> Bool
}

extension InputSourceService: LayoutInputSourceManaging {}

/// Recognises two clean Shift press/release cycles. The timestamp unit is
/// monotonic nanoseconds since startup.
struct LayoutDoubleShiftDetector {
    private let maximumIntervalNanoseconds: UInt64
    private var firstReleaseTimestamp: UInt64?
    private var shiftIsPressed = false
    private var ignoresNextShiftRelease = false

    init(maximumIntervalNanoseconds: UInt64 = 400_000_000) {
        self.maximumIntervalNanoseconds = maximumIntervalNanoseconds
    }

    mutating func recordShiftPress() {
        guard !ignoresNextShiftRelease else { return }
        shiftIsPressed = true
    }

    mutating func recordShiftRelease(atNanoseconds timestamp: UInt64) -> Bool {
        if ignoresNextShiftRelease {
            ignoresNextShiftRelease = false
            shiftIsPressed = false
            firstReleaseTimestamp = nil
            return false
        }
        guard shiftIsPressed else {
            firstReleaseTimestamp = nil
            return false
        }
        shiftIsPressed = false
        guard let firstReleaseTimestamp,
              timestamp >= firstReleaseTimestamp,
              timestamp - firstReleaseTimestamp <= maximumIntervalNanoseconds else {
            self.firstReleaseTimestamp = timestamp
            return false
        }

        self.firstReleaseTimestamp = nil
        return true
    }

    mutating func interrupt(ignoringNextShiftRelease: Bool = false) {
        firstReleaseTimestamp = nil
        shiftIsPressed = false
        ignoresNextShiftRelease = ignoringNextShiftRelease
    }
}

/// One word retained only in RAM until its separator arrives.
struct LayoutBufferedToken: Equatable {
    let token: String
    let convertedToken: String
    let source: KeyboardLayout
    let trailingText: String
}

struct LayoutWordBuffer {
    private let maxTokenLength: Int
    private var token = ""
    private var convertedToken = ""
    private var tokenSource: KeyboardLayout?

    init(maxTokenLength: Int = 24) {
        self.maxTokenLength = maxTokenLength
    }

    mutating func record(
        _ typedText: String,
        keyCode: UInt16? = nil,
        flags: NSEvent.ModifierFlags = [],
        source: KeyboardLayout,
        mapper: KeyboardLayoutMapper = .russianEnglish
    ) -> LayoutBufferedToken? {
        guard typedText.count == 1, let character = typedText.first else {
            reset()
            return nil
        }

        let targetCharacter: Character?
        if let keyCode {
            guard let translation = mapper.translation(
                for: keyCode,
                shifted: flags.contains(.shift),
                capsLock: flags.contains(.capsLock),
                from: source
            ), translation.source == character else {
                reset()
                return nil
            }
            targetCharacter = translation.target
        } else {
            targetCharacter = mapper.convert(String(character), from: source)?.first
        }

        if character.isLetter || targetCharacter?.isLetter == true {
            guard let targetCharacter else {
                reset()
                return nil
            }
            guard tokenSource == nil || tokenSource == source else {
                reset()
                return nil
            }
            guard token.count < maxTokenLength else {
                reset()
                return nil
            }

            tokenSource = source
            token.append(character)
            convertedToken.append(targetCharacter)
            return nil
        }

        guard Self.isSeparator(character),
              let tokenSource,
              tokenSource == source,
              !token.isEmpty else {
            reset()
            return nil
        }

        defer { reset() }
        return LayoutBufferedToken(
            token: token,
            convertedToken: convertedToken,
            source: source,
            trailingText: typedText
        )
    }

    mutating func reset() {
        token = ""
        convertedToken = ""
        tokenSource = nil
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character.isPunctuation
    }
}

/// Reads only the minimum current-focus metadata required to keep secure and
/// excluded targets out of the automatic buffer entirely.
struct LayoutInputContextIdentity: Equatable {
    let processIdentifier: pid_t
    let focusedElementHash: CFHashCode
}

@MainActor
enum LayoutCaptureSafetyGate {
    static func currentContextIdentity(
        safetyPolicy: LayoutSafetyPolicy = .default
    ) -> LayoutInputContextIdentity? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let focusedElement: AXUIElement = attributeValue(
                  kAXFocusedUIElementAttribute,
                  from: AXUIElementCreateSystemWide()
              ) else {
            return nil
        }

        guard LayoutFocusedElementSafety.permits(
            focusedElement,
            in: frontmostApplication,
            safetyPolicy: safetyPolicy
        ) else {
            return nil
        }
        return LayoutInputContextIdentity(
            processIdentifier: frontmostApplication.processIdentifier,
            focusedElementHash: CFHash(focusedElement)
        )
    }

    private static func attributeValue<T>(
        _ attribute: String,
        from element: AXUIElement
    ) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value as? T
    }
}

/// Global listen-only input controller for the conservative automatic path.
///
/// It never suppresses events and never logs text. Exact text replacement is
/// delegated to `FocusedTextGateway`, which revalidates the focused field.
@MainActor
final class LayoutSwitchController {
    enum State: String, Equatable {
        case disabled
        case needsAccessibility
        case unavailable
        case active
    }

    private let confidenceEngine: LayoutConfidenceEngine
    private let textGateway: any LayoutTextCorrecting
    private let inputSourceService: any LayoutInputSourceManaging
    private let isKnownWord: (String, KeyboardLayout) -> Bool
    private let permitsInputCapture: @MainActor () -> Bool
    private let inputContextIdentity: @MainActor () -> LayoutInputContextIdentity?
    private var wordBuffer = LayoutWordBuffer()
    private var doubleShiftDetector = LayoutDoubleShiftDetector()
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    /// Held only until the target application commits the separator event.
    /// No text is persisted or logged.
    private var correctionTask: Task<Void, Never>?
    private var correctionIsInFlight = false
    private var didObserveInput = false
    private var lastInputContextIdentity: LayoutInputContextIdentity?
    /// Bumped by every text-producing key event. A correction is stamped with
    /// the value it was scheduled at; once the user types again the stamp is
    /// stale and the correction must not touch the document. Modifier-only
    /// events deliberately do NOT bump it — reaching for Shift to start the
    /// next word inserts nothing and cannot eat a selection.
    private var inputGeneration: UInt64 = 0
    var onAutomaticCorrection: ((LayoutCorrection) -> Void)?

    init(confidenceEngine: LayoutConfidenceEngine = LayoutConfidenceEngine()) {
        SystemLayoutLexicon.shared.warmUp()
        self.confidenceEngine = confidenceEngine
        self.textGateway = FocusedTextGateway()
        self.inputSourceService = InputSourceService()
        self.isKnownWord = { word, language in
            SystemLayoutLexicon.shared.contains(word, language: language)
        }
        self.permitsInputCapture = { true }
        self.inputContextIdentity = {
            LayoutCaptureSafetyGate.currentContextIdentity()
        }
    }

    init(
        confidenceEngine: LayoutConfidenceEngine = LayoutConfidenceEngine(),
        textGateway: any LayoutTextCorrecting,
        inputSourceService: any LayoutInputSourceManaging,
        isKnownWord: ((String, KeyboardLayout) -> Bool)? = nil,
        permitsInputCapture: @escaping @MainActor () -> Bool = { true },
        inputContextIdentity: @escaping @MainActor () -> LayoutInputContextIdentity? = {
            LayoutInputContextIdentity(processIdentifier: 0, focusedElementHash: 0)
        }
    ) {
        SystemLayoutLexicon.shared.warmUp()
        self.confidenceEngine = confidenceEngine
        self.textGateway = textGateway
        self.inputSourceService = inputSourceService
        self.isKnownWord = isKnownWord ?? { word, language in
            SystemLayoutLexicon.shared.contains(word, language: language)
        }
        self.permitsInputCapture = permitsInputCapture
        self.inputContextIdentity = inputContextIdentity
    }

    @discardableResult
    func start() -> State {
        stop()
        guard Self.shouldObserveInput(
            featureEnabled: AppSettings.shared.layoutFixEnabled,
            automaticEnabled: AppSettings.shared.layoutFixAutoEnabled,
            doubleShiftEnabled: AppSettings.shared.layoutFixDoubleShiftEnabled
        ) else {
            return .disabled
        }
        guard AXIsProcessTrusted() else {
            return .needsAccessibility
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.observeKeyDown(event)
        }
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.observeFlagsChanged(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.observeKeyDown(event)
            return event
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.observeFlagsChanged(event)
            return event
        }

        guard globalKeyMonitor != nil,
              globalFlagsMonitor != nil,
              localKeyMonitor != nil,
              localFlagsMonitor != nil else {
            stop()
            return .unavailable
        }
        return .active
    }

    func stop() {
        correctionTask?.cancel()
        correctionTask = nil
        correctionIsInFlight = false
        wordBuffer.reset()
        doubleShiftDetector.interrupt()
        for monitor in [globalKeyMonitor, localKeyMonitor, globalFlagsMonitor, localFlagsMonitor] {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        globalKeyMonitor = nil
        localKeyMonitor = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        didObserveInput = false
        lastInputContextIdentity = nil
    }

    private func observeKeyDown(_ event: NSEvent) {
        recordObservedInputOnce()
        handleKeyDown(
            text: event.characters ?? "",
            keyCode: event.keyCode,
            flags: event.modifierFlags
        )
    }

    private func observeFlagsChanged(_ event: NSEvent) {
        recordObservedInputOnce()
        handleFlagsChanged(
            keyCode: event.keyCode,
            flags: event.modifierFlags,
            timestamp: UInt64(event.timestamp * 1_000_000_000)
        )
    }

    private func recordObservedInputOnce() {
        guard !didObserveInput else { return }
        didObserveInput = true
        NSLog("[LayoutFix] Input monitor observed an event; contents are never logged")
    }

    func handleKeyDown(
        text: String,
        keyCode: UInt16? = nil,
        flags: NSEvent.ModifierFlags
    ) {
        inputGeneration &+= 1
        doubleShiftDetector.interrupt(
            ignoringNextShiftRelease: flags.contains(.shift)
        )
        guard AppSettings.shared.layoutFixEnabled,
              AppSettings.shared.layoutFixAutoEnabled,
              flags.intersection([.command, .control, .option]).isEmpty,
              synchronizeInputContext(),
              let source = inputSourceService.currentLayout() else {
            wordBuffer.reset()
            return
        }

        guard let bufferedToken = wordBuffer.record(
                  text,
                  keyCode: keyCode,
                  flags: flags,
                  source: source,
                  mapper: .russianEnglish
              ),
              let correction = confidenceEngine.automaticCorrection(
                  for: bufferedToken.token,
                  convertedTo: bufferedToken.convertedToken,
                  typedIn: bufferedToken.source,
                  isKnownWord: isKnownWord
              ) else {
            return
        }

        NSLog("[LayoutFix] High-confidence automatic candidate detected")
        scheduleAutomaticCorrection(
            bufferedToken: bufferedToken,
            correction: correction
        )
    }

    static func shouldObserveInput(
        featureEnabled: Bool,
        automaticEnabled: Bool,
        doubleShiftEnabled: Bool
    ) -> Bool {
        featureEnabled && (automaticEnabled || doubleShiftEnabled)
    }

    private func synchronizeInputContext() -> Bool {
        guard permitsInputCapture(),
              let currentIdentity = inputContextIdentity() else {
            wordBuffer.reset()
            doubleShiftDetector.interrupt()
            lastInputContextIdentity = nil
            return false
        }
        if let lastInputContextIdentity,
           lastInputContextIdentity != currentIdentity {
            wordBuffer.reset()
            doubleShiftDetector.interrupt()
        }
        lastInputContextIdentity = currentIdentity
        return true
    }

    /// `NSEvent`'s global monitor can run before the focused app has inserted
    /// the separator. Delay one short run-loop turn, then let the gateway
    /// revalidate the AX text and caret before it edits anything.
    private func scheduleAutomaticCorrection(
        bufferedToken: LayoutBufferedToken,
        correction: LayoutCorrection
    ) {
        guard !correctionIsInFlight else {
            NSLog("[LayoutFix] Automatic correction skipped: another correction is active")
            return
        }
        let scheduledGeneration = inputGeneration
        correctionTask?.cancel()
        correctionTask = Task { @MainActor [weak self] in
            NSLog("[LayoutFix] Automatic correction queued")
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                NSLog("[LayoutFix] Automatic correction cancelled before dispatch")
                return
            }
            guard !Task.isCancelled, let self else { return }
            // The user typed on during the delay. Their next character would
            // land inside the window where the word is selected, so the
            // correction is already obsolete — drop it before touching text.
            guard self.inputGeneration == scheduledGeneration else {
                NSLog("[LayoutFix] Automatic correction dropped: typing continued")
                return
            }
            self.correctionIsInFlight = true
            defer {
                self.correctionIsInFlight = false
                self.correctionTask = nil
            }
            NSLog("[LayoutFix] Automatic correction dispatch started")
            await self.applyAutomaticCorrection(
                bufferedToken: bufferedToken,
                correction: correction,
                scheduledGeneration: scheduledGeneration
            )
        }
    }

    private func applyAutomaticCorrection(
        bufferedToken: LayoutBufferedToken,
        correction: LayoutCorrection,
        scheduledGeneration: UInt64,
        retriesRemaining: Int = 1
    ) async {
        let outcome = await textGateway.replaceTokenBeforeCaret(
            expectedToken: bufferedToken.token,
            trailingText: bufferedToken.trailingText,
            replacement: correction.replacement,
            isStillCurrent: { [weak self] in
                self?.inputGeneration == scheduledGeneration
            }
        )
        if case .skipped(.staleTarget) = outcome, retriesRemaining > 0 {
            // Some editors publish the separator to Accessibility a little
            // after the key event. Retry that read once; every other failure
            // remains a safe no-op.
            do {
                try await Task.sleep(for: .milliseconds(64))
            } catch {
                return
            }
            guard !Task.isCancelled, inputGeneration == scheduledGeneration else { return }
            await applyAutomaticCorrection(
                bufferedToken: bufferedToken,
                correction: correction,
                scheduledGeneration: scheduledGeneration,
                retriesRemaining: retriesRemaining - 1
            )
            return
        }

        guard outcome == .replaced else {
            if case let .skipped(reason) = outcome {
                NSLog("[LayoutFix] Automatic replacement skipped: %@", reason.rawValue)
            }
            return
        }

        if AppSettings.shared.layoutFixSwitchInputSource {
            _ = inputSourceService.select(correction.targetLayout)
        }
        NSLog("[LayoutFix] Automatic replacement applied")
        onAutomaticCorrection?(correction)
    }

    func handleFlagsChanged(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        timestamp: UInt64
    ) {
        guard AppSettings.shared.layoutFixEnabled,
              AppSettings.shared.layoutFixDoubleShiftEnabled,
              synchronizeInputContext() else {
            doubleShiftDetector.interrupt()
            return
        }

        let isShiftKey = keyCode == UInt16(kVK_Shift) || keyCode == UInt16(kVK_RightShift)
        guard isShiftKey else {
            doubleShiftDetector.interrupt(
                ignoringNextShiftRelease: flags.contains(.shift)
            )
            return
        }
        let conflictingModifiers = flags.intersection([
            .command, .control, .option, .capsLock, .function
        ])
        guard conflictingModifiers.isEmpty else {
            doubleShiftDetector.interrupt(
                ignoringNextShiftRelease: flags.contains(.shift)
            )
            return
        }
        if flags.contains(.shift) {
            doubleShiftDetector.recordShiftPress()
            return
        }
        guard
              doubleShiftDetector.recordShiftRelease(atNanoseconds: timestamp) else {
            return
        }

        NSLog("[LayoutFix] Double Shift gesture detected")
        wordBuffer.reset()
        guard let source = inputSourceService.currentLayout() else { return }
        guard !correctionIsInFlight else {
            NSLog("[LayoutFix] Manual correction skipped: another correction is active")
            return
        }
        let scheduledGeneration = inputGeneration
        correctionTask?.cancel()
        correctionTask = nil
        correctionIsInFlight = true
        correctionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.correctionIsInFlight = false
                self.correctionTask = nil
            }
            NSLog("[LayoutFix] Manual correction dispatch started")
            let outcome = await self.textGateway.correctSelectedTextOrCurrentLine(
                typedIn: source,
                mapper: .russianEnglish,
                isStillCurrent: { [weak self] in
                    self?.inputGeneration == scheduledGeneration
                }
            )
            guard case let .corrected(correction) = outcome else {
                if case let .skipped(reason) = outcome {
                    NSLog("[LayoutFix] Manual replacement skipped: %@", reason.rawValue)
                }
                return
            }

            if AppSettings.shared.layoutFixSwitchInputSource {
                _ = self.inputSourceService.select(correction.targetLayout)
            }
            self.onAutomaticCorrection?(correction)
        }
    }
}

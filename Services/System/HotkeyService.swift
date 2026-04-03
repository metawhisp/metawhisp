import AppKit
import Foundation
import os

/// Detects Right Command / Right Option key taps as global hotkeys.
/// Right ⌥ also supports long-press (≥2s) for translating selected text.
@MainActor
final class HotkeyService: ObservableObject {
    private static let logger = Logger(subsystem: "com.metawhisp.app", category: "Hotkey")

    // NX_DEVICERCMDKEYMASK / NX_DEVICERALTKEYMASK from IOKit/IOLLEvent.h
    private static let rightCmdMask: UInt = 0x10
    private static let rightOptMask: UInt = 0x40

    private var onToggle: (() -> Void)?
    private var onPTTStart: (() -> Void)?
    private var onPTTStop: (() -> Void)?
    private var onTranslateToggle: (() -> Void)?
    private var onTranslateLongPress: (() -> Void)?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?

    // Right Cmd state
    private var rightCmdDown = false
    private var rightCmdDownTime: Date?
    private var otherKeysDuringRightCmd = false

    // Right Option state
    private var rightOptDown = false
    private var rightOptDownTime: Date?
    private var otherKeysDuringRightOpt = false
    private var longPressTimer: DispatchWorkItem?
    private var longPressFired = false

    private let maxTapDuration: TimeInterval = 0.4
    private let longPressDuration: TimeInterval = 1.5

    func register(
        onToggle: @escaping () -> Void,
        onPTTStart: @escaping () -> Void,
        onPTTStop: @escaping () -> Void,
        onTranslateToggle: @escaping () -> Void,
        onTranslateLongPress: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        self.onPTTStart = onPTTStart
        self.onPTTStop = onPTTStop
        self.onTranslateToggle = onTranslateToggle
        self.onTranslateLongPress = onTranslateLongPress

        // Global monitors — events going to OTHER apps
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            guard let self else { return }
            if self.rightCmdDown { self.otherKeysDuringRightCmd = true }
            if self.rightOptDown { self.otherKeysDuringRightOpt = true }
        }
        // Local monitors — events going to OUR app (when popover/window has focus)
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Don't interfere with standard text editing (Cmd+V/C/X/A/Z)
            if event.modifierFlags.contains(.command) { return event }
            if self.rightCmdDown { self.otherKeysDuringRightCmd = true }
            if self.rightOptDown { self.otherKeysDuringRightOpt = true }
            return event
        }
        NSLog("[HotkeyService] Right ⌘, Right ⌥ (tap+long-press) registered (global+local)")
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let deviceFlags = event.modifierFlags.rawValue & 0xFFFF
        // Right ⌘ — toggle or PTT depending on settings
        handleRightCmd(isDown: deviceFlags & Self.rightCmdMask != 0)
        // Right ⌥ — tap + long-press (dedicated handler)
        handleRightOpt(isDown: deviceFlags & Self.rightOptMask != 0)
    }

    /// Right ⌘: Toggle mode = tap to start/stop. PTT mode = hold to record, release to stop.
    private func handleRightCmd(isDown: Bool) {
        let isPTT = AppSettings.shared.hotkeyMode == "pushToTalk"

        if isPTT {
            // Push-to-Talk: hold to record, release to stop
            // Short taps (< 0.15s) are ignored — only sustained hold triggers recording
            if isDown && !rightCmdDown {
                rightCmdDown = true
                rightCmdDownTime = Date()
                // Delay start — only fire if still held after 0.15s
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self, self.rightCmdDown else { return }
                    NSLog("[HotkeyService] Right ⌘ PTT START (held)")
                    Task { @MainActor in self.onPTTStart?() }
                }
            } else if !isDown && rightCmdDown {
                let held = Date().timeIntervalSince(rightCmdDownTime ?? Date())
                rightCmdDown = false
                // Only stop if recording actually started (held > 0.3s)
                if held >= 0.3 {
                    NSLog("[HotkeyService] Right ⌘ PTT STOP (held %.1fs)", held)
                    Task { @MainActor in onPTTStop?() }
                } else {
                    NSLog("[HotkeyService] Right ⌘ PTT ignored short tap (%.2fs)", held)
                }
            }
        } else {
            // Toggle mode: tap < 0.4s = toggle
            handleKey(
                isDown: isDown,
                wasDown: &rightCmdDown, downTime: &rightCmdDownTime,
                otherKeys: &otherKeysDuringRightCmd, name: "Right ⌘", action: onToggle
            )
        }
    }

    /// Right ⌥ with long-press support: tap (<0.4s) = transcribe+translate, hold (≥2s) = translate selection.
    private func handleRightOpt(isDown: Bool) {
        if isDown && !rightOptDown {
            // Key just pressed
            rightOptDown = true
            rightOptDownTime = Date()
            otherKeysDuringRightOpt = false
            longPressFired = false

            // Schedule long-press timer
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.rightOptDown else { NSLog("[HotkeyService] Right ⌥ long-press cancelled: key released"); return }
                guard !self.otherKeysDuringRightOpt else { NSLog("[HotkeyService] Right ⌥ long-press cancelled: other keys pressed"); return }
                self.longPressFired = true
                NSLog("[HotkeyService] Right ⌥ long-press detected (1.5s)")
                Task { @MainActor in self.onTranslateLongPress?() }
            }
            longPressTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + longPressDuration, execute: work)

        } else if !isDown && rightOptDown {
            // Key released
            rightOptDown = false
            longPressTimer?.cancel()
            longPressTimer = nil

            // Fire tap only if: short press, no other keys, long-press didn't fire
            if let t = rightOptDownTime,
               Date().timeIntervalSince(t) < maxTapDuration,
               !otherKeysDuringRightOpt,
               !longPressFired {
                NSLog("[HotkeyService] Right ⌥ tap detected")
                Task { @MainActor in onTranslateToggle?() }
            }
        }
    }

    private func handleKey(
        isDown: Bool, wasDown: inout Bool, downTime: inout Date?,
        otherKeys: inout Bool, name: String, action: (() -> Void)?
    ) {
        if isDown && !wasDown {
            wasDown = true; downTime = Date(); otherKeys = false
        } else if !isDown && wasDown {
            wasDown = false
            if let t = downTime, Date().timeIntervalSince(t) < maxTapDuration && !otherKeys {
                NSLog("[HotkeyService] %@ tap detected", name)
                Task { @MainActor in action?() }
            }
        }
    }

    func unregister() {
        longPressTimer?.cancel()
        longPressTimer = nil
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil; localFlagsMonitor = nil
        keyMonitor = nil; localKeyMonitor = nil
        onToggle = nil; onPTTStart = nil; onPTTStop = nil
        onTranslateToggle = nil; onTranslateLongPress = nil
    }
}

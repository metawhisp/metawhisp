import XCTest

/// C4 / PRD P0 1 — launch shows no system prompt, whether onboarding is
/// finished or not: both start through `applicationDidFinishLaunching` and the
/// same `setupServices`, so neither may call an API that asks for a
/// permission. Permissions are asked from their own buttons, when a feature is
/// turned on, and by the first record press. The audio warm-up, which can
/// bring the microphone prompt up too, is handed to
/// `TranscriptionCoordinator.prepareMicrophoneAtLaunch`, which runs it only on
/// a grant.
///
/// Step-1 review #1 — the launch functions' own bodies are not enough: a
/// prompt reached the launch through `startMonitoring`. So every call that
/// shows a prompt sits in a function that takes a `PermissionAsk`, and only a
/// user's action makes one: no automatic path — launch, activation, a timer,
/// a meeting that starts itself — can reach a prompt, however indirectly.
final class LaunchPermissionGuardTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/LaunchPermissionGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var appDelegate: URL { repoRoot.appendingPathComponent("App/AppDelegate.swift") }

    /// Where a `PermissionAsk` may be made outside the views (every view's
    /// button is a user action): the file, and the functions in it.
    private let userActions: [String: Set<String>] = [
        "TranscriptionCoordinator.swift": ["askForMicrophone"],                        // the first record press
        "PracticeRecorder.swift": ["start"],                                           // the practice's record press
        "AppDelegate.swift": ["startMeetingRecording", "observeIntelligenceSettings"], // RECORD, the Settings switches
    ]

    /// The system calls that show a prompt.
    private let prompts = ["CGRequestScreenCaptureAccess(", "requestFullAccessToEvents(", "requestAccess(to: .event",
                           "requestRecordPermission(", "requestAccess(for: .audio"]

    /// Every Swift file outside the views, with its comment-free lines.
    private func nonViewSources() throws -> [(name: String, code: [String])] {
        var out: [(String, [String])] = []
        for folder in ["App", "Services", "Models", "Helpers"] {
            let base = repoRoot.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let code = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                    .map { raw in raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw }
                out.append((url.lastPathComponent, code))
            }
        }
        XCTAssertGreaterThan(out.count, 50, "the guard must actually scan sources")
        return out
    }

    /// The function a line sits in: its name and its declaration up to the brace.
    private func enclosingFunction(of index: Int, in code: [String]) -> (name: String, signature: String)? {
        let declaration = try? NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        for start in stride(from: index, through: 0, by: -1) {
            let line = code[start]
            guard let match = declaration?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            var signature = ""
            for later in start..<code.count {
                signature += code[later]
                if code[later].contains("{") { break }
            }
            return (String(line[range]), signature)
        }
        return nil
    }

    func testOnlyAUserActionMakesAPermissionAsk() throws {
        var made = 0
        for (name, code) in try nonViewSources() {
            for (index, line) in code.enumerated() where line.contains("PermissionAsk()") {
                made += 1
                let function = enclosingFunction(of: index, in: code)?.name ?? "?"
                XCTAssertTrue(userActions[name]?.contains(function) == true,
                              "\(name):\(index + 1) makes a PermissionAsk in \(function) — not a user's action")
            }
        }
        XCTAssertGreaterThanOrEqual(made, 3, "the user actions above make theirs — the scan found them")
    }

    func testEveryPromptSitsBehindAPermissionAsk() throws {
        var shown = 0
        for (name, code) in try nonViewSources() {
            for (index, line) in code.enumerated() {
                let shows = prompts.contains { line.contains($0) }
                    || (line.contains("kAXTrustedCheckOptionPrompt") && line.contains(": true"))
                guard shows else { continue }
                shown += 1
                let function = enclosingFunction(of: index, in: code)
                XCTAssertTrue(function?.signature.contains("PermissionAsk") == true,
                              "\(name):\(index + 1) shows a prompt in \(function?.name ?? "?"), which takes no PermissionAsk")
            }
        }
        XCTAssertGreaterThanOrEqual(shown, 6, "the prompts that exist were found: screen, microphone ×2, calendar ×2, Accessibility")
    }

    private let asking = [
        "requestPermission(",            // AudioSource, NotificationService
        "requestRecordPermission(",      // AVAudioApplication
        "requestAccess(for: .audio",     // AVCaptureDevice
        "kAXTrustedCheckOptionPrompt",   // the Accessibility prompt
        "CGRequestScreenCaptureAccess(",
        "requestMicrophone(",            // PermissionsService
        "requestAccessibility(",
        "requestScreenRecording(",
    ]

    /// The lines of a function's body, comments stripped: from its declaration
    /// to the brace that closes it. Braces inside string literals don't count.
    private func body(of declaration: String, in source: String) -> [(number: Int, code: String)] {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else { return [] }
        var depth = 0
        var opened = false
        var out: [(Int, String)] = []
        for index in start..<lines.count {
            let raw = lines[index]
            let code = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
            out.append((index + 1, code))
            var inString = false
            var escaped = false
            for character in code {
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                }
            }
            if opened, depth == 0 { break }
        }
        return out
    }

    func testTheLaunchAsksForNoPermission() throws {
        let source = try String(contentsOf: appDelegate, encoding: .utf8)
        for function in ["func applicationDidFinishLaunching(", "func setupServices()"] {
            let lines = body(of: function, in: source)
            XCTAssertGreaterThan(lines.count, 20, "\(function) not found — update the guard")
            for (number, code) in lines {
                let where_ = "AppDelegate.swift:\(number): \(code.trimmingCharacters(in: .whitespaces))"
                for call in asking {
                    XCTAssertFalse(code.contains(call), "a launch-path prompt — \(where_)")
                }
                if code.contains(".warmUp()") {
                    XCTAssertTrue(code.contains("prepareMicrophoneAtLaunch(warmUp:"),
                                  "the warm-up runs only through the microphone's launch check — \(where_)")
                }
            }
        }
    }
}

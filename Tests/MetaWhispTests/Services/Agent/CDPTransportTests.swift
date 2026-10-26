import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 3.1 — how the agent finds a browser's DevTools port on this Mac
/// (ported from browser-harness, MIT © Browser Use).
final class DevToolsPortLocatorTests: XCTestCase {
    func testReadsThePortAndPathChromeWrites() throws {
        let file = try XCTUnwrap(DevToolsPortLocator.parse(activePort: "9222\n/devtools/browser/9f2c-41\n"))
        XCTAssertEqual(file.port, 9222)
        XCTAssertEqual(file.path, "/devtools/browser/9f2c-41")
    }

    func testRefusesWhatChromeDoesNotWrite() {
        XCTAssertNil(DevToolsPortLocator.parse(activePort: ""))
        XCTAssertNil(DevToolsPortLocator.parse(activePort: "9222"), "no path")
        XCTAssertNil(DevToolsPortLocator.parse(activePort: "port\n/devtools/browser/x"))
        XCTAssertNil(DevToolsPortLocator.parse(activePort: "0\n/devtools/browser/x"))
        XCTAssertNil(DevToolsPortLocator.parse(activePort: "70000\n/devtools/browser/x"))
        XCTAssertNil(DevToolsPortLocator.parse(activePort: "9222\nws://evil.example/devtools/browser/x"),
                     "a path only, on the local port")
        XCTAssertNil(DevToolsPortLocator.parse(activePort: "9222\n/json/version"))
    }

    func testFindsBrowsersInBrowserHarnessOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devtools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ profile: String, _ contents: String) throws {
            let folder = root.appendingPathComponent(profile, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try contents.write(to: folder.appendingPathComponent("DevToolsActivePort"), atomically: true, encoding: .utf8)
        }
        try write("BraveSoftware/Brave-Browser", "9333\n/devtools/browser/brave\n")
        try write("Google/Chrome", "9222\n/devtools/browser/chrome\n")
        try write("Arc/User Data", "garbage")
        let found = DevToolsPortLocator.endpoints(applicationSupport: root)
        XCTAssertEqual(found.map(\.browser), ["Google Chrome", "Brave"], "Chrome first; a broken file is skipped")
        XCTAssertEqual(found.first?.webSocketURL.absoluteString, "ws://127.0.0.1:9222/devtools/browser/chrome")
    }
}

/// ITER-076 3.1 — the JSON the DevTools protocol speaks, as a Sendable value.
final class CDPValueTests: XCTestCase {
    func testRoundTripsWhatTheProtocolSends() throws {
        let text = #"{"id":7,"result":{"product":"HeadlessChrome/153.0","ok":true,"list":[1,2.5,null,"x"]}}"#
        let value = try CDPValue.decode(text)
        XCTAssertEqual(value["id"]?.int, 7)
        XCTAssertEqual(value["result"]?["product"]?.string, "HeadlessChrome/153.0")
        XCTAssertEqual(value["result"]?["ok"]?.bool, true)
        XCTAssertEqual(value["result"]?["list"]?.array?.count, 4)
        XCTAssertEqual(try CDPValue.decode(value.encoded()), value)
    }
}

/// ITER-076 3.1 — a real Chrome, headless, with a profile of its own: the
/// user's Chrome and its profile are never touched. Skipped without Chrome.
final class ChromeConnectionLiveTests: XCTestCase {
    func testConnectsToChromeAndAsksItSomething() async throws {
        let chrome = try await TestChrome.launch()
        defer { chrome.quit() }
        let connection = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await connection.open()
        let version = try await connection.send("Browser.getVersion")
        XCTAssertTrue(version["product"]?.string?.contains("Chrome") == true, "\(version)")
        await connection.close()
    }

    /// A test Chrome ends with the run that started it: a run cut short —
    /// killed, timed out — leaves no browser behind (2026-10-03: headless
    /// Chromes of runs cut short outlived them for up to two days).
    func testATestChromeEndsWithTheRunThatStartedIt() async throws {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sleep")
        run.arguments = ["60"]
        try run.run()
        let chrome = try await TestChrome.launch(diesWith: run.processIdentifier)
        defer { chrome.quit() }
        XCTAssertTrue(chrome.process.isRunning, "the premise")
        run.terminate()
        let deadline = Date().addingTimeInterval(5)
        while chrome.process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(chrome.process.isRunning, "Chrome ended with its run")
    }

    func testAnUnknownMethodIsAnErrorNotASilence() async throws {
        let chrome = try await TestChrome.launch()
        defer { chrome.quit() }
        let connection = CDPConnection(url: chrome.endpoint.webSocketURL)
        try await connection.open()
        do {
            _ = try await connection.send("Nothing.here")
            XCTFail("an unknown method must fail")
        } catch let error as CDPError {
            guard case .protocolError = error else { return XCTFail("\(error)") }
        }
        await connection.close()
    }
}

/// A headless Chrome with a throwaway profile, for tests only.
final class TestChrome {
    static let binary = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

    let process: Process
    let profile: URL
    let endpoint: DevToolsEndpoint

    private init(process: Process, profile: URL, endpoint: DevToolsEndpoint) {
        self.process = process
        self.profile = profile
        self.endpoint = endpoint
    }

    /// Where this Chrome saves a download: a folder of its own profile, never
    /// the user's Downloads (ITER-076 I-09).
    var downloads: URL { profile.appendingPathComponent("Downloads") }

    /// `run`: the process whose end ends this Chrome — the test run itself.
    /// `arguments`: more of Chrome's own switches — a test's host rules
    /// (ITER-076 stage 9e).
    static func launch(diesWith run: pid_t = getpid(), arguments: [String] = []) async throws -> TestChrome {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "needs Google Chrome")
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("metawhisp-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Default"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("Downloads"),
                                                withIntermediateDirectories: true)
        let preferences: [String: Any] = ["download": ["default_directory": profile.appendingPathComponent("Downloads").path,
                                                       "prompt_for_download": false]]
        try JSONSerialization.data(withJSONObject: preferences)
            .write(to: profile.appendingPathComponent("Default/Preferences"))
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--headless=new", "--remote-debugging-port=0", "--user-data-dir=\(profile.path)",
                             "--no-first-run", "--no-default-browser-check", "--disable-extensions"]
            + arguments + ["about:blank"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Chrome ends with the run: a watcher outside the run — it outlives
        // a run that is killed — ends it, and removes its profile, once the
        // run is gone. It ends by itself when Chrome does.
        let chrome = process.processIdentifier
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", "while kill -0 \(run) 2>/dev/null && kill -0 \(chrome) 2>/dev/null; do sleep 1; done; "
                             + "if kill -0 \(chrome) 2>/dev/null; then kill \(chrome); sleep 2; rm -rf \"$0\"; fi", profile.path]
        watcher.standardOutput = FileHandle.nullDevice
        watcher.standardError = FileHandle.nullDevice
        try? watcher.run()
        let file = profile.appendingPathComponent("DevToolsActivePort")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let parsed = DevToolsPortLocator.parse(activePort: text) {
                let endpoint = DevToolsEndpoint(browser: "Test Chrome", port: parsed.port, path: parsed.path)
                return TestChrome(process: process, profile: profile, endpoint: endpoint)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw XCTSkip("Chrome did not open its DevTools port in time")
    }

    func quit() {
        if process.isRunning { process.terminate() }
        // Polled, not `waitUntilExit()`: that waits on the calling thread's
        // run loop, which a Swift concurrency thread never runs — a test that
        // quits from one could wait forever (seen 2026-09-29).
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        try? FileManager.default.removeItem(at: profile)
    }
}

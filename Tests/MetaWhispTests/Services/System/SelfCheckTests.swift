import XCTest
@testable import MetaWhisp

/// ITER-075 step 0, US-0.2 — the release smoke test runs `MetaWhisp --self-check`,
/// which checks the bundle and exits before the app opens any data.
final class SelfCheckTests: XCTestCase {

    // …/Tests/MetaWhispTests/Services/System/SelfCheckTests.swift → repo root
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testEveryCheckPassingExitsZeroAndSaysSo() {
        var lines: [String] = []
        let code = SelfCheck.run([.init(name: "one") { nil }, .init(name: "two") { nil }],
                                 print: { lines.append($0) })
        XCTAssertEqual(code, 0)
        XCTAssertEqual(lines, ["self-check: one ok", "self-check: two ok", "SELF-CHECK OK"])
    }

    func testOneFailingCheckFailsTheRunAndTheOthersStillRun() {
        var lines: [String] = []
        let code = SelfCheck.run([.init(name: "one") { "broken" }, .init(name: "two") { nil }],
                                 print: { lines.append($0) })
        XCTAssertEqual(code, 1)
        XCTAssertEqual(lines, ["self-check: one FAILED — broken", "self-check: two ok", "SELF-CHECK FAILED"])
    }

    /// An empty list would print SELF-CHECK OK and pass; building the list runs nothing.
    func testTheSelfCheckRunsItsThreeChecks() {
        XCTAssertEqual(SelfCheck.defaultChecks(bundle: .main).map(\.name),
                       ["Info.plist", "mlx.metallib", "MLX on the GPU"])
    }

    func testOnlyTheSelfCheckArgumentAsksForIt() {
        XCTAssertTrue(SelfCheck.isRequested(["/Applications/Test.app/Contents/MacOS/Test", "--self-check"]))
        XCTAssertFalse(SelfCheck.isRequested(["/Applications/Test.app/Contents/MacOS/Test"]))
        XCTAssertFalse(SelfCheck.isRequested(["--self-check"]), "the program's own path is not an argument")
    }

    func testTheWorkingAppNeedsItsUpdateFeedAndTheDevAppDoesNot() {
        let production: [String: Any] = ["CFBundleIdentifier": "com.metawhisp.app", "CFBundleShortVersionString": "1.0",
                                         "SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "key"]
        XCTAssertNil(SelfCheck.infoPlistProblem(production))
        var noFeed = production
        noFeed["SUFeedURL"] = nil
        XCTAssertNotNil(SelfCheck.infoPlistProblem(noFeed), "a release without its feed never updates again")
        XCTAssertNil(SelfCheck.infoPlistProblem(["CFBundleIdentifier": "com.metawhisp.app.dev",
                                                 "CFBundleShortVersionString": "1.0"]))
        XCTAssertNotNil(SelfCheck.infoPlistProblem([:]), "a binary outside its bundle fails")
    }

    func testTheShadersMustSitNextToTheExecutable() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("MetaWhisp")
        let metallib = folder.appendingPathComponent("mlx.metallib")
        XCTAssertNotNil(SelfCheck.metallibProblem(executableURL: executable), "missing")
        try Data().write(to: metallib)
        XCTAssertNotNil(SelfCheck.metallibProblem(executableURL: executable), "empty")
        try Data([1, 2, 3]).write(to: metallib)
        XCTAssertNil(SelfCheck.metallibProblem(executableURL: executable))
    }

    /// Without its shaders MLX would end the process and cut the report short,
    /// so the GPU check is skipped, never run.
    func testWithoutItsShadersTheGPUCheckIsSkipped() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = try XCTUnwrap(Bundle(url: folder))
        let gpu = try XCTUnwrap(SelfCheck.defaultChecks(bundle: bundle).last)
        XCTAssertEqual(gpu.run(), "skipped — no mlx.metallib")
    }

    /// The self-check runs before the app exists: `Launch` is the only entry
    /// point, its first statement hands over to the self-check, and neither
    /// file reaches the store, the keychain, the log, the network or the app.
    func testTheEntryPointHandsOverToTheSelfCheckBeforeAnythingElse() throws {
        let launch = try String(contentsOf: root.appendingPathComponent("App/Launch.swift"), encoding: .utf8)
        XCTAssertTrue(launch.contains("@main\n@MainActor\nenum Launch {"), "Launch is the entry point")
        let body = try XCTUnwrap(launch.components(separatedBy: "static func main() {").last)
        let firstStatement = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        XCTAssertEqual(firstStatement, "if SelfCheck.isRequested(CommandLine.arguments) {")
        let check = try XCTUnwrap(launch.range(of: "SelfCheck.runAndExit()"))
        let start = try XCTUnwrap(launch.range(of: "MetaWhispApp.main()"))
        XCTAssertLessThan(check.lowerBound, start.lowerBound)

        var entryPoints: [String] = []
        for folder in ["App", "Services", "Models", "Views", "Helpers"] {
            let base = root.appendingPathComponent(folder)
            let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                if text.contains("@main") { entryPoints.append(folder + "/" + file.lastPathComponent) }
            }
        }
        XCTAssertEqual(entryPoints, ["App/Launch.swift"], "Launch is the only entry point")

        let banned = ["FileLogger", "NSLog", "AppSettings", "UserDefaults", "HistoryService", "ModelContainer",
                      "KeychainHelper", "KeychainBackend", "LicenseService", "SecItem", "URLSession",
                      "AppIdentity.current", "supportDirectory", "NSApp", "AppDelegate", ".shared"]
        for file in ["App/Launch.swift", "Services/System/SelfCheck.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(file) mentions \(word)")
            }
        }
    }

    /// End to end: the app these tests were built with, started with
    /// `--self-check`, reports its checks, exits by itself and writes nothing
    /// to its home. It runs outside a bundle here, so it has the Dev identity
    /// and a throwaway home: even a broken entry point can't reach the owner's
    /// data. Its checks fail here (no bundle, no shaders); that is expected.
    func testTheBuiltAppChecksItselfAndLeavesNothingBehind() throws {
        let products = Bundle(for: SelfCheckTests.self).bundleURL.deletingLastPathComponent()
        let executable = products.appendingPathComponent("MetaWhisp")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return XCTFail("the app is not built next to the tests: \(executable.path)")
        }
        let home = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: home) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--self-check"]
        process.currentDirectoryURL = home
        // A minimal environment: a throwaway home and nothing from the test runner.
        process.environment = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        if !waitForExit(process, seconds: 20) {
            XCTFail("the self-check did not exit by itself within 20 s")
            // A broken entry point starts the whole app, whose quit a dialog can
            // hold up; this test's own child is stopped for sure before reading.
            process.terminate()
            if !waitForExit(process, seconds: 5) {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for name in ["Info.plist", "mlx.metallib", "MLX on the GPU"] {
            XCTAssertTrue(output.contains("self-check: \(name) "), output)
        }
        XCTAssertTrue(output.contains("SELF-CHECK "), "a verdict line")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [],
                       "nothing written to its home")
    }

    private func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !process.isRunning
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mw-self-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

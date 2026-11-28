import XCTest
@testable import MetaWhisp
@testable import MetaWhispTrackerKit

/// FEAT-0006 §7 — the local socket between the command-line tool and the app: one request, one answer; bad input
/// never stops the server; a missing app is started once and waited for, with a ceiling.
final class TrackerSocketTests: XCTestCase {

    private var path: String!
    private var server: TrackerSocketServer?

    override func setUp() {
        // sun_path holds 104 bytes: keep test sockets short.
        path = "/tmp/mwt-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    private func startServer(queue: DispatchQueue = DispatchQueue(label: "test-app"),
                             _ handler: @escaping @Sendable (TrackerRequest) -> TrackerResponse = { request in
        .success("echo \(request.op) \(request.folder ?? "-")")
    }) throws {
        let s = TrackerSocketServer(path: path, queue: queue, handler: handler)
        try s.start()
        server = s
    }

    func testOneRequestGetsOneAnswer() throws {
        try startServer()
        let reply = try TrackerClient.send(TrackerRequest(op: "ping", folder: "/x/Acme", client: "test"),
                                           socketPath: path, timeout: 5)
        XCTAssertEqual(reply, .success("echo ping /x/Acme"))
        let again = try TrackerClient.send(TrackerRequest(op: "task_list", folder: nil, client: nil),
                                           socketPath: path, timeout: 5)
        XCTAssertEqual(again.text, "echo task_list -")
    }

    func testTheSocketIsTheOwnersOnly() throws {
        try startServer()
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testGarbageAndOversizedLinesAreRefusedAndTheServerKeepsServing() throws {
        try startServer()
        XCTAssertEqual(try TrackerClient.sendRaw(Data("not json\n".utf8), socketPath: path, timeout: 5).code, .validation)
        var huge = Data(repeating: 0x61, count: TrackerWire.maxBytes + 10)
        huge.append(0x0A)
        XCTAssertEqual(try TrackerClient.sendRaw(huge, socketPath: path, timeout: 5).code, .validation)
        XCTAssertTrue(try TrackerClient.send(TrackerRequest(op: "ping", folder: nil, client: nil),
                                             socketPath: path, timeout: 5).ok)
    }

    func testNoServerIsReportedAsNotRunning() {
        XCTAssertThrowsError(try TrackerClient.send(TrackerRequest(op: "ping", folder: nil, client: nil),
                                                    socketPath: path, timeout: 2)) { error in
            XCTAssertEqual(error as? TrackerClient.ConnectError, .notRunning)
        }
    }

    func testAStaleSocketFileIsReplaced() throws {
        FileManager.default.createFile(atPath: path, contents: Data("old".utf8))
        try startServer()
        XCTAssertTrue(try TrackerClient.send(TrackerRequest(op: "ping", folder: nil, client: nil),
                                             socketPath: path, timeout: 5).ok)
    }

    func testAMissingAppIsStartedOnceAndWaitedFor() throws {
        var launches = 0
        let reply = TrackerClient.sendLaunching(TrackerRequest(op: "ping", folder: nil, client: nil),
                                                socketPath: path, wait: 10, poll: 0.05) {
            launches += 1
            try self.startServer()
        }
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(reply.ok, reply.message ?? "")
    }

    func testAnAppThatNeverAnswersStopsAtTheCeiling() {
        let started = Date()
        let reply = TrackerClient.sendLaunching(TrackerRequest(op: "ping", folder: nil, client: nil),
                                                socketPath: path, wait: 0.5, poll: 0.05) {}
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.code, .appUnavailable)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testALaunchThatFailsIsSaidAtOnce() {
        struct NotInstalled: Error, CustomStringConvertible { var description: String { "not installed" } }
        let reply = TrackerClient.sendLaunching(TrackerRequest(op: "ping", folder: nil, client: nil),
                                                socketPath: path, wait: 10, poll: 0.05) { throw NotInstalled() }
        XCTAssertEqual(reply.code, .appUnavailable)
        XCTAssertTrue(reply.message?.contains("not installed") == true)
    }

    /// Review P2-4: "busy, try again" means the request never runs — a retry cannot make a second task.
    func testABusyAnswerNeverRunsLater() throws {
        let queue = DispatchQueue(label: "busy-app")
        let ran = Counter()
        let s = TrackerSocketServer(path: path, queue: queue, claimTimeout: 0.3) { _ in
            ran.add()
            return .success("ran")
        }
        try s.start()
        server = s
        queue.suspend()
        let reply = try TrackerClient.send(TrackerRequest(op: "task_create", folder: nil, client: nil),
                                           socketPath: path, timeout: 5)
        XCTAssertEqual(reply.code, .internalError)
        XCTAssertTrue(reply.message?.contains("busy") == true)
        queue.resume()
        queue.sync {}
        XCTAssertEqual(ran.value, 0, "the refused request did not run after all")
        XCTAssertEqual(try TrackerClient.send(TrackerRequest(op: "ping", folder: nil, client: nil),
                                              socketPath: path, timeout: 5).text, "ran")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func testTheServerAnswersFromTheMainActor() throws {
        try startServer(queue: .main) { _ in
            MainActor.assumeIsolated { .success(Thread.isMainThread ? "main" : "elsewhere") }
        }
        // The real client is another process; here it runs off the main thread so the main actor stays free.
        let answered = expectation(description: "answered")
        let socket = path!
        var text: String?
        DispatchQueue.global().async {
            text = try? TrackerClient.send(TrackerRequest(op: "ping", folder: nil, client: nil),
                                           socketPath: socket, timeout: 5).text
            answered.fulfill()
        }
        wait(for: [answered], timeout: 10)
        XCTAssertEqual(text, "main")
    }
}

import Foundation
import XCTest
@testable import MetaWhisp

/// ITER-076 3.1 — the WebSocket framing the DevTools connection speaks
/// (RFC 6455), checked against the standard's own examples.
final class WebSocketFrameTests: XCTestCase {
    /// RFC 6455 §1.3.
    func testTheHandshakeProofIsTheOneTheStandardGives() {
        XCTAssertEqual(WebSocketFrame.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    /// RFC 6455 §5.7: a single-frame masked text message, "Hello".
    func testWhatTheAppSendsIsMaskedAsTheStandardShows() {
        let frame = WebSocketFrame.encode(.text, payload: Data("Hello".utf8), mask: [0x37, 0xFA, 0x21, 0x3D])
        XCTAssertEqual([UInt8](frame), [0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D, 0x7F, 0x9F, 0x4D, 0x51, 0x58])
    }

    func testLongerMessagesCarryTheirLengthAsTheStandardSays() {
        let mask: [UInt8] = [1, 2, 3, 4]
        let medium = [UInt8](WebSocketFrame.encode(.text, payload: Data(count: 256), mask: mask))
        XCTAssertEqual(Array(medium[0..<4]), [0x81, 0xFE, 0x01, 0x00], "16-bit length")
        XCTAssertEqual(medium.count, 4 + 4 + 256)
        let long = [UInt8](WebSocketFrame.encode(.text, payload: Data(count: 65_536), mask: mask))
        XCTAssertEqual(Array(long[0..<10]), [0x81, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0], "64-bit length")
        XCTAssertEqual(long.count, 10 + 4 + 65_536)
    }

    /// RFC 6455 §5.7: an unmasked text message, a fragmented one, a ping, and
    /// messages long enough for both longer lengths — read one byte at a time,
    /// as the network may hand them over.
    func testReadsWhatTheBrowserSendsInPiecesOfAnySize() throws {
        var bytes: [UInt8] = [0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F]
        bytes += [0x01, 0x03, 0x48, 0x65, 0x6C, 0x80, 0x02, 0x6C, 0x6F]
        bytes += [0x89, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F]
        bytes += [0x81, 0x7E, 0x01, 0x00] + [UInt8](repeating: 0x61, count: 256)
        bytes += [0x81, 0x7F, 0, 0, 0, 0, 0, 1, 0, 0] + [UInt8](repeating: 0x62, count: 65_536)
        bytes += [0x88, 0x00]
        var reader = WebSocketReader(limit: 1 << 20)
        var events: [WebSocketReader.Event] = []
        for byte in bytes { events += try reader.read(Data([byte])) }
        XCTAssertEqual(events, [
            .message(Data("Hello".utf8)), .message(Data("Hello".utf8)), .ping(Data("Hello".utf8)),
            .message(Data(repeating: 0x61, count: 256)), .message(Data(repeating: 0x62, count: 65_536)), .close,
        ])
    }

    func testReadsSeveralFramesThatArriveTogether() throws {
        var reader = WebSocketReader(limit: 1 << 20)
        let events = try reader.read(Data([0x81, 0x01, 0x41, 0x81, 0x01, 0x42, 0x81]))
        XCTAssertEqual(events, [.message(Data("A".utf8)), .message(Data("B".utf8))], "the third waits for the rest")
        XCTAssertEqual(try reader.read(Data([0x01, 0x43])), [.message(Data("C".utf8))])
    }

    /// What the standard forbids a server to send ends the connection.
    func testRefusesWhatABrowserMustNotSend() {
        func refuses(_ bytes: [UInt8], limit: Int = 1 << 20, _ why: String) {
            var reader = WebSocketReader(limit: limit)
            XCTAssertThrowsError(try reader.read(Data(bytes)), why)
        }
        refuses([0x81, 0x81, 1, 2, 3, 4, 0x40], "a masked frame from the server")
        refuses([0xC1, 0x01, 0x41], "an extension bit nobody agreed on")
        refuses([0x80, 0x01, 0x41], "a continuation with nothing to continue")
        refuses([0x01, 0x01, 0x41, 0x81, 0x01, 0x42], "a new message inside another")
        refuses([0x09, 0x00], "a ping split in pieces")
        refuses([0x83, 0x00], "an opcode the standard does not define")
    }

    /// Review of 3.1 (P1-3): a message over the limit is passed over — its
    /// bytes read and dropped as they come, never kept — and the connection
    /// goes on: a page cannot end it with one big answer.
    func testAMessageOverTheLimitIsPassedOverAndTheNextIsRead() throws {
        var bytes: [UInt8] = [0x81, 0x05, 0x48, 0x65, 0x6C, 0x6C, 0x6F]
        bytes += [0x81, 0x01, 0x41]
        bytes += [0x01, 0x03, 0x48, 0x65, 0x6C, 0x89, 0x00, 0x80, 0x02, 0x6C, 0x6F]
        bytes += [0x81, 0x01, 0x42]
        var reader = WebSocketReader(limit: 4)
        var events: [WebSocketReader.Event] = []
        for byte in bytes { events += try reader.read(Data([byte])) }
        XCTAssertEqual(events, [.dropped, .message(Data("A".utf8)), .ping(Data()), .dropped, .message(Data("B".utf8))])
    }

    /// RFC 6455 §5.4: a control frame may come between the pieces of a message.
    func testAPingBetweenThePiecesOfAMessageIsRead() throws {
        var reader = WebSocketReader(limit: 1 << 20)
        let events = try reader.read(Data([0x01, 0x03, 0x48, 0x65, 0x6C, 0x89, 0x01, 0x21, 0x80, 0x02, 0x6C, 0x6F]))
        XCTAssertEqual(events, [.ping(Data("!".utf8)), .message(Data("Hello".utf8))])
    }
}

/// ITER-076 3.1 — Chrome asks the user to Allow each new connection, so the
/// socket opens one connection per attempt and never tries again on its own.
final class CDPSocketLiveTests: XCTestCase {
    /// A browser that ends the handshake — the user said no, or its question
    /// was closed — ends the attempt at once, on the one connection it made.
    func testAHandshakeTheBrowserEndsIsNotTriedAgain() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let connection = CDPConnection(url: URL(string: "ws://127.0.0.1:\(port.port)/devtools/browser/held")!)
        let started = ContinuousClock.now
        let attempt = Task { try await connection.open(allowLimit: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(500))
        port.decline()
        do {
            try await attempt.value
            XCTFail("never opened")
        } catch let error as CDPError {
            guard case .closed = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3), "ended when the browser ended it")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(port.connections, 1, "one connection, one question to the user")
    }

    /// A browser that ends its side of the connection and keeps it open ends
    /// the attempt too, at once and said as such: nothing more can come. (The
    /// next read would fail anyway, one round later, as "No message available
    /// on STREAM".)
    func testABrowserThatHangsUpEndsTheAttempt() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let connection = CDPConnection(url: URL(string: "ws://127.0.0.1:\(port.port)/devtools/browser/held")!)
        let started = ContinuousClock.now
        let attempt = Task { try await connection.open(allowLimit: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(500))
        port.hangUp()
        do {
            try await attempt.value
            XCTFail("never opened")
        } catch let error as CDPError {
            XCTAssertEqual(error, .closed("closed by the browser"))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3), "ended when the browser hung up")
        XCTAssertEqual(port.connections, 1)
    }

    /// An answer that refuses the connection — as a browser may answer a No —
    /// ends the attempt at once.
    func testARefusalEndsTheAttempt() async throws {
        let port = try await HeldPort.start(answering: "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
        defer { port.stop() }
        try await assertRefused(port)
    }

    /// A switch of protocols without the proof for this connection's key is
    /// not a WebSocket this socket asked for.
    func testAnAnswerForAnotherKeyIsRefused() async throws {
        let port = try await HeldPort.start(answering: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n")
        defer { port.stop() }
        try await assertRefused(port)
    }

    private func assertRefused(_ port: HeldPort, file: StaticString = #filePath, line: UInt = #line) async throws {
        let connection = CDPConnection(url: URL(string: "ws://127.0.0.1:\(port.port)/devtools/browser/held")!)
        let started = ContinuousClock.now
        do {
            try await connection.open(allowLimit: .seconds(30))
            XCTFail("never opened", file: file, line: line)
        } catch let error as CDPError {
            guard case .closed = error else { return XCTFail("\(error)", file: file, line: line) }
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3), file: file, line: line)
        XCTAssertEqual(port.connections, 1, file: file, line: line)
    }

    /// A port nothing listens on — a file a closed browser left — fails at
    /// once, is not waited on, and says so: no browser was reached.
    func testAPortNothingListensOnFailsAtOnce() async throws {
        let connection = CDPConnection(url: URL(string: "ws://127.0.0.1:1/devtools/browser/gone")!)
        let started = ContinuousClock.now
        do {
            try await connection.open(allowLimit: .seconds(30))
            XCTFail("never opened")
        } catch let error as CDPError {
            guard case .unreachable = error else { return XCTFail("\(error)") }
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }
}

/// Review of 3.1 — what a connection sends and keeps when its caller stops,
/// on a port that speaks as a browser does. Stop means nothing more reaches a
/// page, and nothing is left waiting.
final class CDPConnectionStopTests: XCTestCase {
    private func opened(replying: Bool = false) async throws -> (HeldPort, CDPConnection) {
        let port = try await HeldPort.start(speaking: true, replying: replying)
        let connection = CDPConnection(url: URL(string: "ws://127.0.0.1:\(port.port)/devtools/browser/fake")!)
        try await connection.open()
        return (port, connection)
    }

    private func methods(_ port: HeldPort) -> [String] {
        port.messages.compactMap { (try? CDPValue.decode($0))?["method"]?.string }
    }

    /// A caller already stopped sends nothing.
    func testAStoppedCallerSendsNothing() async throws {
        let (port, connection) = try await opened(replying: true)
        defer { port.stop() }
        let call = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await connection.send("Input.insertText", params: ["text": "late"])
        }
        do {
            _ = try await call.value
            XCTFail("never sent")
        } catch let error as CDPError {
            XCTAssertEqual(error, .cancelled)
        }
        _ = try await connection.send("Browser.getVersion")
        XCTAssertEqual(methods(port), ["Browser.getVersion"], "nothing after Stop")
    }

    /// ITER-076 I-05, review round 1 (P1-1): a call whose caller stops after
    /// it went out is abandoned, not cancelled — the browser may carry it
    /// out — and one stopped before it went out is cancelled.
    func testACallStoppedAfterItWentOutIsAbandonedNotCancelled() async throws {
        let (port, connection) = try await opened()
        defer { port.stop() }
        let call = Task { try await connection.send("Input.insertText", params: ["text": "late"]) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !port.messages.contains(where: { $0.contains("Input.insertText") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        call.cancel()
        do {
            _ = try await call.value
            XCTFail("never answered")
        } catch let error as CDPError {
            XCTAssertEqual(error, .abandoned)
        }
    }

    /// A call whose caller stops while it waits leaves nothing waiting.
    func testACallStoppedWhileWaitingLeavesNothingInFlight() async throws {
        let (port, connection) = try await opened()
        defer { port.stop() }
        let call = Task { try await connection.send("Browser.getVersion") }
        try await Task.sleep(for: .milliseconds(200))
        call.cancel()
        _ = try? await call.value
        try await Task.sleep(for: .milliseconds(50))
        let inFlight = await connection.inFlight
        XCTAssertEqual(inFlight, 0)
    }

    /// A call the browser never answers fails at its limit, and is forgotten.
    func testACallTheBrowserNeverAnswersTimesOut() async throws {
        let (port, connection) = try await opened()
        defer { port.stop() }
        do {
            _ = try await connection.send("Browser.getVersion", timeout: .milliseconds(300))
            XCTFail("never answered")
        } catch let error as CDPError {
            XCTAssertEqual(error, .timedOut(method: "Browser.getVersion"))
        }
        let inFlight = await connection.inFlight
        XCTAssertEqual(inFlight, 0)
    }

    /// An open stopped while the browser asks the user ends as stopped — not
    /// as a No the user never gave.
    func testAnOpenStoppedWhileTheBrowserAsksIsStoppedNotRefused() async throws {
        let port = try await HeldPort.start()
        defer { port.stop() }
        let connection = CDPConnection(url: URL(string: "ws://127.0.0.1:\(port.port)/devtools/browser/held")!)
        let attempt = Task { try await connection.open(allowLimit: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(300))
        attempt.cancel()
        do {
            try await attempt.value
            XCTFail("never opened")
        } catch let error as CDPError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    /// Stop never splits a click: a click not yet begun is not begun, and a
    /// press is always followed by its release.
    @MainActor
    func testStopNeverSplitsAClick() async throws {
        let (port, connection) = try await opened(replying: true)
        defer { port.stop() }
        let bridge = ChromeBridge(connection: connection)
        let tab = BrowserTab(windowID: "target", tabID: "session")
        let early = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await bridge.click(x: 10, y: 10, in: tab)
        }
        _ = try? await early.value
        XCTAssertFalse(methods(port).contains("Input.dispatchMouseEvent"), "a click not begun is not begun")
        let running = TaskHolder()
        port.onMessage = { message in
            if message.contains("mousePressed") { running.cancel() }
        }
        let click = Task { @MainActor in try await bridge.click(x: 10, y: 10, in: tab) }
        running.hold(click)
        _ = try? await click.value
        // The stopped caller is back at once; the click finishes alone.
        let deadline = ContinuousClock.now + .seconds(2)
        while !port.messages.contains(where: { $0.contains("mouseReleased") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let presses = port.messages.filter { $0.contains("Input.dispatchMouseEvent") }
        XCTAssertEqual(presses.count, 2, "the release follows the press")
        XCTAssertTrue(presses.last?.contains("mouseReleased") == true)
    }
}

/// Review of 3.1, round 2 — Stop and a lost connection, without Chrome.
final class ChromeBridgeStopTests: XCTestCase {
    /// Stop is not held up by a page slow to take a click: the caller gets
    /// back at once, and the click begun is finished alone, its release sent.
    @MainActor
    func testStopIsNotHeldUpByAPageSlowToTakeAClick() async throws {
        let port = try await HeldPort.start(speaking: true, replying: true, slowOn: "mousePressed", by: 2)
        defer { port.stop() }
        let connection = CDPConnection(url: URL(string: "ws://127.0.0.1:\(port.port)/devtools/browser/fake")!)
        try await connection.open()
        let bridge = ChromeBridge(connection: connection)
        let click = Task { @MainActor in
            try await bridge.click(x: 10, y: 10, in: BrowserTab(windowID: "target", tabID: "session"))
        }
        try await Task.sleep(for: .milliseconds(200))
        let stopped = ContinuousClock.now
        click.cancel()
        _ = try? await click.value
        XCTAssertLessThan(ContinuousClock.now - stopped, .milliseconds(500), "Stop gets back at once")
        let deadline = ContinuousClock.now + .seconds(4)
        while !port.messages.contains(where: { $0.contains("mouseReleased") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(port.messages.contains { $0.contains("mouseReleased") }, "the release follows its press")
    }

    /// ITER-076 I-05, review round 1 (P1-1): a click stopped once its press
    /// went out says it may have happened; one stopped before it began says
    /// nothing was sent. So does a script stopped after it went out.
    @MainActor
    func testAnInputStoppedAfterItWentOutIsInterruptedNotCancelled() async throws {
        let port = try await HeldPort.start(speaking: true, replying: true, slowOn: "mousePressed", by: 2)
        defer { port.stop() }
        let connection = CDPConnection(url: URL(string: "ws://127.0.0.1:\(port.port)/devtools/browser/fake")!)
        try await connection.open()
        let bridge = ChromeBridge(connection: connection)
        let tab = BrowserTab(windowID: "target", tabID: "session")

        let early = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await bridge.click(x: 10, y: 10, in: tab)
        }
        do {
            try await early.value
            XCTFail("never begun")
        } catch {
            XCTAssertTrue(error is CancellationError, "not begun: \(error)")
        }

        let click = Task { @MainActor in try await bridge.click(x: 10, y: 10, in: tab) }
        let deadline = ContinuousClock.now + .seconds(2)
        while !port.messages.contains(where: { $0.contains("mousePressed") }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        click.cancel()
        do {
            try await click.value
            XCTFail("stopped")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .interrupted, "the press went out: \(error)")
        }

        // A script on a port that never answers: stopped once it went out.
        let silent = try await HeldPort.start(speaking: true)
        defer { silent.stop() }
        let quiet = CDPConnection(url: URL(string: "ws://127.0.0.1:\(silent.port)/devtools/browser/fake")!)
        try await quiet.open()
        let reader = ChromeBridge(connection: quiet)
        let script = Task { @MainActor in try await reader.runInPage("document.title", in: tab) }
        let sent = ContinuousClock.now + .seconds(2)
        while !silent.messages.contains(where: { $0.contains("Runtime.evaluate") }), ContinuousClock.now < sent {
            try await Task.sleep(for: .milliseconds(10))
        }
        script.cancel()
        do {
            _ = try await script.value
            XCTFail("never answered")
        } catch {
            XCTAssertEqual(error as? BrowserBridgeError, .interrupted, "the script went out: \(error)")
        }
    }

    /// A lost connection is not a page still loading: waiting on it ends at
    /// once, not at its limit.
    @MainActor
    func testALostConnectionIsNotAPageStillLoading() async throws {
        let bridge = ChromeBridge(connection: CDPConnection(url: URL(string: "ws://127.0.0.1:1/devtools/browser/gone")!))
        do {
            _ = try await bridge.isLoading(BrowserTab(windowID: "target", tabID: "session"))
            XCTFail("a lost connection is an error")
        } catch {}
    }

    /// ITER-076 I-05: a lost connection says so, apart from a script that
    /// failed — the one bridge failure that ends an errand.
    @MainActor
    func testALostConnectionSaysSo() async throws {
        let bridge = ChromeBridge(connection: CDPConnection(url: URL(string: "ws://127.0.0.1:1/devtools/browser/gone")!))
        let tab = BrowserTab(windowID: "target", tabID: "session")
        for call in ["run", "isLoading"] {
            do {
                _ = call == "run" ? try await bridge.run("document.title", in: tab)
                    : String(try await bridge.isLoading(tab))
                XCTFail("\(call): a lost connection is an error")
            } catch {
                XCTAssertEqual(error as? BrowserBridgeError, .connectionLost, call)
            }
        }
    }
}

/// A task to cancel from another thread.
final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Error>?
    private var cancelled = false

    func hold(_ task: Task<Void, Error>) {
        lock.lock()
        self.task = task
        let early = cancelled
        lock.unlock()
        if early { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

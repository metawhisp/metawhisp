import Foundation

/// What can go wrong on a DevTools connection (ITER-076 3.1).
enum CDPError: Error, Equatable {
    /// `send` before `open`, or after the connection ended.
    case notOpen
    /// Nothing answered on the port: no browser listens there — a file a
    /// closed browser left behind.
    case unreachable(String)
    /// The browser was reached, and the connection ended — before it opened,
    /// or after; the reason is the system's.
    case closed(String)
    /// The user did not click Allow in Chrome within the limit.
    case allowTimedOut
    /// A method got no reply in time.
    case timedOut(method: String)
    /// Chrome answered with an error.
    case protocolError(code: Int, message: String)
    /// The caller stopped before the call went out: nothing was sent.
    case cancelled
    /// The caller stopped after the call went out (ITER-076 I-05): the
    /// browser may carry it out.
    case abandoned
}

/// An event Chrome sent on its own (a method with no id).
struct CDPEvent: Sendable, Equatable {
    let method: String
    let params: CDPValue
    let sessionID: String?
}

/// One WebSocket connection to a browser's DevTools endpoint (ITER-076 3.1),
/// ported from browser-harness's daemon (MIT © Browser Use): requests carry an
/// id and optionally a target's session, replies are matched by id, events are
/// passed to listeners. It runs off the main thread.
///
/// Chrome 144+ holds a new connection to the user's own browser until the
/// user clicks Allow in Chrome, and the connection that asked is the only thing
/// keeping that dialog up — so the app keeps one connection alive and waits for
/// the Allow, up to a limit, never clicking it itself.
actor CDPConnection {
    enum State: Equatable {
        case idle
        case opening
        /// Not open after a moment: Chrome is most likely asking the user.
        case waitingForAllow
        case open
        case closed
    }

    /// Runs before a call is handed to the socket, given its method. Tests
    /// use it to hold a call there; the app passes nothing.
    typealias WriteHook = @Sendable (_ method: String) async -> Void
    /// Runs on the socket's queue, in the turn that makes a call's message
    /// and hands it to the connection, before the message is made, given
    /// its method. Tests use it to hold the queue there (Codex review 3 of
    /// I-09, P2-2); the app passes nothing.
    typealias QueueHook = @Sendable (_ method: String) -> Void

    let url: URL
    private(set) var state: State = .idle
    private var socket: CDPSocket?
    private var receiver: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CDPReply] = [:]
    private var listeners: [UUID: AsyncStream<CDPEvent>.Continuation] = [:]
    private let beforeWrite: WriteHook?
    private let onTheSocketQueue: QueueHook?

    /// Observer reports can be large; the system default is 1 MB.
    static let maximumMessageSize = 64 << 20

    init(url: URL, beforeWrite: WriteHook? = nil, onTheSocketQueue: QueueHook? = nil) {
        self.url = url
        self.beforeWrite = beforeWrite
        self.onTheSocketQueue = onTheSocketQueue
    }

    /// Opens the socket. When it is not open after `waitingAfter`, the state
    /// becomes `.waitingForAllow` and `onWaiting` is told once; at
    /// `allowLimit` the wait ends in `.allowTimedOut`, and a caller that stops
    /// waiting ends it in `.cancelled` — never a No the user did not give.
    func open(allowLimit: Duration = .seconds(600), waitingAfter: Duration = .seconds(1),
              onWaiting: (@Sendable () -> Void)? = nil) async throws {
        guard state == .idle else { throw CDPError.notOpen }
        state = .opening
        // One connection, never tried again on its own: Chrome asks the user
        // about each one (`CDPSocket`).
        guard let socket = CDPSocket(url: url, maximumMessageSize: Self.maximumMessageSize) else {
            state = .closed
            throw CDPError.closed("not a DevTools address")
        }
        self.socket = socket
        socket.start()

        let notice = Task { [weak self] in
            try? await Task.sleep(for: waitingAfter)
            guard !Task.isCancelled else { return }
            if await self?.markWaiting() == true { onWaiting?() }
        }
        let result = await Deadline.run(within: allowLimit) { await socket.waitUntilOpen() }
        notice.cancel()
        switch result {
        case .success?:
            // Closed while the handshake finished: not open.
            guard state != .closed else { throw CDPError.closed("closed while opening") }
            state = .open
            startReceiving(socket)
        case .failure(let error)?:
            shutDown(with: error)
            throw error
        case nil:
            let error: CDPError = Task.isCancelled ? .cancelled : .allowTimedOut
            shutDown(with: error)
            throw error
        }
    }

    /// Sends `method` and waits for its reply's `result`, up to `timeout`. A
    /// caller already stopped sends nothing — `.cancelled`: Stop means nothing
    /// more reaches a page (review of 3.1). One that stops once the call went
    /// out leaves nothing waiting, and gets `.abandoned`: the browser may
    /// still carry the call out (ITER-076 I-05). `atTheWire`, when given,
    /// makes the call's parameters in place of `params`, in the very turn
    /// that hands the call to the socket — the last step before the wire,
    /// with nothing between what it decides and the send (Codex review 2 of
    /// I-09, P1-5).
    func send(_ method: String, params: CDPValue = [:], sessionID: String? = nil,
              timeout: Duration = .seconds(30),
              atTheWire: (@Sendable () -> CDPValue)? = nil) async throws -> CDPValue {
        if let beforeWrite { await beforeWrite(method) }
        guard !Task.isCancelled else { throw CDPError.cancelled }
        guard state == .open, let socket else { throw CDPError.notOpen }
        nextID += 1
        let id = nextID
        let compose = { @Sendable () -> String? in
            try? Self.encoded(id: id, method: method, params: atTheWire?() ?? params, sessionID: sessionID)
        }
        // A call whose parameters are given is written now: one that cannot
        // be is refused before anything is sent, as before.
        let text = atTheWire == nil ? try Self.encoded(id: id, method: method, params: params, sessionID: sessionID)
            : nil
        let reply = CDPReply()
        pending[id] = reply
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expire(id, method: method)
        }
        defer { timer.cancel() }
        let held = onTheSocketQueue.map { hook in { @Sendable in hook(method) } }
        do {
            if let text {
                try await socket.send(text, held: held)
            } else {
                try await socket.send(composing: compose, held: held)
            }
        } catch {
            pending[id] = nil
            throw CDPError.closed(error.localizedDescription)
        }
        return try await withTaskCancellationHandler {
            try await reply.wait()
        } onCancel: { [weak self] in
            reply.resolve(.failure(.abandoned))
            Task { await self?.forget(id) }
        }
    }

    /// A call as its message's text.
    private static func encoded(id: Int, method: String, params: CDPValue, sessionID: String?) throws -> String {
        var message: [String: CDPValue] = ["id": .number(Double(id)), "method": .string(method), "params": params]
        if let sessionID { message["sessionId"] = .string(sessionID) }
        return try CDPValue.object(message).encoded()
    }

    /// Calls sent and not yet answered, failed or given up.
    var inFlight: Int { pending.count }

    /// Listeners of events still attached: each leaves when its stream ends.
    var listening: Int { listeners.count }

    /// Every event from now on, until the connection ends.
    func events() -> AsyncStream<CDPEvent> {
        let (stream, continuation) = AsyncStream<CDPEvent>.makeStream()
        guard state != .closed else {
            continuation.finish()
            return stream
        }
        let id = UUID()
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    func close() {
        shutDown(with: .closed("closed by the app"))
    }

    // MARK: - Private

    private func markWaiting() -> Bool {
        guard state == .opening else { return false }
        state = .waitingForAllow
        return true
    }

    private func startReceiving(_ socket: CDPSocket) {
        receiver = Task { [weak self] in
            do {
                for try await text in socket.messages { await self?.handle(text) }
                await self?.fail(with: .closed("ended"))
            } catch {
                await self?.fail(with: (error as? CDPError) ?? .closed(error.localizedDescription))
            }
        }
    }

    private func handle(_ text: String) {
        guard let message = try? CDPValue.decode(text) else { return }
        if let id = message["id"]?.int {
            guard let reply = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] {
                reply.resolve(.failure(.protocolError(code: error["code"]?.int ?? 0,
                                                      message: error["message"]?.string ?? "")))
            } else {
                reply.resolve(.success(message["result"] ?? [:]))
            }
        } else if let method = message["method"]?.string {
            let event = CDPEvent(method: method, params: message["params"] ?? [:],
                                 sessionID: message["sessionId"]?.string)
            for listener in listeners.values { listener.yield(event) }
        }
    }

    private func expire(_ id: Int, method: String) {
        pending.removeValue(forKey: id)?.resolve(.failure(.timedOut(method: method)))
    }

    private func forget(_ id: Int) {
        pending[id] = nil
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    private func fail(with error: CDPError) {
        shutDown(with: error)
    }

    private func shutDown(with error: CDPError) {
        guard state != .closed else { return }
        state = .closed
        receiver?.cancel()
        receiver = nil
        socket?.close()
        socket = nil
        let waiting = pending.values
        pending = [:]
        for reply in waiting { reply.resolve(.failure(error)) }
        for listener in listeners.values { listener.finish() }
        listeners = [:]
    }
}

/// One reply, resolved once, awaited once.
final class CDPReply: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CDPValue, CDPError>?
    private var waiter: CheckedContinuation<CDPValue, Error>?

    func resolve(_ outcome: Result<CDPValue, CDPError>) {
        lock.lock()
        guard case .none = result else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(with: outcome.mapError { $0 as Error })
    }

    func wait() async throws -> CDPValue {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result.mapError { $0 as Error })
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Whether the socket opened, resolved once.
final class CDPOpenSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, CDPError>?
    private var waiter: CheckedContinuation<Result<Void, CDPError>, Never>?

    func resolve(_ outcome: Result<Void, CDPError>) {
        lock.lock()
        guard case .none = result else {
            lock.unlock()
            return
        }
        result = outcome
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: outcome)
    }

    func wait() async -> Result<Void, CDPError> {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

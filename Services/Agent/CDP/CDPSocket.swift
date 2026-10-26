import CryptoKit
import Foundation
import Network

/// RFC 6455 framing for a client (ITER-076 3.1): what the app sends is one
/// masked frame per message; what the browser sends is read by
/// `WebSocketReader`.
enum WebSocketFrame {
    enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    /// The proof a server's handshake answer carries (RFC 6455 §1.3, §4.2.2).
    static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    /// One final frame from the client, masked with `mask` (RFC 6455 §5.2, §5.3).
    static func encode(_ opcode: Opcode, payload: Data, mask: [UInt8]) -> Data {
        var frame = Data([0x80 | opcode.rawValue])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(contentsOf: [UInt8(0x80 | 126), UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: stride(from: 56, through: 0, by: -8).map { UInt8((UInt64(count) >> UInt64($0)) & 0xFF) })
        }
        frame.append(contentsOf: mask)
        var masked = [UInt8](payload)
        for index in masked.indices { masked[index] ^= mask[index & 3] }
        frame.append(contentsOf: masked)
        return frame
    }
}

/// What the browser sends, read as it arrives — in pieces of any size, several
/// frames at once — and put back together into whole messages (RFC 6455 §5).
/// Anything the standard forbids a server to send is an error: the connection
/// ends. A message over `limit` is passed over — its bytes read and dropped as
/// they come, never kept — and the connection goes on, so a page cannot end
/// the one connection to the user's browser with one big answer (review of
/// 3.1, P1-3); the call it answered runs out of time.
struct WebSocketReader {
    enum Event: Equatable {
        case message(Data)
        case ping(Data)
        case close
        /// A message over the limit was passed over.
        case dropped
    }

    let limit: Int
    private var buffer: [UInt8] = []
    /// A message whose first pieces have come, and not its last.
    private var pieces: [UInt8]?
    /// Bytes of a frame being passed over, still to come.
    private var skipping: UInt64 = 0
    /// Whether the pieces still to come belong to a message passed over.
    private var droppingPieces = false

    init(limit: Int) {
        self.limit = limit
    }

    /// Takes the bytes that arrived, and returns every event they complete.
    mutating func read(_ bytes: Data) throws -> [Event] {
        buffer.append(contentsOf: bytes)
        var events: [Event] = []
        while let event = try nextFrame() {
            if let event { events.append(event) }
        }
        return events
    }

    /// Nil when the next frame has not fully arrived; `.some(nil)` for a frame
    /// that completes no event (a pong, or a piece of a message).
    private mutating func nextFrame() throws -> Event?? {
        if skipping > 0 {
            skip()
            guard skipping == 0 else { return nil }
        }
        guard buffer.count >= 2 else { return nil }
        let final = buffer[0] & 0x80 != 0
        guard buffer[0] & 0x70 == 0 else { throw CDPError.closed("an extension nobody agreed on") }
        guard let opcode = WebSocketFrame.Opcode(rawValue: buffer[0] & 0x0F) else {
            throw CDPError.closed("an unknown frame")
        }
        guard buffer[1] & 0x80 == 0 else { throw CDPError.closed("a masked frame from the browser") }
        var header = 2
        var length = UInt64(buffer[1] & 0x7F)
        if length == 126 {
            guard buffer.count >= 4 else { return nil }
            length = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
            header = 4
        } else if length == 127 {
            guard buffer.count >= 10 else { return nil }
            length = buffer[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
            header = 10
        }
        let control = opcode.rawValue & 0x8 != 0
        if control {
            guard final, length <= 125 else { throw CDPError.closed("a control frame out of shape") }
        } else {
            if opcode == .continuation {
                guard pieces != nil || droppingPieces else { throw CDPError.closed("a piece of no message") }
            } else {
                guard pieces == nil, !droppingPieces else { throw CDPError.closed("a new message inside another") }
            }
            if droppingPieces || length > UInt64(limit) || UInt64(pieces?.count ?? 0) + length > UInt64(limit) {
                let starts = !droppingPieces
                pieces = nil
                droppingPieces = !final
                buffer.removeFirst(header)
                skipping = length
                skip()
                return .some(starts ? .dropped : nil)
            }
        }
        guard buffer.count - header >= Int(length) else { return nil }
        let payload = Array(buffer[header..<(header + Int(length))])
        buffer.removeFirst(header + Int(length))
        switch opcode {
        case .ping:
            return .some(.ping(Data(payload)))
        case .pong:
            return .some(nil)
        case .close:
            return .some(.close)
        case .text, .binary:
            if final { return .some(.message(Data(payload))) }
            pieces = payload
            return .some(nil)
        case .continuation:
            guard var started = pieces else { throw CDPError.closed("a piece of no message") }
            started += payload
            if final {
                pieces = nil
                return .some(.message(Data(started)))
            }
            pieces = started
            return .some(nil)
        }
    }

    /// Drops what has come of a frame being passed over.
    private mutating func skip() {
        let count = Int(min(UInt64(buffer.count), skipping))
        buffer.removeFirst(count)
        skipping -= UInt64(count)
    }
}

/// One WebSocket connection to a browser's DevTools endpoint on this Mac, over
/// one TCP connection (ITER-076 3.1). It is never tried again on its own:
/// Chrome asks the user to Allow each new connection, so a handshake the
/// browser ends — the user said no, or the question was closed — ends the
/// attempt, and a port nothing listens on fails at once. URLSession would open
/// up to three connections for a handshake a server drops (measured
/// 2026-09-28), and so ask the user up to three times.
///
/// Every state change runs on one serial queue.
final class CDPSocket: @unchecked Sendable {
    /// The browser's messages, in order; finished with the reason it ended.
    let messages: AsyncThrowingStream<String, Error>

    private let stream: AsyncThrowingStream<String, Error>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.metawhisp.cdp-socket")
    private let request: Data
    private let expectedAccept: String
    private let opened = CDPOpenSignal()
    private var reader: WebSocketReader
    private var answer: [UInt8] = []
    /// Whether the connection reached the browser: something answered on
    /// the port.
    private var reached = false
    private var isOpen = false
    private var ended = false

    /// The largest handshake answer read.
    private static let answerLimit = 16_384

    /// Nil for anything but a `ws://` address with a host and a port.
    init?(url: URL, maximumMessageSize: Int) {
        guard url.scheme == "ws", let host = url.host, !host.isEmpty, let port = url.port,
              let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        request = Data(("GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)
        expectedAccept = WebSocketFrame.acceptKey(for: key)
        reader = WebSocketReader(limit: maximumMessageSize)
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        let (messages, stream) = AsyncThrowingStream<String, Error>.makeStream()
        self.messages = messages
        self.stream = stream
    }

    /// Starts the one connection and its handshake.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.changed(state) }
        connection.start(queue: queue)
    }

    /// Whether the handshake finished: open, or the reason it ended.
    func waitUntilOpen() async -> Result<Void, CDPError> {
        await opened.wait()
    }

    /// Sends one text message; messages go out in the order they are sent.
    /// `held`, when given, runs on the socket's queue first (`write`).
    func send(_ text: String, held: (@Sendable () -> Void)? = nil) async throws {
        let frame = WebSocketFrame.encode(.text, payload: Data(text.utf8), mask: Self.mask())
        try await write(held: held) { frame }
    }

    /// Sends one text message that `compose` makes on the socket's queue, in
    /// the very turn that hands it to the connection: what it decides there
    /// is what goes out, with nothing between (Codex review 2 of I-09, P1-5).
    /// Nil from it sends nothing.
    func send(composing compose: @escaping @Sendable () -> String?, held: (@Sendable () -> Void)? = nil) async throws {
        try await write(held: held) {
            compose().map { WebSocketFrame.encode(.text, payload: Data($0.utf8), mask: Self.mask()) }
        }
    }

    /// Hands the frame `make` gives, on the socket's queue, to the connection.
    /// `held` runs there, in that turn, before the frame is made: tests hold
    /// the queue with it (Codex review 3 of I-09, P2-2); the app passes nil.
    private func write(held: (@Sendable () -> Void)?, _ make: @escaping @Sendable () -> Data?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                held?()
                guard self.isOpen, !self.ended else { return continuation.resume(throwing: CDPError.notOpen) }
                guard let frame = make() else {
                    return continuation.resume(throwing: CDPError.closed("a message that could not be written"))
                }
                self.connection.send(content: frame, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: CDPError.closed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    /// Ends the connection, telling the browser first when it is open.
    func close() {
        queue.async { self.end("closed by the app") }
    }

    // MARK: - On the queue

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            reached = true
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                if let error { self?.end(error.localizedDescription) }
            })
            receive()
        case .waiting(let error), .failed(let error):
            // Waiting is where a connection would try again later: this one
            // does not.
            end(error.localizedDescription)
        case .cancelled:
            end("closed")
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty { self.arrived(data) }
            if let error { return self.end(error.localizedDescription) }
            if complete { return self.end("closed by the browser") }
            if !self.ended { self.receive() }
        }
    }

    private func arrived(_ data: Data) {
        guard isOpen else { return handshake(data) }
        do {
            for event in try reader.read(data) {
                switch event {
                case .message(let bytes):
                    stream.yield(String(decoding: bytes, as: UTF8.self))
                case .ping(let payload):
                    connection.send(content: WebSocketFrame.encode(.pong, payload: payload, mask: Self.mask()),
                                    completion: .idempotent)
                case .close:
                    return end("closed by the browser")
                case .dropped:
                    // The call it answered runs out of time.
                    break
                }
            }
        } catch {
            end((error as? CDPError).map { "\($0)" } ?? error.localizedDescription)
        }
    }

    /// Reads the handshake's answer: it must switch protocols and carry the
    /// proof for this connection's key. What follows it is the first frames.
    private func handshake(_ data: Data) {
        answer.append(contentsOf: data)
        let marker: [UInt8] = [13, 10, 13, 10]
        guard let headEnd = answer.indices.dropLast(3).first(where: { Array(answer[$0..<($0 + 4)]) == marker }) else {
            if answer.count > Self.answerLimit { end("the browser's answer is too long") }
            return
        }
        let head = String(decoding: answer[..<headEnd], as: UTF8.self).components(separatedBy: "\r\n")
        let rest = Data(answer[(headEnd + 4)...])
        answer = []
        let status = head.first?.split(separator: " ").dropFirst().first
        guard status == "101" else {
            // "Not found" is no browser at this address — one that has moved
            // on, or something else on its old port: passed over like a port
            // nothing answers on. Any other answer is a browser's.
            return end("the browser answered \(head.first ?? "nothing")", reachedBrowser: status != "404")
        }
        let accept = head.dropFirst().compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "sec-websocket-accept"
            else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.first
        guard accept == expectedAccept else { return end("the browser's answer does not match this connection") }
        isOpen = true
        opened.resolve(.success(()))
        if !rest.isEmpty { arrived(rest) }
    }

    private func end(_ reason: String, reachedBrowser: Bool? = nil) {
        guard !ended else { return }
        ended = true
        // A port nothing answered on is told apart from a browser that ended
        // the connection: only the first may be tried again.
        let error: CDPError = (reachedBrowser ?? reached) ? .closed(reason) : .unreachable(reason)
        opened.resolve(.failure(error))
        stream.finish(throwing: error)
        if isOpen {
            // Tell the browser, then let go.
            connection.send(content: WebSocketFrame.encode(.close, payload: Data(), mask: Self.mask()),
                            completion: .contentProcessed { [connection] _ in connection.cancel() })
        } else {
            connection.cancel()
        }
    }

    private static func mask() -> [UInt8] {
        (0..<4).map { _ in UInt8.random(in: .min ... .max) }
    }
}

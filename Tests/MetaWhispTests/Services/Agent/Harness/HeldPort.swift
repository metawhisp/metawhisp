import Foundation
import Network
import XCTest
@testable import MetaWhisp

/// A DevTools port on the loopback address, for tests.
/// - By default it holds every connection without answering, as Chrome does
///   while it asks the user to Allow; `decline` ends them, as the user's No
///   does, and `hangUp` ends its side only.
/// - `answering:` sends that text to every handshake.
/// - `speaking` completes the handshake as a browser does, records every
///   message the client sends, and — when `replying` — answers each with an
///   empty result; one that contains `slowOn` is answered `by` seconds late,
///   as a page slow to take an input is. `onMessage` sees each message as it
///   comes, on the port's queue.
final class HeldPort: @unchecked Sendable {
    private let listener: NWListener
    private let answer: String?
    private let speaking: Bool
    private let replying: Bool
    private let slowOn: String?
    private let slowness: TimeInterval
    private let queue = DispatchQueue(label: "held-port")
    private var held: [NWConnection] = []
    private var count = 0
    private var endedCount = 0
    private var heardCount = 0
    private var received: [String] = []
    var onMessage: (@Sendable (String) -> Void)?

    private init(listener: NWListener, answer: String?, speaking: Bool, replying: Bool, slowOn: String?,
                 slowness: TimeInterval) {
        self.listener = listener
        self.answer = answer
        self.speaking = speaking
        self.replying = replying
        self.slowOn = slowOn
        self.slowness = slowness
    }

    static func start(answering answer: String? = nil, speaking: Bool = false, replying: Bool = false,
                      slowOn: String? = nil, by slowness: TimeInterval = 0) async throws -> HeldPort {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let port = HeldPort(listener: try NWListener(using: parameters), answer: answer, speaking: speaking,
                            replying: replying, slowOn: slowOn, slowness: slowness)
        try await port.listen()
        return port
    }

    var port: Int { Int(listener.port?.rawValue ?? 0) }

    var connections: Int { queue.sync { count } }

    /// Connections the client has ended.
    var ended: Int { queue.sync { endedCount } }

    /// Bytes the clients sent, in all: none from a client that only
    /// connected (ITER-076 stage 9e).
    var heard: Int { queue.sync { heardCount } }

    /// Every message the client sent after the handshake, in order.
    var messages: [String] { queue.sync { received } }

    func decline() {
        queue.sync {
            for connection in held { connection.cancel() }
            held = []
        }
    }

    /// Says it has nothing more to send and keeps listening: a half-closed
    /// connection, as a server that ends its side first leaves it.
    func hangUp() {
        queue.sync {
            for connection in held {
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            }
        }
    }

    func stop() {
        decline()
        listener.cancel()
    }

    private func listen() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.held.append(connection)
            self.count += 1
            connection.start(queue: self.queue)
            self.drain(connection, answered: false, bytes: [])
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = FirstTime()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { continuation.resume() }
                case .failed(let error): if once.take() { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Reads what the client sends: its handshake, answered only when told
    /// to; then, when speaking, its messages.
    private func drain(_ connection: NWConnection, answered: Bool, bytes: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            self.heardCount += data?.count ?? 0
            guard error == nil, !done else {
                self.endedCount += 1
                return
            }
            var bytes = bytes + [UInt8](data ?? Data())
            if !answered {
                guard let reply = self.reply(to: bytes) else {
                    return self.drain(connection, answered: false, bytes: self.answer == nil && !self.speaking ? [] : bytes)
                }
                connection.send(content: Data(reply.utf8), completion: .idempotent)
                return self.drain(connection, answered: true, bytes: [])
            }
            if self.speaking {
                for message in Self.messages(in: &bytes) {
                    self.received.append(message)
                    self.onMessage?(message)
                    if self.replying, let id = (try? CDPValue.decode(message))?["id"]?.int {
                        let reply = Self.frame("{\"id\":\(id),\"result\":{}}")
                        let late = self.slowOn.map { message.contains($0) } ?? false
                        self.queue.asyncAfter(deadline: .now() + (late ? self.slowness : 0)) {
                            connection.send(content: reply, completion: .idempotent)
                        }
                    }
                }
            }
            self.drain(connection, answered: true, bytes: bytes)
        }
    }

    /// The answer to a whole handshake: the one given, or — speaking — a
    /// switch of protocols with this connection's proof.
    private func reply(to request: [UInt8]) -> String? {
        let text = String(decoding: request, as: UTF8.self)
        guard text.contains("\r\n\r\n") else { return nil }
        if let answer { return answer }
        guard speaking, let line = text.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else { return nil }
        let key = line.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
        return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(WebSocketFrame.acceptKey(for: key))\r\n\r\n"
    }

    /// The client's whole text frames, unmasked; what is left waits for more.
    private static func messages(in bytes: inout [UInt8]) -> [String] {
        var messages: [String] = []
        while bytes.count >= 2 {
            var length = Int(bytes[1] & 0x7F), header = 2
            if length == 126 {
                guard bytes.count >= 4 else { break }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                header = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { break }
                length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
                header = 10
            }
            let masked = bytes[1] & 0x80 != 0
            let start = header + (masked ? 4 : 0)
            guard bytes.count >= start + length else { break }
            var payload = Array(bytes[start..<(start + length)])
            if masked {
                let mask = Array(bytes[header..<(header + 4)])
                for index in payload.indices { payload[index] ^= mask[index % 4] }
            }
            let opcode = bytes[0] & 0x0F
            bytes.removeFirst(start + length)
            if opcode == 0x1 { messages.append(String(decoding: payload, as: UTF8.self)) }
        }
        return messages
    }

    /// One unmasked text frame, as a server sends it.
    private static func frame(_ text: String) -> Data {
        let payload = [UInt8](text.utf8)
        var frame: [UInt8] = [0x81]
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        }
        return Data(frame + payload)
    }
}

import Foundation
import Network
@testable import MetaWhisp

/// A recorded DevTools transport for tests (ITER-076 I-05): a port on the
/// loopback address that passes every message between the app and a real
/// Chrome and keeps what the app sent. A test may hold the reply to a message
/// it names until it releases it, and may make every reply come late.
final class CDPProxy: @unchecked Sendable {
    private let listener: NWListener
    private let chrome: CDPSocket
    private let queue = DispatchQueue(label: "cdp-proxy")
    private var client: NWConnection?
    private var received: [String] = []
    private var heldIDs: Set<Int> = []
    private var delay: TimeInterval = 0
    private var outgoing: AsyncStream<String>.Continuation?
    private var pumps: [Task<Void, Never>] = []

    /// Sees each message the app sends, on the proxy's queue; true holds the
    /// reply to it.
    var holdsReply: (@Sendable (String) -> Bool)?
    /// Called with a held reply's release once that reply came from Chrome.
    var onHeld: (@Sendable (_ release: @escaping @Sendable () -> Void) -> Void)?
    /// Sees each message the app sends, on the proxy's queue; true keeps it
    /// from Chrome and answers it at once with an empty result: a call
    /// Chrome says it carried out, and never saw (ITER-076 I-09 review).
    var swallows: (@Sendable (String) -> Bool)?
    /// Sees each message the app sends, on the proxy's queue; an answer keeps
    /// it from Chrome and answers it so instead: with an error at once, or
    /// never (Codex review 2 of I-09, P2-4).
    var answers: (@Sendable (String) -> Answer?)?

    /// What `answers` gives a message in Chrome's place.
    enum Answer {
        /// A protocol error, at once.
        case error(String)
        /// Nothing, ever.
        case never
    }

    private init(listener: NWListener, chrome: CDPSocket) {
        self.listener = listener
        self.chrome = chrome
    }

    /// A proxy in front of the Chrome at `upstream`, already connected to it.
    static func start(to upstream: URL) async throws -> CDPProxy {
        guard let chrome = CDPSocket(url: upstream, maximumMessageSize: CDPConnection.maximumMessageSize) else {
            throw CDPError.notOpen
        }
        chrome.start()
        if case .failure(let error) = await chrome.waitUntilOpen() { throw error }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let proxy = CDPProxy(listener: try NWListener(using: parameters), chrome: chrome)
        try await proxy.listen()
        proxy.pump()
        return proxy
    }

    /// Where the app connects.
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.port?.rawValue ?? 0)/devtools/browser/proxy")! }

    /// Every message the app sent, in order.
    var messages: [String] { queue.sync { received } }

    /// Every reply from now on goes back `seconds` late — each still well
    /// within its own deadline.
    func delayReplies(by seconds: TimeInterval) {
        queue.sync { delay = seconds }
    }

    func stop() {
        pumps.forEach { $0.cancel() }
        outgoing?.finish()
        queue.sync {
            client?.cancel()
            client = nil
        }
        listener.cancel()
        chrome.close()
    }

    // MARK: - Private

    private func listen() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.client = connection
            connection.start(queue: self.queue)
            self.drain(connection, open: false, bytes: [])
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

    /// Chrome's messages to the app, and the app's to Chrome, one at a time
    /// each way, in order.
    private func pump() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        outgoing = continuation
        let chrome = chrome
        pumps.append(Task {
            for await text in stream { try? await chrome.send(text) }
        })
        pumps.append(Task { [weak self] in
            do {
                for try await text in chrome.messages { self?.fromChrome(text) }
            } catch {}
        })
    }

    private func fromChrome(_ text: String) {
        queue.async {
            let id = (try? CDPValue.decode(text))?["id"]?.int
            let send = { [weak self] in
                guard let self else { return }
                self.queue.async { self.client?.send(content: Self.frame(text), completion: .idempotent) }
            }
            if let id, self.heldIDs.remove(id) != nil, let onHeld = self.onHeld {
                onHeld { send() }
            } else if id != nil, self.delay > 0 {
                self.queue.asyncAfter(deadline: .now() + self.delay) { send() }
            } else {
                send()
            }
        }
    }

    private func drain(_ connection: NWConnection, open: Bool, bytes: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self, error == nil, !done else { return }
            var bytes = bytes + [UInt8](data ?? Data())
            if !open {
                guard let reply = Self.handshake(bytes) else { return self.drain(connection, open: false, bytes: bytes) }
                connection.send(content: Data(reply.utf8), completion: .idempotent)
                return self.drain(connection, open: true, bytes: [])
            }
            for message in Self.messages(in: &bytes) {
                self.received.append(message)
                if self.swallows?(message) == true, let id = (try? CDPValue.decode(message))?["id"]?.int {
                    connection.send(content: Self.frame("{\"id\":\(id),\"result\":{}}"), completion: .idempotent)
                    continue
                }
                if let answer = self.answers?(message), let id = (try? CDPValue.decode(message))?["id"]?.int {
                    if case .error(let text) = answer, let quoted = try? CDPValue.string(text).encoded() {
                        let reply = "{\"id\":\(id),\"error\":{\"code\":-32000,\"message\":\(quoted)}}"
                        connection.send(content: Self.frame(reply), completion: .idempotent)
                    }
                    continue
                }
                if self.holdsReply?(message) == true, let id = (try? CDPValue.decode(message))?["id"]?.int {
                    self.heldIDs.insert(id)
                }
                self.outgoing?.yield(message)
            }
            self.drain(connection, open: true, bytes: bytes)
        }
    }

    private static func handshake(_ request: [UInt8]) -> String? {
        let text = String(decoding: request, as: UTF8.self)
        guard text.contains("\r\n\r\n"), let line = text.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else { return nil }
        let key = line.dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces)
        return "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(WebSocketFrame.acceptKey(for: key))\r\n\r\n"
    }

    /// The app's whole text frames, unmasked; what is left waits for more.
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

    /// One unmasked text frame, as a server sends it, of any length.
    private static func frame(_ text: String) -> Data {
        let payload = [UInt8](text.utf8)
        var frame: [UInt8] = [0x81]
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        } else {
            frame.append(127)
            frame += stride(from: 56, through: 0, by: -8).map { UInt8((UInt64(payload.count) >> UInt64($0)) & 0xFF) }
        }
        return Data(frame + payload)
    }
}

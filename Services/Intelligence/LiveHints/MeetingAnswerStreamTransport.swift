import Foundation

/// Card responses deliver content followed by one terminal status.
enum MeetingAnswerStreamEvent: Equatable, Sendable {
    case delta(String)
    case end(MeetingAnswerReply)
}

/// A pull-based line source lets cancellation prevent the next read.
typealias MeetingAnswerLineTransport = @Sendable (URLRequest) async throws -> MeetingAnswerLineResponse

struct MeetingAnswerLineResponse: @unchecked Sendable {
    let response: HTTPURLResponse
    let nextLine: @Sendable () async throws -> String?
    let cancel: @Sendable () -> Void

    init(response: HTTPURLResponse,
         nextLine: @escaping @Sendable () async throws -> String?,
         cancel: @escaping @Sendable () -> Void) {
        self.response = response
        self.nextLine = nextLine
        let cancellation = MeetingStreamCancellation(cancel)
        self.cancel = { cancellation.cancel() }
    }
}

/// One owner for terminal events and cancellation across all card routes.
enum MeetingAnswerStreamTransport {
    enum WireFormat { case pro, ownKey }

    @MainActor
    static func make(stopToken: LiveHintsStopToken,
                     handle: LiveHintsRequestHandle,
                     operation: @escaping @MainActor (AsyncStream<MeetingAnswerStreamEvent>.Continuation) async throws -> MeetingAnswerReply
    ) -> AsyncStream<MeetingAnswerStreamEvent> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                let reply: MeetingAnswerReply
                do {
                    try check(stopToken, handle)
                    reply = try await operation(continuation)
                } catch {
                    let cancelled = Task.isCancelled || stopToken.isCancelled || handle.isCancelled || error is CancellationError
                    let failureStatus = (error as? URLError)?.code == .timedOut ? 408 : 500
                    reply = MeetingAnswerReply(status: cancelled ? 499 : failureStatus, retryAfter: nil, text: nil)
                }
                continuation.yield(.end(reply))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            handle.attach { task.cancel() }
            stopToken.retain(task)
        }
    }

    /// Routes implemented only as whole replies keep a compatible stream adapter.
    @MainActor
    static func bridge(_ route: MeetingAnswerRoute, system: String, user: String, deadlineMs: Int,
                       stopToken: LiveHintsStopToken, handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        make(stopToken: stopToken, handle: handle) { continuation in
            let reply = try await route.answer(system: system, user: user, deadlineMs: deadlineMs, stopToken: stopToken)
            try check(stopToken, handle)
            if reply.status == 200, let text = reply.text {
                continuation.yield(.delta(text))
            }
            return reply
        }
    }

    /// Card deadlines own completion cancellation; non-card answer timers stay separate.
    @MainActor
    static func wholeText(stopToken: LiveHintsStopToken, handle: LiveHintsRequestHandle,
                          keepProviderStatus: Bool = false,
                          complete: @escaping @MainActor () async throws -> String) -> AsyncStream<MeetingAnswerStreamEvent> {
        make(stopToken: stopToken, handle: handle) { continuation in
            do {
                let text = try await complete()
                try check(stopToken, handle)
                continuation.yield(.delta(text))
                return MeetingAnswerReply(status: 200, retryAfter: nil, text: text)
            } catch {
                try check(stopToken, handle)
                if keepProviderStatus, case let ProcessingError.http(status, _, retryAfter) = error {
                    return MeetingAnswerReply(status: status, retryAfter: retryAfter, text: nil)
                }
                throw error
            }
        }
    }

    @MainActor
    static func read(request: URLRequest, transport: MeetingAnswerLineTransport, format: WireFormat,
                     stopToken: LiveHintsStopToken, handle: LiveHintsRequestHandle,
                     continuation: AsyncStream<MeetingAnswerStreamEvent>.Continuation) async throws -> MeetingAnswerReply {
        try check(stopToken, handle)
        let source = try await transport(request)
        defer { source.cancel() }
        return try await withTaskCancellationHandler {
            try check(stopToken, handle)
            let status = source.response.statusCode
            let retryAfter = ProAdviceClient.retryAfterSeconds(source.response)
            guard status == 200 else {
                return MeetingAnswerReply(status: status, retryAfter: retryAfter, text: nil)
            }
            let isSSE = source.response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased().contains("text/event-stream") == true
            if !isSSE {
                var body = ""
                while let line = try await next(source, stopToken: stopToken, handle: handle) {
                    body += line + "\n"
                }
                let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
                let text: String?
                switch format {
                case .pro:
                    text = object?["text"] as? String
                case .ownKey:
                    let choices = object?["choices"] as? [[String: Any]]
                    text = (choices?.first?["message"] as? [String: Any])?["content"] as? String
                }
                guard let text else {
                    // The Pro JSON adapter preserves HTTP 200 even when text cannot be decoded.
                    return MeetingAnswerReply(status: format == .pro ? 200 : 500, retryAfter: retryAfter, text: nil)
                }
                try check(stopToken, handle)
                continuation.yield(.delta(text))
                return MeetingAnswerReply(status: 200, retryAfter: retryAfter, text: nil)
            }
            while let line = try await next(source, stopToken: stopToken, handle: handle) {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty else { continue }
                if format == .ownKey, payload == "[DONE]" {
                    return MeetingAnswerReply(status: 200, retryAfter: retryAfter, text: nil)
                }
                guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
                    return MeetingAnswerReply(status: 500, retryAfter: retryAfter, text: nil)
                }
                if object["error"] != nil {
                    return MeetingAnswerReply(status: 500, retryAfter: retryAfter, text: nil)
                }
                let text: String?
                switch format {
                case .pro:
                    if object["done"] as? Bool == true {
                        return MeetingAnswerReply(status: 200, retryAfter: retryAfter, text: nil)
                    }
                    text = object["delta"] as? String
                case .ownKey:
                    let choices = object["choices"] as? [[String: Any]]
                    text = (choices?.first?["delta"] as? [String: Any])?["content"] as? String
                }
                if let text, !text.isEmpty {
                    try check(stopToken, handle)
                    continuation.yield(.delta(text))
                }
            }
            // EOF is not successful completion, even when useful content arrived.
            return MeetingAnswerReply(status: 500, retryAfter: retryAfter, text: nil)
        } onCancel: {
            source.cancel()
        }
    }

    private static func next(_ source: MeetingAnswerLineResponse, stopToken: LiveHintsStopToken,
                             handle: LiveHintsRequestHandle) async throws -> String? {
        try check(stopToken, handle)
        let line = try await source.nextLine()
        try check(stopToken, handle)
        return line
    }

    static func check(_ token: LiveHintsStopToken, _ handle: LiveHintsRequestHandle) throws {
        guard !Task.isCancelled, !token.isCancelled, !handle.isCancelled else { throw CancellationError() }
    }

    static func live(_ request: URLRequest) async throws -> MeetingAnswerLineResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        let reader = MeetingStreamLineReader(bytes)
        return MeetingAnswerLineResponse(response: http, nextLine: { try await reader.next() },
                                         cancel: { bytes.task.cancel() })
    }

    /// Existing injected data transports remain fake when their callers start streaming.
    static func buffered(_ data: Data, response: HTTPURLResponse) -> MeetingAnswerLineResponse {
        let reader = MeetingBufferedLineReader(String(decoding: data, as: UTF8.self))
        return MeetingAnswerLineResponse(response: response, nextLine: { reader.next() }, cancel: {})
    }
}

extension MeetingAnswerRoute {
    func stream(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        MeetingAnswerStreamTransport.bridge(self, system: system, user: user, deadlineMs: deadlineMs,
                                           stopToken: stopToken, handle: handle)
    }
}

extension OwnKeyAnswerRoute {
    func stream(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        guard let lineTransport else {
            let complete = self.complete
            let key = apiKey()
            let chosen = provider()
            return MeetingAnswerStreamTransport.wholeText(stopToken: stopToken, handle: handle, keepProviderStatus: true) {
                try await complete(system, user, key, chosen)
            }
        }
        let key = apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = provider()
        return MeetingAnswerStreamTransport.make(stopToken: stopToken, handle: handle) { continuation in
            guard !key.isEmpty else { return MeetingAnswerReply(status: 401, retryAfter: nil, text: nil) }
            var request = URLRequest(url: chosen.endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": chosen.model, "temperature": 0.3, "max_tokens": 4096, "stream": true,
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
            ])
            return try await MeetingAnswerStreamTransport.read(request: request, transport: lineTransport, format: .ownKey,
                                                               stopToken: stopToken, handle: handle, continuation: continuation)
        }
    }
}

extension LocalAnswerRoute {
    /// Local backends return a single complete answer, retaining separate inputs.
    func stream(system: String, user: String, deadlineMs: Int, stopToken: LiveHintsStopToken,
                handle: LiveHintsRequestHandle) -> AsyncStream<MeetingAnswerStreamEvent> {
        let complete = self.complete
        return MeetingAnswerStreamTransport.wholeText(stopToken: stopToken, handle: handle) {
            try await complete(system, user, Self.maxUserCharacters)
        }
    }
}

private final class MeetingStreamCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (() -> Void)?
    init(_ cancel: @escaping () -> Void) { cancellation = cancel }
    func cancel() {
        let action = lock.withLock { let action = cancellation; cancellation = nil; return action }
        action?()
    }
}

/// Only the producer task advances this iterator; cancellation uses its URL task.
private final class MeetingStreamLineReader: @unchecked Sendable {
    private var iterator: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator
    init(_ bytes: URLSession.AsyncBytes) { iterator = bytes.lines.makeAsyncIterator() }
    func next() async throws -> String? { try await iterator.next() }
}

private final class MeetingBufferedLineReader: @unchecked Sendable {
    private var lines: Array<String>.Iterator
    init(_ body: String) { lines = body.components(separatedBy: .newlines).makeIterator() }
    func next() -> String? { lines.next() }
}

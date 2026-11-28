import Foundation
import MetaWhispTrackerKit

/// FEAT-0006 §7 — the app's end of the local socket. Accepts only the user's own processes (`getpeereid`), reads one
/// request line (at most 1 MB), runs it through `handler` — on the main actor in the app — and writes one answer
/// line. Bad input gets an answer and never stops the server.
/// spec://tracker/FEAT-0006#wire
final class TrackerSocketServer: @unchecked Sendable {
    /// Runs on `queue` (the main queue in the app, where it may assume the main actor).
    typealias Handler = @Sendable (TrackerRequest) -> TrackerResponse

    private let path: String
    private let queue: DispatchQueue
    private let claimTimeout: TimeInterval
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    /// - Parameter claimTimeout: how long a request may wait for `queue` before it is refused as busy. Below the
    ///   client's read ceiling, so the client always hears the answer.
    init(path: String, queue: DispatchQueue = .main, claimTimeout: TimeInterval = 20, handler: @escaping Handler) {
        self.path = path
        self.queue = queue
        self.claimTimeout = claimTimeout
        self.handler = handler
    }
    /// The socket the app serves: `<support folder>/tracker.sock`.
    static var defaultPath: String {
        AppIdentity.current.supportDirectory.appendingPathComponent(TrackerWire.socketName).path
    }

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TrackerFailure(.internalError, "socket: \(String(cString: strerror(errno)))") }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        // A socket file left by a crash: replace it, unless another copy of the app still answers on it.
        if FileManager.default.fileExists(atPath: path) {
            if (try? TrackerClient.send(TrackerRequest(op: "ping", folder: nil, client: nil), socketPath: path,
                                        timeout: 1)) != nil {
                close(fd)
                throw TrackerFailure(.internalError, "Another MetaWhisp already serves \(path).")
            }
            unlink(path)
        }
        var addr = try UnixSocket.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let e = String(cString: strerror(errno))
            close(fd)
            throw TrackerFailure(.internalError, "bind \(path): \(e)")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let e = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw TrackerFailure(.internalError, "listen: \(e)")
        }
        lock.lock()
        listenFD = fd
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "MetaWhisp tracker socket"
        thread.start()
        NSLog("[Tracker] serving %@", path)
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        running = false
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(path)
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if !isRunning { return }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            NSLog("[Tracker] refused a connection from another user")
            return
        }
        UnixSocket.setTimeouts(fd, seconds: TrackerWire.timeoutSeconds)
        let response: TrackerResponse
        switch UnixSocket.readLine(fd, limit: TrackerWire.maxBytes) {
        case .closed:
            return
        case .tooLong:
            response = .failure(.validation("The request is larger than \(TrackerWire.maxBytes / 1_048_576) MB."))
        case .line(let data):
            if let request = try? TrackerWire.decode(TrackerRequest.self, from: data) {
                response = run(request)
            } else {
                response = .failure(.validation("Not a MetaWhisp tracker request."))
            }
        }
        if let line = try? TrackerWire.encodeLine(response) { _ = UnixSocket.writeAll(fd, line) }
    }

    /// Hands the request to `queue`, with a ceiling on the wait. A request refused as busy is cancelled under the
    /// lock before it can start, so "try again" never also runs it later (review P2-4: no duplicate tasks).
    private func run(_ request: TrackerRequest) -> TrackerResponse {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        let handler = self.handler
        queue.async {
            guard box.claim() else { return }
            box.value = handler(request)
            done.signal()
        }
        if done.wait(timeout: .now() + claimTimeout) == .success, let value = box.value { return value }
        if box.cancelIfNotStarted() {
            return .failure(TrackerFailure(.internalError, "MetaWhisp was busy for \(Int(claimTimeout)) s; nothing "
                                           + "was done. Try again."))
        }
        // It started just now: a synchronous step on the queue; its answer is the truth.
        done.wait()
        return box.value ?? .failure(TrackerFailure(.internalError, "MetaWhisp lost the answer."))
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var started = false
        private var cancelled = false
        var value: TrackerResponse?

        /// The queue takes the request, unless it was already refused.
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            started = true
            return true
        }

        /// The waiter gives up, unless the request already started.
        func cancelIfNotStarted() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if started { return false }
            cancelled = true
            return true
        }
    }
}

import Foundation

// FEAT-0006 §7 — a unix-domain socket in the app's support folder; one JSON line each way per connection.

/// The POSIX pieces both ends use.
public enum UnixSocket {
    /// `sun_path` holds 104 bytes including the terminator.
    public static let maxPathBytes = 103

    public static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathBytes else {
            throw TrackerFailure(.internalError, "The socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    public static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 { if errno == EINTR { continue }; return false }
                p = p.advanced(by: n)
                left -= n
            }
            return true
        }
    }

    public enum ReadResult: Equatable {
        case line(Data)
        case tooLong
        case closed
    }

    /// Reads up to the first newline; a line over `limit` bytes is read to its end (up to 8× the limit, so the
    /// sender is not cut off mid-write) and refused.
    public static func readLine(_ fd: Int32, limit: Int) -> ReadResult {
        var out = Data()
        var total = 0
        var buf = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return total > limit ? .tooLong : .closed }
            if n == 0 { return total > limit ? .tooLong : (out.isEmpty ? .closed : .line(out)) }
            let chunk = buf[0..<n]
            let nl = chunk.firstIndex(of: 0x0A)
            let part = nl.map { chunk[chunk.startIndex..<$0] } ?? chunk
            total += part.count
            if total <= limit { out.append(contentsOf: part) } else { out.removeAll(keepingCapacity: false) }
            if nl != nil { return total > limit ? .tooLong : .line(out) }
            if total > limit * 8 { return .tooLong }
        }
    }
}

/// The command-line side: connect, send one request, read one answer.
public enum TrackerClient {

    public enum ConnectError: Error, Equatable {
        /// No socket file, or nobody listening: the app is not running (or too old to have the tracker).
        case notRunning
        case io(String)
    }

    /// `~/Library/Application Support/MetaWhisp/tracker.sock`, or `METAWHISP_SOCKET`.
    public static func defaultSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let p = environment["METAWHISP_SOCKET"], !p.isEmpty { return p }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("MetaWhisp").appendingPathComponent(TrackerWire.socketName).path
    }

    public static func send(_ request: TrackerRequest, socketPath: String, timeout: TimeInterval) throws -> TrackerResponse {
        try sendRaw(try TrackerWire.encodeLine(request), socketPath: socketPath, timeout: timeout)
    }

    public static func sendRaw(_ line: Data, socketPath: String, timeout: TimeInterval) throws -> TrackerResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectError.io("socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var addr = try UnixSocket.address(socketPath)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            if errno == ENOENT || errno == ECONNREFUSED || errno == ENOTSOCK { throw ConnectError.notRunning }
            throw ConnectError.io("connect: \(String(cString: strerror(errno)))")
        }
        UnixSocket.setTimeouts(fd, seconds: timeout)
        guard UnixSocket.writeAll(fd, line) else { throw ConnectError.io("MetaWhisp closed the connection.") }
        switch UnixSocket.readLine(fd, limit: TrackerWire.maxBytes * 8) {
        case .line(let data):
            do { return try TrackerWire.decode(TrackerResponse.self, from: data) } catch {
                throw ConnectError.io("MetaWhisp sent an answer this tool cannot read.")
            }
        case .tooLong: throw ConnectError.io("MetaWhisp's answer was too long.")
        case .closed: throw ConnectError.io("MetaWhisp did not answer in \(Int(timeout)) s.")
        }
    }

    /// T11 — sends; when the app is not running, starts it once (`launch`) and retries until it answers or `wait`
    /// runs out. Never throws: every outcome is an answer the agent can read.
    public static func sendLaunching(_ request: TrackerRequest, socketPath: String,
                                     wait: TimeInterval = TrackerWire.timeoutSeconds, poll: TimeInterval = 0.25,
                                     launch: () throws -> Void) -> TrackerResponse {
        func attempt() -> Result<TrackerResponse, ConnectError> {
            do { return .success(try send(request, socketPath: socketPath, timeout: TrackerWire.timeoutSeconds)) }
            catch let e as ConnectError { return .failure(e) }
            catch let f as TrackerFailure { return .success(.failure(f)) }
            catch { return .failure(.io(error.localizedDescription)) }
        }
        switch attempt() {
        case .success(let r): return r
        case .failure(.io(let m)): return .failure(TrackerFailure(.appUnavailable, m))
        case .failure(.notRunning): break
        }
        do { try launch() } catch {
            return .failure(TrackerFailure(.appUnavailable, "MetaWhisp could not be started: \(error)"))
        }
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: poll)
            switch attempt() {
            case .success(let r): return r
            case .failure(.io(let m)): return .failure(TrackerFailure(.appUnavailable, m))
            case .failure(.notRunning): continue
            }
        }
        return .failure(TrackerFailure(.appUnavailable,
            "MetaWhisp did not answer within \(Int(wait)) s. If it is running, update it to a version with the task "
            + "tracker; if not, open it once."))
    }
}

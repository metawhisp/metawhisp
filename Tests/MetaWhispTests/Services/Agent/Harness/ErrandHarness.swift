import Combine
import Foundation
@testable import MetaWhisp

/// A planner that has its plan already: what a test gives the run (ITER-076
/// I-05). It costs nothing.
struct FixedPlanner: ErrandPlanner {
    let plan: AgentPlan
    func worstCaseUSD(goal: String) -> Double { 0 }

    func plan(goal: String) async throws -> AgentPlan { plan }
}

extension AgentRun {
    /// A run whose plan is given, as every test before the planner made one.
    convenience init(plan: AgentPlan, errandID: UUID, collaborators: Collaborators,
                     answerWindow: Duration = .seconds(ConfirmationRequest.answerWindow),
                     limits: AgentBudget.Limits = .standard, stopLimit: Duration = AgentRun.stopLimit) {
        self.init(goal: plan.goal, planner: FixedPlanner(plan: plan), errandID: errandID,
                  collaborators: collaborators, answerWindow: answerWindow, limits: limits, stopLimit: stopLimit)
    }

    /// Runs the errand to its end, hearing nothing of its progress, and
    /// returns its record.
    func run() async -> ErrandRecord {
        _ = await run(report: { _ in })
        return record
    }
}

/// The lines an errand's owners said, as the app's log would get them
/// (ITER-076 I-06a): what a test hands the run and the service in place of
/// the log.
@MainActor
final class LogLines {
    private(set) var all: [String] = []

    var sink: @MainActor @Sendable (String) -> Void {
        { [weak self] line in self?.all.append(line) }
    }

    /// Every line said of errand `id`, without its prefix.
    func lines(of id: UUID) -> [String] {
        let prefix = "[Errand \(id.uuidString.prefix(8))] "
        return all.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// The numbered lines of errand `id`, whole, in the order said.
    func numbered(of id: UUID) -> [String] {
        let prefix = "[Errand \(id.uuidString.prefix(8))] #"
        return all.filter { $0.hasPrefix(prefix) }
    }

    /// What the log says errand `id`'s record holds: under each number, the
    /// last line said — a step corrected, or taken back, is said again under
    /// its number — in the numbers' order.
    func events(of id: UUID) -> [String] {
        var byNumber: [Int: String] = [:]
        for line in numbered(of: id) {
            let rest = line.split(separator: "#", maxSplits: 1)[1]
            guard let number = Int(rest.prefix { $0.isNumber }) else { continue }
            byNumber[number] = line
        }
        return byNumber.keys.sorted().compactMap { byNumber[$0] }
    }
}

/// The fixture browser, where Stop comes as the first act is about to go
/// out: the bridge says nothing was sent. It counts the acts that did. An
/// act's lookup made alone before it is not the act (ITER-076 I-09, round 5).
@MainActor
final class StopsBeforeTheAct: BrowserBridge {
    let inner = WebViewBridge()
    var stop: (@MainActor () -> Void)?
    private var stopped = false

    func openTab(_ url: URL) async throws -> BrowserTab { try await inner.openTab(url) }
    func isLoading(_ tab: BrowserTab) async throws -> Bool { try await inner.isLoading(tab) }
    func closeTab(_ tab: BrowserTab) async throws { try await inner.closeTab(tab) }

    func run(_ javascript: String, in tab: BrowserTab) async throws -> String {
        guard !stopped, javascript.contains("const expected"), !javascript.contains(#""operation":"found""#) else {
            return try await inner.run(javascript, in: tab)
        }
        stopped = true
        stop?()
        throw CancellationError()
    }
    func runAwaiting(_ javascript: String, in tab: BrowserTab) async throws -> String {
        try await inner.runAwaiting(javascript, in: tab)
    }
}

extension ErrandRecord {
    /// The record's events as the log says them.
    var eventLines: [String] { events.indices.map(logLine(at:)) }
}

extension ErrandRecord.Event {
    /// The event without its times and costs, for a test to compare.
    var shape: String {
        switch self {
        case .plan(let result, _, _): "plan \(result.rawValue)"
        case .model(let purpose, let result, _, _): "model \(purpose.rawValue) \(result.rawValue)"
        case .step(let step): "step \(step.operation) \(step.outcome.rawValue)"
        case .pageMiss(let miss): "miss \(miss.rawValue)"
        case .serviceWait(_, let answered): "wait " + (answered.map { $0 ? "answered" : "unanswered" } ?? "cut")
        case .question(let operation, let role): "question \(operation) \(role ?? "-")"
        case .answer(let reply): "answer \(reply.rawValue)"
        case .takenBack: "taken back"
        case .dialog(let kind, let accepted): "dialog \(kind.rawValue) \(accepted ? "ok" : "cancel")"
        case .downloadRefused: "download refused"
        case .addressRefused: "address refused"
        case .read(let read): "read \(read.end.rawValue)"
        case .handover(let kind, let host): "handover \(kind.rawValue) \(host)"
        case .continued: "continued"
        case .ending(let ending, let failure, let notRun, let rows):
            (["ending", ending.rawValue, failure?.rawValue, notRun?.rawValue].compactMap { $0 } + ["rows=\(rows)"])
                .joined(separator: " ")
        }
    }
}

/// A browser link that is connected already, with one bridge for every
/// errand.
@MainActor
final class FixedLink: BrowserLink {
    let state: ChromeLink.State = .connected(browser: "Google Chrome")
    var states: AnyPublisher<ChromeLink.State, Never> { Just(state).eraseToAnyPublisher() }
    private let bridge: any BrowserBridge

    init(_ bridge: any BrowserBridge) { self.bridge = bridge }

    func errandBridge() async -> (any BrowserBridge)? { bridge }
}

/// Jev as the Pro server answers it, recorded (ITER-076 I-05): every request
/// the loop sends is kept, and each is answered from a script — a status for
/// the whole request, or an answer per question. Nothing reaches the network.
final class RecordedJev: @unchecked Sendable {
    /// What one request asked: each question's options (none for a noul),
    /// and the state the questions read.
    struct Asked: @unchecked Sendable {
        let questions: [String: [String]]
        let state: [String: Any]

        /// A step asks for the next operation; the risk questions do not.
        var isStep: Bool { questions["operation"] != nil }
        var pageURL: String { ((state["page"] as? [String: Any])?["url"] as? String) ?? "" }
        /// The labels of the last actions, oldest first.
        var recentLabels: [String] {
            ((state["recent_actions"] as? [[String: Any]]) ?? []).compactMap { $0["action"] as? String }
        }

        /// The key of the step's element with this label.
        func key(labelled label: String) -> String? {
            ((state["elements"] as? [[String: Any]]) ?? []).first { $0["label"] as? String == label }?["index"]
                as? String
        }
    }

    /// How the server answers one request.
    indirect enum Reply {
        case status(Int, retryAfter: String? = nil)
        /// The owner's switch on the server is off (ITER-076 stage 9d, № 27).
        case switchedOff
        /// The step's operation and its target, and each noul by name; a
        /// noul not named is 0.
        case answers(operation: String? = nil, target: String? = nil, nouls: [String: Double] = [:])
        /// That answer, this late.
        case after(Duration, Reply)
    }

    private let lock = NSLock()
    private var asked: [Asked] = []
    private var sent: [Data] = []
    private let script: @Sendable (Asked, Int) -> Reply

    /// `script` gets each request and its number, from 0.
    init(_ script: @escaping @Sendable (Asked, Int) -> Reply) {
        self.script = script
    }

    /// Every request so far.
    var requests: [Asked] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    /// Every request's body, byte for byte, as it went out.
    var bodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    /// The loop's engine, asking this Jev with a test license.
    var engine: JevDecisionEngine {
        JevDecisionEngine(jev: JevEngine(licenseKey: { "LICENSE-1" }, send: { try await self.send($0) },
                                         log: { _ in }))
    }

    /// Keeps a request; returns its number.
    private func keep(_ one: Asked) -> Int {
        lock.lock()
        defer { lock.unlock() }
        asked.append(one)
        return asked.count - 1
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        lock.lock()
        sent.append(request.httpBody ?? Data())
        lock.unlock()
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let questions = (body["questions"] as? [String: [String: Any]] ?? [:]).mapValues { question in
            question["type"] as? String == "choice"
                ? ((question["criteria"] as? [String: Any]) ?? [:]).keys.sorted() : []
        }
        let one = Asked(questions: questions, state: body["state"] as? [String: Any] ?? [:])
        var reply = script(one, keep(one))
        while case .after(let delay, let later) = reply {
            try await Task.sleep(for: delay)
            reply = later
        }
        switch reply {
        case .after:
            fatalError("unwrapped above")
        case .status(let code, let retryAfter):
            return (Data(), HTTPURLResponse(url: JevEngine.endpoint, statusCode: code, httpVersion: nil,
                                            headerFields: retryAfter.map { ["Retry-After": $0] })!)
        case .switchedOff:
            return (Data(#"{"error":"agent switched off"}"#.utf8),
                    HTTPURLResponse(url: JevEngine.endpoint, statusCode: 503, httpVersion: nil,
                                    headerFields: ["X-Agent-Switch": "off"])!)
        case .answers(let operation, let target, let nouls):
            var answers: [String: Any] = [:]
            for (name, options) in questions {
                if options.isEmpty {
                    answers[name] = ["type": "noul", "noul": nouls[name] ?? 0]
                    continue
                }
                let chosen: String
                if name == "operation", let operation {
                    chosen = operation
                } else if let operation, name == operation.lowercased() + "_target", let target {
                    chosen = target
                } else {
                    chosen = options[0]
                }
                answers[name] = ["type": "choice", "choice": chosen, "confidence": 0.95,
                                 "probabilities": Dictionary(uniqueKeysWithValues: options.map {
                                     ($0, $0 == chosen ? 1.0 : 0.0)
                                 })]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "model": "jev-1.13.0", "usage": ["input_tokens": 1000, "output_tokens": 20], "answers": answers,
            ])
            return (data, HTTPURLResponse(url: JevEngine.endpoint, statusCode: 200, httpVersion: nil,
                                          headerFields: nil)!)
        }
    }
}

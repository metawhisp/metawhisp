import Foundation
@testable import MetaWhisp

/// The details a form the bench meets is filled from (2026-10-19): a made-up person, never the owner's. The phone
/// is in the 555-01xx range kept for fiction; the address is on the reserved `.test` domain.
enum BenchPersona {
    static let facts = FormFacts(details: [
        "My name is Sam Taylor.", "I am Head of Operations at Acme Robotics.",
        "My work email is sam.taylor@acme-robotics.test.", "My phone number is +1 415 555 0134.",
        "Acme Robotics has 50 employees.", "Acme Robotics is in the United States.",
    ].map { FormFacts.Detail(text: $0, source: .memory) })
}

/// The bench's tasks file (`METAWHISP_BENCH_TASKS`, one JSON object a line with `goal` and `yes_hosts`): the hosts
/// whose questions the bench answers Yes, for each goal. Without it, `METAWHISP_BENCH_YES_HOSTS`, comma-separated.
enum BenchTasks {
    static func yesHosts(for goal: String, in environment: [String: String]) -> [String] {
        let global = (environment["METAWHISP_BENCH_YES_HOSTS"] ?? "").split(separator: ",").map(String.init)
        guard let path = environment["METAWHISP_BENCH_TASKS"], !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return global }
        let wanted = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        for line in text.split(separator: "\n") {
            guard let task = try? CDPValue.decode(String(line)),
                  task["goal"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted else { continue }
            return task["yes_hosts"]?.array?.compactMap(\.string) ?? []
        }
        return global
    }
}

/// One errand's line for the blind set's grader (`grade.py`): what it answered, how it ended, the pages it saw,
/// what the user was asked and answered, whether anything went out, and what it took.
@MainActor
struct BenchResult {
    let goal: String
    let errand: BenchErrand
    let saved: ErrandRecord?

    nonisolated static func ending(_ ending: ErrandRecord.Ending?) -> String {
        switch ending {
        case .done?: "done"
        case .notFinished?, .needsUser?, .stuck?: "not_done"
        case .stopped?, .ceiling?: "stopped"
        case .failed?, .unavailable?, .noPro?, .dailyLimit?, nil: "error"
        }
    }

    var line: String {
        let fields: [String: CDPValue] = [
            "goal": .string(goal),
            "answer": .string(errand.outcome?.answer ?? saved?.answer ?? ""),
            "ending": .string(Self.ending(errand.outcome?.ending ?? saved?.ending)),
            "visited": .array((saved?.seen ?? []).map { CDPValue.string($0) }),
            "asked_yes": .array(errand.questions.map { CDPValue.string($0) }),
            "answers_given": .array(errand.yesGiven.map { .string($0 ? "yes" : "no") }),
            "sent": .bool(saved?.steps.contains { $0.outcome == .confirmed && ["click", "open"].contains($0.operation) } ?? false),
            "steps": .number(Double(saved?.steps.count ?? 0)),
            "seconds": .number(errand.seconds),
            "usd": .number(saved?.spentUSD ?? 0),
        ]
        return ((try? CDPValue.object(fields).encoded()) ?? "{}") + "\n"
    }
}

extension AgentLiveBenchTests {
    static func appendLine(_ line: String, to file: URL) throws {
        let data = Data(line.utf8)
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try data.write(to: file)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

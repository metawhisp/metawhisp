import CryptoKit
import Foundation

/// A prompt with a name and a signature, so a change to it can be pointed at.
///
/// A prompt is the behaviour of this product, and it used to be an anonymous
/// string. One edit to the wording made the agent silent — the flagship case
/// scored 0.00 and reported "nothing to say" — and recovering it took an
/// evening of remembering rather than a query, because the run journal
/// recorded `promptVersion = ""`.
///
/// The signature is derived from the text itself, so it cannot be forgotten:
/// change a word and the signature changes with it. The human part (`v3`) says
/// what someone MEANT to change; the hash says what actually changed.
struct PromptDescriptor {
    let name: String
    /// Bumped by a person when the intent changes. Never load-bearing on its
    /// own — the hash is what proves two runs used the same text.
    let semanticVersion: Int
    /// The text this descriptor describes. Held to compute the signature once.
    private let text: String

    init(name: String, version: Int, text: String) {
        self.name = name
        self.semanticVersion = version
        self.text = text
    }

    /// `insight.v3+a41f2c` — name, intent, and proof.
    var version: String { "\(name).v\(semanticVersion)+\(Self.signature(of: text))" }

    /// SHA-256 truncated. Deliberately not `hashValue`: that is seeded per
    /// process, so the same prompt would sign differently after every relaunch
    /// and the journal could never group runs by the text they used.
    static func signature(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(6).description
    }
}

/// Every prompt the Screen Agent path uses, signed in one place so a run can
/// record which text produced it.
enum ScreenAgentPrompts {

    /// The rule sheet that decides whether the agent speaks at all — the
    /// single-pass route, taken only when there is no screen history to dig
    /// through.
    static let insight = PromptDescriptor(
        name: "insight", version: 1, text: InsightPrompts.systemPrompt)
    /// The route production actually takes. With history in hand the assistant
    /// investigates with tools under a different rule sheet, and signing the
    /// single-pass text for both meant an edit to the real prompt left every
    /// run holding the old signature (Codex).
    static let insightInvestigation = PromptDescriptor(
        name: "insight-investigation", version: 1,
        text: InsightPrompts.investigationSystemPrompt)
    /// The single-window task classifier.
    static let task = PromptDescriptor(
        name: "task", version: 1, text: RealtimeScreenReactor.systemPrompt)
    /// The hourly work analysis.
    static let work = PromptDescriptor(
        name: "work", version: 1, text: ScreenExtractor.systemPrompt)
}

import Foundation

/// Whether a claim describes things only eyes can verify.
///
/// The agent's input is flat OCR — a list of strings with no layout, no color,
/// no control state. The prompts nevertheless asked it to spot the disabled
/// button, the field on the right, the wrongly-selected plan, and the model
/// obliged the only way it could: by inventing. A user who gets told "the
/// Submit button is disabled" when it is not learns the right lesson about the
/// product and the wrong one about ever reading it again.
///
/// Until a claim carries visual evidence from an actual frame, spatial and
/// visual vocabulary makes it undeliverable.
enum ScreenAgentSpatialClaimGuard {

    /// Words that assert layout, color, or control state. Both languages the
    /// product ships in; matched on normalized word boundaries so "красный"
    /// triggers and "прекрасный" does not.
    private static let spatialStems: [String] = [
        // layout
        "left", "right", "above", "below", "top", "bottom", "beside", "corner",
        "слева", "справа", "сверху", "снизу", "выше", "ниже", "углу",
        // color as UI state
        "red", "green", "orange", "highlighted", "greyed", "grayed",
        "красн", "зелен", "оранжев", "подсвечен", "серым",
        // control state only pixels can show
        "disabled", "enabled", "selected", "unselected", "checked", "unchecked",
        "checkbox", "toggled", "collapsed", "expanded",
        "неактивн", "активн", "выделен", "выбран", "отмечен", "свернут", "развернут",
    ]

    /// True when the text makes a claim that flat OCR cannot support.
    static func makesSpatialClaim(_ text: String) -> Bool {
        let words = ScreenAgentEvidence.normalize(text)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.contains { word in
            spatialStems.contains { stem in
                // Stems for the inflected languages, whole words for English —
                // "right" must not fire inside "copyright".
                stem.count < word.count ? word.hasPrefix(stem) : word == stem
            }
        }
    }
}

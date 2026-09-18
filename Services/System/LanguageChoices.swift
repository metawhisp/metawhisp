import Foundation

/// The languages dictation can be set to.
///
/// The list lived privately inside the settings window, so choosing a language
/// meant opening that window — there was nowhere else to do it. Shared here so
/// the menu-bar switcher and Settings offer the same set and cannot drift
/// apart.
enum LanguageChoices {

    struct Choice: Equatable {
        /// What the transcriber is told — a lowercase ISO code.
        let code: String
        /// What the button says.
        let label: String
    }

    static let all: [Choice] = [
        Choice(code: "ru", label: "RU"), Choice(code: "en", label: "EN"),
        Choice(code: "es", label: "ES"), Choice(code: "fr", label: "FR"),
        Choice(code: "de", label: "DE"), Choice(code: "zh", label: "ZH"),
        Choice(code: "ja", label: "JA"), Choice(code: "ko", label: "KO"),
        Choice(code: "pt", label: "PT"), Choice(code: "it", label: "IT"),
        Choice(code: "uk", label: "UK"),
    ]

    /// A code the list does not carry still shows as itself: a blank button
    /// would be worse than an unfamiliar one.
    static func label(for code: String) -> String {
        all.first { $0.code == code }?.label ?? code.uppercased()
    }
}

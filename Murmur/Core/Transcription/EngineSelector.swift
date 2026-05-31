import Foundation

enum EngineSelector {
    /// Languages Parakeet (FluidAudio v2 English + v3 European) handles well.
    static let parakeetLanguages: Set<String> = [
        "en", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "uk", "cs", "sk",
        "ro", "hu", "bg", "hr", "da", "sv", "no", "fi", "el", "ca", "sl", "lt", "lv"
    ]

    /// Pure, testable policy. `osMajor` = macOS major version (e.g. 14, 15, 26).
    /// `appleSupported` = base language codes Apple's DictationTranscriber supports.
    static func resolve(preference: EnginePreference,
                        osMajor: Int,
                        language: String,
                        appleSupported: Set<String>) -> EngineID {
        let lang = baseLanguage(language)

        func automatic() -> EngineID {
            if osMajor >= 26, appleSupported.contains(lang) { return .appleSpeech }
            if parakeetLanguages.contains(lang) { return .parakeet }
            return .whisperKit
        }

        switch preference {
        case .automatic:
            return automatic()
        case .appleSpeech:
            return (osMajor >= 26 && appleSupported.contains(lang)) ? .appleSpeech : automatic()
        case .parakeet:
            return parakeetLanguages.contains(lang) ? .parakeet : automatic()
        case .whisperKit:
            return .whisperKit
        }
    }

    /// "en-US" / "en_US" / "auto" → base code. "auto" maps to "en" for routing.
    static func baseLanguage(_ language: String) -> String {
        if language == "auto" { return "en" }
        let lower = language.lowercased()
        let sep = lower.firstIndex(where: { $0 == "-" || $0 == "_" })
        return sep.map { String(lower[lower.startIndex..<$0]) } ?? lower
    }
}

import XCTest
@testable import Murmur

final class EngineSelectorTests: XCTestCase {
    private let appleLocales: Set<String> = ["en", "es", "fr", "de", "it", "pt", "zh", "ja", "ko", "ar"]

    func test_automatic_onMacOS26_englishLocale_selectsApple() {
        let id = EngineSelector.resolve(preference: .automatic, osMajor: 26, language: "en", appleSupported: appleLocales)
        XCTAssertEqual(id, .appleSpeech)
    }

    func test_automatic_onMacOS15_english_selectsParakeet() {
        let id = EngineSelector.resolve(preference: .automatic, osMajor: 15, language: "en", appleSupported: appleLocales)
        XCTAssertEqual(id, .parakeet)
    }

    func test_automatic_rareLanguage_selectsWhisperKit() {
        let id = EngineSelector.resolve(preference: .automatic, osMajor: 26, language: "cy", appleSupported: appleLocales)
        XCTAssertEqual(id, .whisperKit)
    }

    func test_automatic_europeanLanguage_onOldOS_selectsParakeet() {
        let id = EngineSelector.resolve(preference: .automatic, osMajor: 14, language: "fr", appleSupported: appleLocales)
        XCTAssertEqual(id, .parakeet)
    }

    func test_manualPreference_isHonoredWhenSupported() {
        XCTAssertEqual(EngineSelector.resolve(preference: .whisperKit, osMajor: 26, language: "en", appleSupported: appleLocales), .whisperKit)
        XCTAssertEqual(EngineSelector.resolve(preference: .parakeet, osMajor: 26, language: "en", appleSupported: appleLocales), .parakeet)
    }

    func test_manualApple_onOldOS_fallsBackToAutomatic() {
        let id = EngineSelector.resolve(preference: .appleSpeech, osMajor: 15, language: "en", appleSupported: appleLocales)
        XCTAssertEqual(id, .parakeet)
    }
}

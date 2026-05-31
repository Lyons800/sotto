# Multi-Engine Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Murmur transcribe through WhisperKit, Parakeet (FluidAudio), or Apple SpeechAnalyzer behind one `TranscriptionEngineProtocol`, choosing the best engine automatically per OS/language with a manual override.

**Architecture:** Protocol + factory. A batch-shaped `TranscriptionEngineProtocol` returns the existing `TranscriptionResult` domain type. Three concrete engines conform to it. An `EngineSelector` resolves `(preference, os, language) → engine`; a factory builds the chosen engine; `MurmurApp` and `FileTranscriber` depend only on the protocol. App-layer chunked streaming and file transcription are unchanged because they only call `transcribe(samples:)`.

**Tech Stack:** Swift 5/6, macOS 14+, XCTest. SDKs: WhisperKit 0.17 (existing), FluidAudio ≥0.14.7 (new SPM), Apple `Speech` framework (`SpeechAnalyzer`/`DictationTranscriber`, macOS 26+).

**Test note:** Tests run on the user's Mac via Xcode. Pure-logic tests (Tasks 1–5, 11–12) are fast XCTest unit tests run with `xcodebuild test -scheme Murmur -destination 'platform=macOS'`. Real-engine tests (Tasks 7, 9) are **integration smoke tests** gated behind an env var `MURMUR_RUN_ENGINE_INTEGRATION=1` because they download models and need audio + Apple Silicon. Each test step gives the exact command and expected result; if you are an agent without a Mac, mark engine-integration *execution* as blocked and hand back to the user, but still write the test code.

**Verified API references** (sources captured 2026-05-31): FluidAudio `AsrManager`/`AsrModels`/`TdtDecoderState`/`ASRResult`; Apple `SpeechAnalyzer`/`DictationTranscriber`/`AssetInventory`/`AnalyzerInput`. A few Apple enum case spellings (`.offlineTranscription` preset, `.audioTimeRange`) are unconfirmed — the plan flags them inline as "confirm in Xcode autocomplete."

---

## File Structure

**New files:**
- `Murmur/Core/Transcription/TranscriptionEngineProtocol.swift` — protocol, `EngineID`, `EnginePreference`, `TranscriptionEngineError` (moved here).
- `Murmur/Core/Transcription/WhisperKitEngine.swift` — current `TranscriptionEngine` renamed + conformed. Only file importing WhisperKit.
- `Murmur/Core/Transcription/ParakeetEngine.swift` — FluidAudio wrapper. Only file importing FluidAudio.
- `Murmur/Core/Transcription/AppleSpeechEngine.swift` — `Speech` wrapper, `@available(macOS 26, *)`.
- `Murmur/Core/Transcription/EngineSelector.swift` — selection policy + factory.
- `Murmur/Core/Transcription/ModelManager.swift` — unified per-engine availability/disk view.
- `MurmurTests/Transcription/MockEngine.swift` — test double.
- `MurmurTests/Transcription/EngineSelectorTests.swift`
- `MurmurTests/Transcription/MurmurConfigEngineTests.swift`
- `MurmurTests/Transcription/EngineIntegrationTests.swift` — gated real-engine smoke tests.

**Modified files:**
- `Murmur/Core/TranscriptionEngine.swift` — deleted (content moves to `WhisperKitEngine.swift`).
- `Murmur/Models/MurmurConfig.swift` — add `enginePreference`.
- `Murmur/MurmurApp.swift` — build engine via factory; add Settings→engine bridge (fixes dead `switchModel`).
- `Murmur/Core/FileTranscriber.swift` — depend on protocol, not concrete type.
- `Murmur/UI/SettingsView.swift` — engine picker; wire model/engine change to live engine.
- `WhisprMacOS.xcodeproj/project.pbxproj` — add FluidAudio SPM dependency; add new files to targets.

---

## Phase 1 — The abstraction (pure logic, TDD)

### Task 1: Define the engine protocol and supporting enums

**Files:**
- Create: `Murmur/Core/Transcription/TranscriptionEngineProtocol.swift`
- Test: `MurmurTests/Transcription/EngineSelectorTests.swift` (created in Task 4; this task has no test — it is type definitions only, validated by compile)

- [ ] **Step 1: Create the protocol file**

```swift
import Foundation

/// Identifies which concrete transcription engine produced a result / is selected.
enum EngineID: String, Codable, Sendable, CaseIterable {
    case whisperKit
    case parakeet
    case appleSpeech
}

/// User-facing engine preference stored in config.
enum EnginePreference: String, Codable, Sendable, CaseIterable {
    case automatic
    case whisperKit
    case parakeet
    case appleSpeech
}

/// Errors common to all engines.
enum TranscriptionEngineError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed
    case unsupportedOnThisOS
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Transcription model not loaded"
        case .transcriptionFailed: return "Transcription failed"
        case .unsupportedOnThisOS: return "This engine is not available on this version of macOS"
        case .unsupportedLanguage(let l): return "This engine does not support language: \(l)"
        }
    }
}

/// Batch-shaped engine boundary. App-layer streaming re-calls `transcribe` on
/// accumulated audio, so a batch interface covers dictation streaming and files.
protocol TranscriptionEngineProtocol: AnyObject {
    var identifier: EngineID { get }
    var isModelLoaded: Bool { get }
    /// Load (downloading if needed) the model. `progress` is 0.0...1.0 when known.
    func loadModel(progress: ((Double) -> Void)?) async throws
    /// Transcribe 16 kHz mono float PCM. `promptText` is an optional biasing hint.
    func transcribe(audioSamples: [Float], language: String, promptText: String?) async throws -> TranscriptionResult
    /// Release the loaded model and free memory.
    func unload()
}
```

- [ ] **Step 2: Add the file to the Murmur target** in `project.pbxproj` (or via Xcode: drag into `Core/Transcription` group, ensure "Murmur" target membership).

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -scheme Murmur -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED (the existing `TranscriptionEngineError` in `TranscriptionEngine.swift` will now be duplicate — that's removed in Task 2; if you build before Task 2 you'll get a redeclaration error, so proceed to Task 2 before building, or temporarily comment the old enum).

- [ ] **Step 4: Commit**

```bash
git add Murmur/Core/Transcription/TranscriptionEngineProtocol.swift WhisprMacOS.xcodeproj/project.pbxproj
git commit -m "feat(transcription): add TranscriptionEngineProtocol + engine enums"
```

### Task 2: Refactor current engine into `WhisperKitEngine` conforming to the protocol

**Files:**
- Create: `Murmur/Core/Transcription/WhisperKitEngine.swift`
- Delete: `Murmur/Core/TranscriptionEngine.swift`
- Modify: `Murmur/MurmurApp.swift:101,113` and `Murmur/Core/FileTranscriber.swift:18,23` (update type references — done fully in Tasks 12 & 14; here just keep them compiling via a typealias)

- [ ] **Step 1: Create `WhisperKitEngine.swift` from the existing engine**

Move the full body of `Murmur/Core/TranscriptionEngine.swift` into a new class `WhisperKitEngine`, conform it to the protocol, rename `loadModel(progressCallback:)` to the protocol signature, add `identifier`/`unload`, and REMOVE the now-duplicate `TranscriptionEngineError` (it lives in the protocol file now). Keep `modelNameMap`, `resolvedModelName`, `modelCacheDirectory`, `buildPromptTokens`, `cleanCorruptedMetadata`, and the `TranscriptionResult` mapping exactly as they are.

```swift
import Foundation
import WhisperKit

final class WhisperKitEngine: TranscriptionEngineProtocol {
    let identifier: EngineID = .whisperKit
    private var whisperKit: WhisperKit?
    private(set) var isModelLoaded = false
    private(set) var modelName: String

    init(modelName: String = "base.en") {
        self.modelName = modelName
    }

    static let modelNameMap: [String: String] = [
        // ... copy verbatim from the existing TranscriptionEngine.swift ...
    ]
    private var resolvedModelName: String { Self.modelNameMap[modelName] ?? modelName }
    private static var modelCacheDirectory: URL {
        // ... copy verbatim ...
    }

    func loadModel(progress: ((Double) -> Void)? = nil) async throws {
        // ... copy body of existing loadModel(progressCallback:), renaming the param to `progress` ...
    }

    func transcribe(audioSamples: [Float], language: String = "en", promptText: String? = nil) async throws -> TranscriptionResult {
        // ... copy verbatim from existing transcribe(audioSamples:language:promptText:) ...
    }

    func switchModel(to newModel: String) async throws {
        modelName = newModel
        isModelLoaded = false
        whisperKit = nil
        try await loadModel(progress: nil)
    }

    func unload() {
        whisperKit = nil
        isModelLoaded = false
    }

    private func buildPromptTokens(promptText: String?) -> [Int] { /* copy verbatim */ }
    private static func cleanCorruptedMetadata() { /* copy verbatim */ }
}
```

> Copy the omitted bodies verbatim from the current `Murmur/Core/TranscriptionEngine.swift` (lines 13–24 map, 26–36 cache dir, 38–57 loadModel, 59–114 transcribe, 116–153 helpers). Do not change logic.

- [ ] **Step 2: Delete the old file and add a temporary typealias** so existing call sites keep compiling until Tasks 12/14 update them.

In `WhisperKitEngine.swift`, add at the bottom:
```swift
/// Temporary alias so existing call sites compile until the factory lands (Task 12/14).
typealias TranscriptionEngine = WhisperKitEngine
```
Then delete `Murmur/Core/TranscriptionEngine.swift` and update `project.pbxproj` (remove old file ref, add new file to the Murmur target).

- [ ] **Step 3: Build to verify no behavior change**

Run: `xcodebuild build -scheme Murmur -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED. `MurmurApp` and `FileTranscriber` still compile via the `TranscriptionEngine` typealias; `init(modelName:)` and `transcribe`/`switchModel` signatures are unchanged.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Core/Transcription/WhisperKitEngine.swift WhisprMacOS.xcodeproj/project.pbxproj
git rm Murmur/Core/TranscriptionEngine.swift
git commit -m "refactor(transcription): extract WhisperKitEngine behind protocol (no behavior change)"
```

### Task 3: Add `MockEngine` test double

**Files:**
- Create: `MurmurTests/Transcription/MockEngine.swift`

- [ ] **Step 1: Write the mock**

```swift
import Foundation
@testable import Murmur

final class MockEngine: TranscriptionEngineProtocol {
    let identifier: EngineID
    private(set) var isModelLoaded = false
    var loadShouldThrow: Error?
    var transcribeShouldThrow: Error?
    var stubbedResult: TranscriptionResult
    private(set) var transcribeCallCount = 0
    private(set) var lastLanguage: String?

    init(identifier: EngineID = .whisperKit,
         stubbedText: String = "hello world") {
        self.identifier = identifier
        self.stubbedResult = TranscriptionResult(text: stubbedText, duration: 0.1, language: "en", segments: [])
    }

    func loadModel(progress: ((Double) -> Void)?) async throws {
        if let loadShouldThrow { throw loadShouldThrow }
        progress?(1.0)
        isModelLoaded = true
    }

    func transcribe(audioSamples: [Float], language: String, promptText: String?) async throws -> TranscriptionResult {
        transcribeCallCount += 1
        lastLanguage = language
        if let transcribeShouldThrow { throw transcribeShouldThrow }
        return stubbedResult
    }

    func unload() { isModelLoaded = false }
}
```

- [ ] **Step 2: Add to the MurmurTests target** in `project.pbxproj` (or Xcode target membership = MurmurTests only).

- [ ] **Step 3: Build the test target**

Run: `xcodebuild build-for-testing -scheme Murmur -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add MurmurTests/Transcription/MockEngine.swift WhisprMacOS.xcodeproj/project.pbxproj
git commit -m "test(transcription): add MockEngine test double"
```

### Task 4: `EngineSelector` selection policy (TDD)

**Files:**
- Create: `Murmur/Core/Transcription/EngineSelector.swift`
- Test: `MurmurTests/Transcription/EngineSelectorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Murmur

final class EngineSelectorTests: XCTestCase {
    // Apple-supported locale list is injected so tests don't depend on the host OS.
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
        // Welsh: not Apple-supported, not European-Parakeet set → WhisperKit tail.
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
        // User pinned Apple but OS < 26 → fall back to automatic resolution.
        let id = EngineSelector.resolve(preference: .appleSpeech, osMajor: 15, language: "en", appleSupported: appleLocales)
        XCTAssertEqual(id, .parakeet)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/EngineSelectorTests -quiet`
Expected: FAIL — `EngineSelector` is undefined.

- [ ] **Step 3: Implement `EngineSelector.resolve`**

```swift
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
            // Honor only if actually available, else fall back to automatic.
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/EngineSelectorTests -quiet`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Murmur/Core/Transcription/EngineSelector.swift MurmurTests/Transcription/EngineSelectorTests.swift WhisprMacOS.xcodeproj/project.pbxproj
git commit -m "feat(transcription): add EngineSelector policy with tests"
```

### Task 5: Add `enginePreference` to `MurmurConfig` (TDD migration)

**Files:**
- Modify: `Murmur/Models/MurmurConfig.swift`
- Test: `MurmurTests/Transcription/MurmurConfigEngineTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Murmur

final class MurmurConfigEngineTests: XCTestCase {
    func test_defaultEnginePreference_isAutomatic() {
        XCTAssertEqual(MurmurConfig().enginePreference, .automatic)
    }

    func test_decodingLegacyConfigWithoutEngineField_defaultsToAutomatic() throws {
        // Simulate an old stored config JSON that has no enginePreference key.
        let legacy = #"{"modelName":"base.en","language":"en"}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        let config = try decoder.decode(MurmurConfig.self, from: legacy)
        XCTAssertEqual(config.enginePreference, .automatic)
        XCTAssertEqual(config.modelName, "base.en")
    }
}
```

> If `MurmurConfig` is not currently `Codable`, check `Murmur/Models/MurmurConfig.swift` first. The audit confirms config is stored in UserDefaults as `murmur_config`; if it uses `Codable`, this test applies as-is. If it uses manual UserDefaults keys, replace Step 1's decode test with a test that constructs the struct and asserts the default, and add a decode-default test matching the real persistence path.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/MurmurConfigEngineTests -quiet`
Expected: FAIL — `enginePreference` undefined.

- [ ] **Step 3: Add the field with a defaulting decoder**

In `Murmur/Models/MurmurConfig.swift`, add the property near `modelName`/`language`:
```swift
var enginePreference: EnginePreference = .automatic
```
Ensure backward-compatible decoding. If the struct relies on synthesized `Codable`, add an explicit `init(from:)` that defaults missing keys:
```swift
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.modelName = try c.decodeIfPresent(String.self, forKey: .modelName) ?? "base.en"
    self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
    self.enginePreference = try c.decodeIfPresent(EnginePreference.self, forKey: .enginePreference) ?? .automatic
    // ... decodeIfPresent for every other existing field with its current default ...
}
```
> Read the current property list in `MurmurConfig.swift` and include EVERY existing field in this initializer with its existing default, or synthesized decoding for other fields will break. If the struct already has a custom `init(from:)`, just add the one `enginePreference` line.

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/MurmurConfigEngineTests -quiet`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Murmur/Models/MurmurConfig.swift MurmurTests/Transcription/MurmurConfigEngineTests.swift WhisprMacOS.xcodeproj/project.pbxproj
git commit -m "feat(config): add enginePreference with backward-compatible default"
```

---

## Phase 2 — Real engines

### Task 6: Add the FluidAudio SPM dependency

**Files:**
- Modify: `WhisprMacOS.xcodeproj/project.pbxproj` (+ `project.xcworkspace/.../Package.resolved`)

- [ ] **Step 1: Add the package in Xcode**

File → Add Package Dependencies → `https://github.com/FluidInference/FluidAudio.git` → Dependency Rule: "Up to Next Major" from `0.14.7` → Add `FluidAudio` product to the **Murmur** target only.

- [ ] **Step 2: Verify it resolves and builds**

Run: `xcodebuild -resolvePackageDependencies -scheme Murmur` then `xcodebuild build -scheme Murmur -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED; `Package.resolved` now lists `FluidAudio`.

- [ ] **Step 3: Commit**

```bash
git add WhisprMacOS.xcodeproj/project.pbxproj WhisprMacOS.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "build(deps): add FluidAudio SPM dependency"
```

### Task 7: `ParakeetEngine` (FluidAudio wrapper)

**Files:**
- Create: `Murmur/Core/Transcription/ParakeetEngine.swift`
- Test: `MurmurTests/Transcription/EngineIntegrationTests.swift` (gated smoke test)

- [ ] **Step 1: Implement the engine using the verified FluidAudio API**

```swift
import Foundation
import FluidAudio

/// Parakeet TDT 0.6B via FluidAudio. 16 kHz mono float PCM. Apple Silicon only.
final class ParakeetEngine: TranscriptionEngineProtocol {
    let identifier: EngineID = .parakeet
    private var manager: AsrManager?
    private var models: AsrModels?
    private(set) var isModelLoaded = false

    /// v3 = multilingual/European, v2 = English-only. Default v3.
    private let version: AsrModelVersion

    init(version: AsrModelVersion = .v3) {
        self.version = version
    }

    func loadModel(progress: ((Double) -> Void)?) async throws {
        // FluidAudio downloads to its own cache; progressHandler reports download.
        let loaded = try await AsrModels.downloadAndLoad(
            version: version,
            progressHandler: { p in progress?(p) }   // confirm closure signature in Xcode: DownloadUtils.ProgressHandler
        )
        let mgr = AsrManager(config: .default)
        try await mgr.loadModels(loaded)
        self.models = loaded
        self.manager = mgr
        self.isModelLoaded = true
    }

    func transcribe(audioSamples: [Float], language: String, promptText: String?) async throws -> TranscriptionResult {
        guard let manager else { throw TranscriptionEngineError.modelNotLoaded }
        var state = TdtDecoderState.make()                 // required inout decoder state
        let start = Date()
        let result = try await manager.transcribe(audioSamples, decoderState: &state)
        let duration = Date().timeIntervalSince(start)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Parakeet returns token-level timings, not sentence segments → empty segments is fine.
        return TranscriptionResult(text: text, duration: duration, language: language, segments: [])
    }

    func unload() {
        manager = nil
        models = nil
        isModelLoaded = false
    }
}
```

> Notes from API verification: `AsrManager` is an actor (all calls `await`). The bare `transcribe(samples)` shown in FluidAudio's README does NOT exist — you MUST pass `decoderState: inout`. `promptText` is intentionally unused (Parakeet has no prompt-biasing API in v1 scope). Confirm `progressHandler` label/closure type via Xcode autocomplete; if it differs, pass `nil` and call `progress?(1.0)` after load.

- [ ] **Step 2: Write the gated integration smoke test**

```swift
import XCTest
@testable import Murmur

/// Real-engine smoke tests. Run only when MURMUR_RUN_ENGINE_INTEGRATION=1
/// (downloads models, needs Apple Silicon + a bundled test WAV at 16kHz mono).
final class EngineIntegrationTests: XCTestCase {
    private var shouldRun: Bool { ProcessInfo.processInfo.environment["MURMUR_RUN_ENGINE_INTEGRATION"] == "1" }

    /// 16kHz mono PCM of a known phrase, added to the MurmurTests bundle as Resources/hello.wav.
    private func loadSamples() throws -> [Float] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "hello", withExtension: "wav"))
        return try AudioTestUtil.float16kMono(from: url)   // small helper added alongside this test
    }

    func test_parakeet_transcribesKnownPhrase() async throws {
        try XCTSkipUnless(shouldRun, "Set MURMUR_RUN_ENGINE_INTEGRATION=1 to run engine integration tests")
        let engine = ParakeetEngine(version: .v2)   // English-only is smaller/faster for CI
        try await engine.loadModel(progress: nil)
        let result = try await engine.transcribe(audioSamples: try loadSamples(), language: "en", promptText: nil)
        XCTAssertTrue(result.text.lowercased().contains("hello"), "got: \(result.text)")
    }
}
```

> Add `AudioTestUtil.float16kMono(from:)` (an AVAudioFile → 16 kHz mono `[Float]` converter, ~20 lines using `AVAudioConverter`) and a short `hello.wav` resource to the MurmurTests target. Keep the WAV < 1 s and clearly spoken.

- [ ] **Step 3: Run the gated test (on a Mac)**

Run: `MURMUR_RUN_ENGINE_INTEGRATION=1 xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/EngineIntegrationTests/test_parakeet_transcribesKnownPhrase`
Expected: PASS (first run downloads the Parakeet model — may take minutes). Without the env var the test SKIPS.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Core/Transcription/ParakeetEngine.swift MurmurTests/Transcription/EngineIntegrationTests.swift MurmurTests/Resources/hello.wav WhisprMacOS.xcodeproj/project.pbxproj
git commit -m "feat(transcription): add ParakeetEngine (FluidAudio) + integration smoke test"
```

### Task 8: `AppleSpeechEngine` (SpeechAnalyzer wrapper, macOS 26+)

**Files:**
- Create: `Murmur/Core/Transcription/AppleSpeechEngine.swift`
- Test: extend `MurmurTests/Transcription/EngineIntegrationTests.swift`

- [ ] **Step 1: Implement the engine using the verified Speech API**

```swift
import Foundation
import Speech
import AVFoundation
import CoreMedia

/// Apple on-device dictation via SpeechAnalyzer + DictationTranscriber (macOS 26+).
@available(macOS 26.0, *)
final class AppleSpeechEngine: TranscriptionEngineProtocol {
    let identifier: EngineID = .appleSpeech
    private(set) var isModelLoaded = false
    private let localeID: String

    init(localeID: String = "en-US") {
        self.localeID = localeID
    }

    func loadModel(progress: ((Double) -> Void)?) async throws {
        let locale = Locale(identifier: localeID)
        let transcriber = makeTranscriber(locale: locale)
        if !DictationTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()   // observe request.progress on a Task for UI if desired
            }
        }
        _ = try await AssetInventory.reserve(locale: locale)
        progress?(1.0)
        isModelLoaded = true
    }

    func transcribe(audioSamples: [Float], language: String, promptText: String?) async throws -> TranscriptionResult {
        let locale = Locale(identifier: localeID)
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionEngineError.transcriptionFailed
        }
        let buffer = try Self.makeBuffer(samples: audioSamples, sourceSampleRate: 16_000, targetFormat: analyzerFormat)

        let start = Date()
        let collector = Task { () -> String in
            var acc = AttributedString()
            for try await result in transcriber.results where result.isFinal {
                acc.append(result.text)
            }
            return String(acc.characters)
        }

        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputSequence)
        inputBuilder.yield(AnalyzerInput(buffer: buffer))
        inputBuilder.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let text = try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(text: text, duration: Date().timeIntervalSince(start), language: language, segments: [])
    }

    func unload() { isModelLoaded = false }

    private func makeTranscriber(locale: Locale) -> DictationTranscriber {
        // Confirm option case spellings in Xcode: `.volatileResults` is verified;
        // attributeOptions left empty here to avoid the unconfirmed `.audioTimeRange` spelling.
        DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    /// Convert 16 kHz mono [Float] to an AVAudioPCMBuffer in the analyzer's required format.
    private static func makeBuffer(samples: [Float], sourceSampleRate: Double, targetFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceSampleRate, channels: 1, interleaved: false)!
        let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        srcBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { srcBuffer.floatChannelData!.pointee.update(from: $0.baseAddress!, count: samples.count) }
        guard srcFormat != targetFormat else { return srcBuffer }
        let converter = AVAudioConverter(from: srcFormat, to: targetFormat)!
        let ratio = targetFormat.sampleRate / srcFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)!
        var fed = false
        var err: NSError?
        converter.convert(to: outBuffer, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return srcBuffer
        }
        if let err { throw err }
        return outBuffer
    }
}
```

> API-verification caveats baked in: `SpeechAnalyzer`/`DictationTranscriber` are `@available(macOS 26)`. `.volatileResults` is confirmed; `.audioTimeRange` was NOT confirmed, so `attributeOptions: []` is used to stay safe. Confirm `Locale.identifier(.bcp47)` availability or fall back to `$0.identifier == locale.identifier`. Confirm `AVAudioConverter` single-shot pattern compiles. This engine never compiles into the macOS 14 path because it's `@available`-gated and only instantiated behind `if #available(macOS 26, *)` in the factory (Task 9).

- [ ] **Step 2: Add a gated integration test (guarded by availability)**

```swift
func test_appleSpeech_transcribesKnownPhrase() async throws {
    try XCTSkipUnless(shouldRun, "Set MURMUR_RUN_ENGINE_INTEGRATION=1")
    guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26+") }
    let engine = AppleSpeechEngine(localeID: "en-US")
    try await engine.loadModel(progress: nil)
    let result = try await engine.transcribe(audioSamples: try loadSamples(), language: "en", promptText: nil)
    XCTAssertTrue(result.text.lowercased().contains("hello"), "got: \(result.text)")
}
```

- [ ] **Step 3: Run on a macOS 26 machine**

Run: `MURMUR_RUN_ENGINE_INTEGRATION=1 xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/EngineIntegrationTests/test_appleSpeech_transcribesKnownPhrase`
Expected: PASS on macOS 26+ (first run downloads the locale asset); SKIP on older OS or without the env var.

- [ ] **Step 4: Commit**

```bash
git add Murmur/Core/Transcription/AppleSpeechEngine.swift MurmurTests/Transcription/EngineIntegrationTests.swift WhisprMacOS.xcodeproj/project.pbxproj
git commit -m "feat(transcription): add AppleSpeechEngine (SpeechAnalyzer, macOS 26+)"
```

---

## Phase 3 — Wiring

### Task 9: Engine factory

**Files:**
- Modify: `Murmur/Core/Transcription/EngineSelector.swift` (add factory)
- Test: `MurmurTests/Transcription/EngineSelectorTests.swift` (add factory-returns-correct-type tests)

- [ ] **Step 1: Write failing factory tests**

```swift
func test_factory_buildsWhisperKitEngine() {
    let e = EngineSelector.makeEngine(id: .whisperKit, modelName: "base.en", localeID: "en-US")
    XCTAssertEqual(e.identifier, .whisperKit)
}
func test_factory_buildsParakeetEngine() {
    let e = EngineSelector.makeEngine(id: .parakeet, modelName: "base.en", localeID: "en-US")
    XCTAssertEqual(e.identifier, .parakeet)
}
func test_factory_appleOnOldOS_fallsBackToParakeetOrWhisper() {
    // makeEngine for .appleSpeech on <26 must not crash; returns a usable non-Apple engine.
    let e = EngineSelector.makeEngine(id: .appleSpeech, modelName: "base.en", localeID: "en-US")
    XCTAssertNotEqual(e.identifier, .appleSpeech) // because test host is <26; on 26 host, adjust expectation
}
```

> The third assertion depends on the host OS. If CI runs on macOS 26, invert it. Prefer gating: `if #available(macOS 26, *) { XCTAssertEqual(e.identifier, .appleSpeech) } else { XCTAssertNotEqual(e.identifier, .appleSpeech) }`.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/EngineSelectorTests -quiet`
Expected: FAIL — `makeEngine` undefined.

- [ ] **Step 3: Implement the factory**

```swift
extension EngineSelector {
    /// Build a concrete engine for an EngineID. Falls back off Apple on macOS < 26.
    static func makeEngine(id: EngineID, modelName: String, localeID: String) -> TranscriptionEngineProtocol {
        switch id {
        case .whisperKit:
            return WhisperKitEngine(modelName: modelName)
        case .parakeet:
            return ParakeetEngine(version: .v3)
        case .appleSpeech:
            if #available(macOS 26.0, *) {
                return AppleSpeechEngine(localeID: localeID)
            } else {
                // Should not happen (selector gates), but be safe.
                return ParakeetEngine(version: .v3)
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/EngineSelectorTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Murmur/Core/Transcription/EngineSelector.swift MurmurTests/Transcription/EngineSelectorTests.swift
git commit -m "feat(transcription): add engine factory"
```

### Task 10: Wire the factory into `MurmurApp` + Settings→engine bridge (fixes dead switchModel)

**Files:**
- Modify: `Murmur/MurmurApp.swift` (engine construction ~line 101/113; add reload-on-settings-change)

- [ ] **Step 1: Replace direct engine construction with factory-based selection**

In `MurmurApp`, change the engine property type to the protocol and build it from config:
```swift
let transcriptionEngine: TranscriptionEngineProtocol
```
In `init`, resolve and build:
```swift
let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
let appleSupported: Set<String> = Self.appleSupportedBaseLanguages()  // see Step 2
let id = EngineSelector.resolve(preference: config.enginePreference,
                                osMajor: osMajor,
                                language: config.language,
                                appleSupported: appleSupported)
self.transcriptionEngine = EngineSelector.makeEngine(id: id, modelName: config.modelName, localeID: Self.localeID(for: config.language))
```

- [ ] **Step 2: Add the Apple-supported-language probe**

```swift
static func appleSupportedBaseLanguages() -> Set<String> {
    if #available(macOS 26.0, *) {
        return Set(DictationTranscriber.supportedLocales.map { EngineSelector.baseLanguage($0.identifier) })
    }
    return []
}
static func localeID(for language: String) -> String {
    language == "auto" || language == "en" ? "en-US" : language
}
```
> Wrap the `import Speech`-dependent code so it only compiles in the gated branch; `DictationTranscriber` is `@available(macOS 26)`. Add `import Speech` at top of `MurmurApp.swift` (the `@available` guards keep it safe on 14).

- [ ] **Step 3: Add a live engine-rebuild path (fixes the dead `switchModel`/`updateHotkey` bug)**

Add a method and have Settings call it on change (bridge via NotificationCenter, matching existing app patterns):
```swift
func reloadEngineFromConfig() {
    let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    let id = EngineSelector.resolve(preference: config.enginePreference, osMajor: osMajor,
                                    language: config.language, appleSupported: Self.appleSupportedBaseLanguages())
    let newEngine = EngineSelector.makeEngine(id: id, modelName: config.modelName, localeID: Self.localeID(for: config.language))
    Task { @MainActor in
        self.transcriptionEngine.unload()
        self.transcriptionEngine = newEngine        // make the property `var` if currently `let`
        try? await newEngine.loadModel(progress: nil)
    }
}
```
Register an observer in `init` for a `.murmurEngineConfigChanged` notification that calls `reloadEngineFromConfig()`.

- [ ] **Step 4: Build + run existing tests**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests -quiet`
Expected: BUILD SUCCEEDED, all unit tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Murmur/MurmurApp.swift
git commit -m "feat(transcription): select+build engine from config; live reload on settings change"
```

### Task 11: `FileTranscriber` depends on the protocol

**Files:**
- Modify: `Murmur/Core/FileTranscriber.swift:18,23`

- [ ] **Step 1: Change the dependency type**

```swift
private let transcriptionEngine: TranscriptionEngineProtocol
init(transcriptionEngine: TranscriptionEngineProtocol) { self.transcriptionEngine = transcriptionEngine }
```
No other change — it already only calls `transcribe(...)`.

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Murmur -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Murmur/Core/FileTranscriber.swift
git commit -m "refactor(files): FileTranscriber depends on TranscriptionEngineProtocol"
```

### Task 12: Remove the temporary typealias

**Files:**
- Modify: `Murmur/Core/Transcription/WhisperKitEngine.swift` (remove the `typealias` from Task 2)

- [ ] **Step 1: Delete the alias and fix any remaining references**

Remove `typealias TranscriptionEngine = WhisperKitEngine`. Grep for stragglers:
Run: `grep -rn "TranscriptionEngine\b" Murmur/ | grep -v TranscriptionEngineProtocol | grep -v TranscriptionEngineError`
Replace any remaining `TranscriptionEngine(` constructions with the factory or `WhisperKitEngine(` as appropriate (there should be none after Tasks 10–11).

- [ ] **Step 2: Build**

Run: `xcodebuild build -scheme Murmur -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Murmur/Core/Transcription/WhisperKitEngine.swift
git commit -m "refactor(transcription): drop temporary TranscriptionEngine typealias"
```

### Task 13: `ModelManager` unified per-engine view

**Files:**
- Create: `Murmur/Core/Transcription/ModelManager.swift`
- Test: `MurmurTests/Transcription/ModelManagerTests.swift`

- [ ] **Step 1: Write the failing test (pure summary logic only)**

```swift
import XCTest
@testable import Murmur

final class ModelManagerTests: XCTestCase {
    func test_engineAvailability_appleUnavailableBelowMacOS26() {
        let avail = ModelManager.availability(osMajor: 15)
        XCTAssertFalse(avail[.appleSpeech] ?? true)
        XCTAssertTrue(avail[.whisperKit] ?? false)
        XCTAssertTrue(avail[.parakeet] ?? false)
    }
    func test_engineAvailability_appleAvailableOnMacOS26() {
        let avail = ModelManager.availability(osMajor: 26)
        XCTAssertTrue(avail[.appleSpeech] ?? false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/ModelManagerTests -quiet`
Expected: FAIL — `ModelManager` undefined.

- [ ] **Step 3: Implement the pure availability map (UI consumes this)**

```swift
import Foundation

enum ModelManager {
    /// Which engines are usable on this OS major version (pure, testable).
    static func availability(osMajor: Int) -> [EngineID: Bool] {
        [
            .whisperKit: true,
            .parakeet: true,       // Apple Silicon checked at load time
            .appleSpeech: osMajor >= 26
        ]
    }

    static func displayName(_ id: EngineID) -> String {
        switch id {
        case .whisperKit: return "WhisperKit (99 languages)"
        case .parakeet: return "Parakeet — fastest, English/European"
        case .appleSpeech: return "Apple Dictation (macOS 26+)"
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/ModelManagerTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Murmur/Core/Transcription/ModelManager.swift MurmurTests/Transcription/ModelManagerTests.swift WhisprMacOS.xcodeproj/project.pbxproj
git commit -m "feat(transcription): add ModelManager availability map"
```

### Task 14: Settings UI — engine picker

**Files:**
- Modify: `Murmur/UI/SettingsView.swift`

- [ ] **Step 1: Add the engine picker bound to config**

In the Transcription section of `SettingsView`, add:
```swift
Picker("Engine", selection: $config.enginePreference) {
    Text("Recommended (Automatic)").tag(EnginePreference.automatic)
    let avail = ModelManager.availability(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    Text(ModelManager.displayName(.parakeet)).tag(EnginePreference.parakeet)
    Text(ModelManager.displayName(.whisperKit)).tag(EnginePreference.whisperKit)
    Text(ModelManager.displayName(.appleSpeech))
        .tag(EnginePreference.appleSpeech)
        .disabled(!(avail[.appleSpeech] ?? false))
}
.onChange(of: config.enginePreference) { _, _ in
    persistConfig()                                   // existing save path
    NotificationCenter.default.post(name: .murmurEngineConfigChanged, object: nil)
}
```
Show the existing WhisperKit model sub-picker only when `config.enginePreference == .whisperKit || config.enginePreference == .automatic`. Wire its `.onChange` to also post `.murmurEngineConfigChanged` (this is what finally makes model changes apply live — fixing the dead `switchModel`).

- [ ] **Step 2: Define the notification name** (e.g. in `MurmurApp.swift` or a small `Notifications.swift`):
```swift
extension Notification.Name { static let murmurEngineConfigChanged = Notification.Name("murmurEngineConfigChanged") }
```

- [ ] **Step 3: Build and launch to verify the picker appears and switching triggers a reload**

Run: `xcodebuild build -scheme Murmur -destination 'platform=macOS' -quiet` then run the app from Xcode, open Settings → Transcription, switch engine, confirm `[Murmur]` logs show an engine reload and transcription still works.
Expected: BUILD SUCCEEDED; engine switch reloads without a restart.

- [ ] **Step 4: Commit**

```bash
git add Murmur/UI/SettingsView.swift Murmur/MurmurApp.swift
git commit -m "feat(ui): add engine picker to Settings; apply engine/model changes live"
```

---

## Phase 4 — Verification

### Task 15: Full build, test, and manual smoke checklist

- [ ] **Step 1: Full unit-test run**

Run: `xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests -quiet`
Expected: all unit tests PASS (EngineSelector, MurmurConfig, ModelManager; engine-integration tests SKIP without the env var).

- [ ] **Step 2: Engine-integration run (on Apple Silicon; Apple test only on macOS 26)**

Run: `MURMUR_RUN_ENGINE_INTEGRATION=1 xcodebuild test -scheme Murmur -destination 'platform=macOS' -only-testing:MurmurTests/EngineIntegrationTests`
Expected: Parakeet PASS; Apple PASS on macOS 26 (else SKIP).

- [ ] **Step 3: Manual smoke (run the app)**

Verify each against `docs/superpowers/specs/2026-05-31-multi-engine-transcription-design.md` success criteria:
1. With `Automatic` + English on your macOS 26 machine → Apple engine selected (check `[Murmur]` log), dictation works.
2. Override to Parakeet → reloads, dictation works, noticeably better than base.en.
3. Override to WhisperKit + a non-English language → works.
4. File transcription still works.
5. Existing config (no enginePreference) loads and defaults to Automatic.
6. DMG size unchanged (no bundled models) — `du -sh` the built `.app`.

- [ ] **Step 4: Final commit / open PR**

```bash
git add -A && git commit -m "test(transcription): full multi-engine verification pass"
git push -u origin feature/multi-engine-transcription
gh pr create --fill --base main
```

---

## Self-Review (completed by author)

- **Spec coverage:** §1 boundary→Task 1; §2 engines→Tasks 2,7,8; §3 selection/config/migration→Tasks 4,5,9,10; §4 model mgmt→Task 13; §5 UI→Task 14; §6 testing→Tasks 3,4,5,7,8,13; §7 error handling→`TranscriptionEngineError` (Task 1) + factory fallback (Task 9) + selector fallback (Task 4). All covered.
- **Placeholder scan:** engine bodies that say "copy verbatim" reference exact line ranges in the existing file (no logic invented); all new logic has full code. Apple/FluidAudio uncertainties are explicitly flagged with "confirm in Xcode," not left vague.
- **Type consistency:** `TranscriptionEngineProtocol` method names (`loadModel(progress:)`, `transcribe(audioSamples:language:promptText:)`, `unload()`, `identifier`, `isModelLoaded`) are identical across Tasks 1,2,3,7,8; `EngineSelector.resolve`/`makeEngine`, `EnginePreference`, `EngineID`, `.murmurEngineConfigChanged` consistent throughout.
- **Known risk:** exact Apple `Speech` enum spellings and FluidAudio `progressHandler` closure type need Xcode confirmation at implementation time (flagged inline). These are the only non-deterministic spots.

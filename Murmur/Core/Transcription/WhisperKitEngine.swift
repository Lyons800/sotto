import WhisperKit
import Foundation

final class WhisperKitEngine: TranscriptionEngineProtocol {
    let identifier: EngineID = .whisperKit
    private var whisperKit: WhisperKit?
    private(set) var isModelLoaded = false
    private(set) var modelName: String

    init(modelName: String = "base.en") {
        self.modelName = modelName
    }

    /// Maps user-facing short names to WhisperKit model identifiers
    static let modelNameMap: [String: String] = [
        "tiny": "openai_whisper-tiny",
        "tiny.en": "openai_whisper-tiny.en",
        "base": "openai_whisper-base",
        "base.en": "openai_whisper-base.en",
        "small": "openai_whisper-small",
        "small.en": "openai_whisper-small.en",
        "medium": "openai_whisper-medium",
        "medium.en": "openai_whisper-medium.en",
        "large-v3": "openai_whisper-large-v3",
    ]

    private var resolvedModelName: String {
        Self.modelNameMap[modelName] ?? modelName
    }

    /// Dedicated, writable directory for WhisperKit models
    private static var modelCacheDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport.appendingPathComponent("Murmur/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return modelsDir
    }

    func loadModel(progress: ((Double) -> Void)? = nil) async throws {
        // Clean any corrupted metadata files before attempting download
        Self.cleanCorruptedMetadata()

        let config = WhisperKitConfig(
            model: resolvedModelName,
            downloadBase: Self.modelCacheDirectory,
            verbose: true,
            logLevel: .debug,
            prewarm: false,
            load: true,
            download: true
        )

        NSLog("[Murmur] WhisperKit init with model: \(resolvedModelName), downloadBase: \(Self.modelCacheDirectory.path)")

        let kit = try await WhisperKit(config)
        whisperKit = kit
        isModelLoaded = true
    }

    func transcribe(audioSamples: [Float], language: String = "en", promptText: String? = nil) async throws -> TranscriptionResult {
        guard let whisperKit else {
            throw TranscriptionEngineError.modelNotLoaded
        }

        let promptTokens = buildPromptTokens(promptText: promptText)
        let options: DecodingOptions
        if !promptTokens.isEmpty {
            options = DecodingOptions(
                language: language,
                temperature: 0.0,
                detectLanguage: language == "auto",
                promptTokens: promptTokens
            )
        } else {
            options = DecodingOptions(
                language: language,
                temperature: 0.0,
                detectLanguage: language == "auto"
            )
        }

        let start = Date()
        let results = try await whisperKit.transcribe(audioArray: audioSamples, decodeOptions: options)

        guard !results.isEmpty else {
            throw TranscriptionEngineError.transcriptionFailed
        }

        let duration = Date().timeIntervalSince(start)
        let fullText = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        let segments = results.flatMap { result in
            result.segments.map { segment in
                TranscriptionResult.Segment(
                    text: segment.text,
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end)
                )
            }
        }

        return TranscriptionResult(
            text: fullText,
            duration: duration,
            language: language,
            segments: segments
        )
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

    /// Build prompt tokens from a text hint string for WhisperKit's conditional generation.
    /// Returns nil if no prompt text is provided (WhisperKit will use no prompt).
    private func buildPromptTokens(promptText: String?) -> [Int] {
        guard let promptText, !promptText.isEmpty, let whisperKit, let tokenizer = whisperKit.tokenizer else {
            return []
        }
        let tokens = tokenizer.encode(text: promptText)
        // Filter out special tokens to avoid confusing the model
        return tokens.filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    }

    /// Remove any corrupted .metadata files from the cache directory
    private static func cleanCorruptedMetadata() {
        let fm = FileManager.default
        let cacheDir = modelCacheDirectory

        guard let enumerator = fm.enumerator(at: cacheDir, includingPropertiesForKeys: nil) else { return }

        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "metadata" {
                try? fm.removeItem(at: url)
                NSLog("[Murmur] Removed metadata file: \(url.lastPathComponent)")
            }
        }

        // Also clean the default HuggingFace cache in Documents
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let hfDir = documents.appendingPathComponent("huggingface")
        if let hfEnum = fm.enumerator(at: hfDir, includingPropertiesForKeys: nil) {
            while let url = hfEnum.nextObject() as? URL {
                if url.pathExtension == "metadata" {
                    try? fm.removeItem(at: url)
                    NSLog("[Murmur] Removed HF metadata file: \(url.lastPathComponent)")
                }
            }
        }
    }
}


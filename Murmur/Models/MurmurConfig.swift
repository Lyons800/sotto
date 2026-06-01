import Foundation
import Carbon.HIToolbox

enum RecordingMode: String, CaseIterable, Codable {
    case hold = "Hold to Record"
    case toggle = "Toggle Recording"
}

struct MurmurConfig: Codable {
    var modelName: String = "base.en"
    var language: String = "en"
    var recordingMode: RecordingMode = .hold
    var hotkeyKeyCode: UInt16 = UInt16(kVK_RightOption)
    var hotkeyModifiers: UInt = 0
    var playSounds: Bool = true
    var autoCapitalize: Bool = true
    var convertPunctuation: Bool = true
    var removeFiller: Bool = false
    var clipboardRestoreDelay: TimeInterval = 0.2
    var useStreaming: Bool = true
    var llmEnabled: Bool = false
    var launchAtLogin: Bool = false
    var dictionaryEntries: [DictionaryEntry] = []
    var historyEnabled: Bool = true
    var smartModes: [SmartMode] = SmartMode.defaults
    var muteMediaDuringRecording: Bool = false
    var enginePreference: EnginePreference = .automatic
    var commandBrainProvider: BrainProvider = .byok

    static let `default` = MurmurConfig()

    private static let storageKey = "murmur_config"
    private static let legacyStorageKey = "whispr_config"

    static func load() -> MurmurConfig {
        // Try new key first, then fall back to legacy key for migration
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let config = try? JSONDecoder().decode(MurmurConfig.self, from: data) {
            return config
        }
        if let data = UserDefaults.standard.data(forKey: legacyStorageKey),
           let config = try? JSONDecoder().decode(MurmurConfig.self, from: data) {
            // Migrate: save under new key and remove old
            config.save()
            UserDefaults.standard.removeObject(forKey: legacyStorageKey)
            return config
        }
        return .default
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: MurmurConfig.storageKey)
        }
    }
}

// MARK: - Backward-compatible decoding
// Placed in an extension so the struct retains its synthesized memberwise init().
// A custom init(from:) inside the struct body would suppress memberwise init synthesis,
// breaking callers such as `MurmurConfig()` and `MurmurConfig.default`.
// Using decodeIfPresent for every field means legacy configs (persisted before any
// given field was added) still decode successfully instead of throwing keyNotFound
// and losing the user's entire saved configuration.
extension MurmurConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelName                = try c.decodeIfPresent(String.self,             forKey: .modelName)                ?? "base.en"
        language                 = try c.decodeIfPresent(String.self,             forKey: .language)                 ?? "en"
        recordingMode            = try c.decodeIfPresent(RecordingMode.self,      forKey: .recordingMode)            ?? .hold
        hotkeyKeyCode            = try c.decodeIfPresent(UInt16.self,             forKey: .hotkeyKeyCode)            ?? UInt16(kVK_RightOption)
        hotkeyModifiers          = try c.decodeIfPresent(UInt.self,               forKey: .hotkeyModifiers)          ?? 0
        playSounds               = try c.decodeIfPresent(Bool.self,               forKey: .playSounds)               ?? true
        autoCapitalize           = try c.decodeIfPresent(Bool.self,               forKey: .autoCapitalize)           ?? true
        convertPunctuation       = try c.decodeIfPresent(Bool.self,               forKey: .convertPunctuation)       ?? true
        removeFiller             = try c.decodeIfPresent(Bool.self,               forKey: .removeFiller)             ?? false
        clipboardRestoreDelay    = try c.decodeIfPresent(TimeInterval.self,       forKey: .clipboardRestoreDelay)    ?? 0.2
        useStreaming             = try c.decodeIfPresent(Bool.self,               forKey: .useStreaming)             ?? true
        llmEnabled               = try c.decodeIfPresent(Bool.self,               forKey: .llmEnabled)               ?? false
        launchAtLogin            = try c.decodeIfPresent(Bool.self,               forKey: .launchAtLogin)            ?? false
        dictionaryEntries        = try c.decodeIfPresent([DictionaryEntry].self,  forKey: .dictionaryEntries)        ?? []
        historyEnabled           = try c.decodeIfPresent(Bool.self,               forKey: .historyEnabled)           ?? true
        smartModes               = try c.decodeIfPresent([SmartMode].self,        forKey: .smartModes)               ?? SmartMode.defaults
        muteMediaDuringRecording = try c.decodeIfPresent(Bool.self,               forKey: .muteMediaDuringRecording) ?? false
        enginePreference         = try c.decodeIfPresent(EnginePreference.self,   forKey: .enginePreference)         ?? .automatic
        commandBrainProvider     = try c.decodeIfPresent(BrainProvider.self,      forKey: .commandBrainProvider)     ?? .byok
    }
}


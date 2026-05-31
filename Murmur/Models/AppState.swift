import Foundation
import SwiftUI

enum TranscriptionState: Equatable {
    case idle
    case loading(progress: Double)
    case ready
    case recording
    case transcribing
    case inserting
    case error(String)

    var isRecording: Bool { self == .recording }

    var statusText: String {
        switch self {
        case .idle: return "Initializing..."
        case .loading(let progress): return "Downloading model (\(Int(progress * 100))%)..."
        case .ready: return "Ready"
        case .recording: return "Recording..."
        case .transcribing: return "Transcribing..."
        case .inserting: return "Inserting text..."
        case .error(let msg): return "Error: \(msg)"
        }
    }

    /// New state for a model-load progress update. Ignores updates once loading is
    /// finished, so a late progress(1.0) callback can't clobber `.ready` (which would
    /// leave the app stuck "Downloading model (100%)" and unable to record).
    func applyingLoadingProgress(_ progress: Double) -> TranscriptionState {
        if case .loading = self { return .loading(progress: progress) }
        return self
    }

    static func == (lhs: TranscriptionState, rhs: TranscriptionState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.ready, .ready), (.recording, .recording),
             (.transcribing, .transcribing), (.inserting, .inserting):
            return true
        case (.loading(let a), .loading(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

@Observable
final class AppState {
    var state: TranscriptionState = .idle
    var selectedModel: String = "base.en"
    var recordingMode: RecordingMode = .hold
    var lastTranscription: String?
    var audioLevel: Float = 0.0

    // Streaming transcription state
    var streamingConfirmedText: String = ""
    var streamingUnconfirmedText: String = ""
    var isStreaming: Bool = false

    var hasMicrophonePermission = false
    var hasAccessibilityPermission = false

    var isReady: Bool { state == .ready }

    func reset() {
        state = .ready
        audioLevel = 0.0
        streamingConfirmedText = ""
        streamingUnconfirmedText = ""
        isStreaming = false
    }
}

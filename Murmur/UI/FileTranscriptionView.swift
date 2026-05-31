import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    var transcriptionEngine: TranscriptionEngineProtocol?
    @State private var result: FileTranscriptionResult?
    @State private var isTranscribing = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var isDragTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let result {
                resultView(result)
            } else if isTranscribing {
                progressView
            } else {
                dropZoneView
            }
        }
        .frame(width: 600, height: 500)
    }

    // MARK: - Drop Zone

    private var dropZoneView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(isDragTargeted ? Color.accentColor : .secondary)

            Text("Drop an audio or video file here")
                .font(.title3)
                .fontWeight(.medium)

            Text("Supports: MP3, WAV, M4A, AAC, FLAC, MP4, MOV")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Choose File...") {
                chooseFile()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDragTargeted ? Color.accentColor : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 2, dash: [8]))
                .padding()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: 16) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 300)

            Text("Transcribing... \(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private func resultView(_ result: FileTranscriptionResult) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Transcription")
                    .font(.headline)
                Spacer()
                Text(formatDuration(result.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Segments list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(result.segments) { segment in
                        HStack(alignment: .top, spacing: 12) {
                            Text(formatTimestamp(segment.startTime))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)

                            Text(segment.text)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.fullText, forType: .string)
                }

                Button("Copy with Timestamps") {
                    let timestamped = result.segments.map { segment in
                        "[\(formatTimestamp(segment.startTime))] \(segment.text)"
                    }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(timestamped, forType: .string)
                }

                Spacer()

                Button("New Transcription") {
                    self.result = nil
                    self.progress = 0
                    self.errorMessage = nil
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileTranscriber.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            transcribeFile(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            let ext = url.pathExtension.lowercased()
            guard FileTranscriber.supportedExtensions.contains(ext) else {
                Task { @MainActor in errorMessage = "Unsupported file type: .\(ext)" }
                return
            }
            Task { @MainActor in transcribeFile(url) }
        }
        return true
    }

    private func transcribeFile(_ url: URL) {
        isTranscribing = true
        progress = 0
        errorMessage = nil

        Task {
            do {
                let config = MurmurConfig.load()

                // Reuse the app's engine if available, otherwise create a new one
                let engine: TranscriptionEngineProtocol
                if let shared = transcriptionEngine, shared.isModelLoaded {
                    engine = shared
                } else {
                    engine = WhisperKitEngine(modelName: config.modelName)
                    try await engine.loadModel { p in
                        Task { @MainActor in progress = p * 0.3 }
                    }
                }

                let transcriber = FileTranscriber(transcriptionEngine: engine)
                let fileResult = try await transcriber.transcribe(
                    fileURL: url,
                    language: config.language
                ) { p in
                    Task { @MainActor in progress = 0.3 + p * 0.7 } // Remaining 70% is transcription
                }

                result = fileResult
            } catch {
                errorMessage = error.localizedDescription
            }
            isTranscribing = false
        }
    }

    // MARK: - Formatting

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins > 0 {
            return "\(mins)m \(secs)s"
        }
        return "\(secs)s"
    }
}

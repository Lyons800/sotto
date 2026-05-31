import SwiftUI

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appDelegate: appDelegate)
        } label: {
            Image(systemName: appDelegate.menuBarIcon)
        }

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("History", id: "history") {
            HistoryView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Transcribe File", id: "file-transcription") {
            FileTranscriptionView(transcriptionEngine: appDelegate.transcriptionEngine)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var config = MurmurConfig.load()

    var body: some View {
        Text(appDelegate.appState.state.statusText)
            .font(.caption)

        if let last = appDelegate.appState.lastTranscription, !last.isEmpty {
            Divider()
            let preview = String(last.prefix(60)) + (last.count > 60 ? "..." : "")
            Text("Last: \(preview)")
                .font(.caption)
        }

        Divider()

        let hotkeyName = KeyCodes.displayName(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers)
        Text("Hotkey: \(hotkeyName)")
            .font(.caption)
        Text("Model: \(config.modelName)")
            .font(.caption)

        Divider()

        Button("History...") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "history")
        }
        .keyboardShortcut("h")

        Button("Transcribe File...") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "file-transcription")
        }
        .keyboardShortcut("t")

        Button("Settings...") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")

        Button("Check for Updates...") {
            appDelegate.updateManager.checkForUpdates()
        }
        .disabled(!appDelegate.updateManager.canCheckForUpdates)

        Button("Quit Murmur") {
            appDelegate.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, Observable {
    let appState = AppState()
    let audioRecorder = AudioRecorder()
    let textInserter = TextInserter()
    let hotkeyManager: HotkeyManager
    let transcriptionEngine: TranscriptionEngine
    let overlay = TranscriptionOverlay()
    let llmProcessor = LLMProcessor()
    let updateManager = UpdateManager()
    let mediaController = MediaController()

    var menuBarIcon: String = "waveform"
    private var streamingTask: Task<Void, Error>?
    private var onboardingWindow: NSWindow?

    override init() {
        let config = MurmurConfig.load()
        self.transcriptionEngine = TranscriptionEngine(modelName: config.modelName)
        self.hotkeyManager = HotkeyManager(
            keyCode: config.hotkeyKeyCode,
            modifiers: config.hotkeyModifiers,
            mode: config.recordingMode
        )
        super.init()
    }

    private static let onboardingCompleteKey = "murmur_onboarding_complete"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check current permission state without prompting
        appState.hasMicrophonePermission = Permissions.checkMicrophone()
        appState.hasAccessibilityPermission = Permissions.checkAccessibility()

        let onboardingDone = UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey)

        if !onboardingDone || !appState.hasMicrophonePermission {
            // Show onboarding — permissions are requested there by user action
            NSLog("[Murmur] Showing onboarding...")
            showOnboardingWindow()
        } else {
            // Already onboarded with mic permission — go straight to loading
            Task { await loadModelAndStart() }
        }
    }

    // MARK: - Onboarding Window

    private func showOnboardingWindow() {
        let onboardingView = OnboardingView { [weak self] in
            self?.completeOnboarding()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Murmur"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        self.onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Called from OnboardingView when the user taps "Get Started"
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
        appState.hasMicrophonePermission = Permissions.checkMicrophone()
        appState.hasAccessibilityPermission = Permissions.checkAccessibility()

        onboardingWindow?.close()
        onboardingWindow = nil

        Task { await loadModelAndStart() }
    }

    func shutdown() {
        hotkeyManager.stop()
        streamingTask?.cancel()
        audioRecorder.shutdown()
    }

    // MARK: - Initialization

    private func loadModelAndStart() async {
        NSLog("[Murmur] Initializing...")

        // Load Whisper model (no permission prompts here)
        NSLog("[Murmur] Loading model: \(transcriptionEngine.modelName)...")
        appState.state = .loading(progress: 0)

        do {
            try await transcriptionEngine.loadModel { progress in
                Task { @MainActor [weak self] in
                    self?.appState.state = .loading(progress: progress)
                    NSLog("[Murmur] Model download: \(Int(progress * 100))%")
                }
            }
            appState.state = .ready
            NSLog("[Murmur] Model loaded. Ready!")
        } catch {
            appState.state = .error(error.localizedDescription)
            NSLog("[Murmur] Model load failed: \(error.localizedDescription)")
            return
        }

        // Load LLM model if enabled (background, non-blocking)
        let config = MurmurConfig.load()
        if config.llmEnabled && llmProcessor.isAvailable {
            Task {
                do {
                    try await llmProcessor.loadModel { progress in
                        NSLog("[Murmur] LLM download: \(Int(progress * 100))%")
                    }
                } catch {
                    NSLog("[Murmur] LLM load failed (non-fatal): \(error.localizedDescription)")
                }
            }
        }

        // Warm up audio engine so first recording starts instantly
        do {
            try audioRecorder.warmUp()
        } catch {
            NSLog("[Murmur] Audio warm-up failed (non-fatal): \(error.localizedDescription)")
        }

        // Set up hotkey
        setupHotkey()
        NSLog("[Murmur] Hotkey active. Hold Right Option to record.")
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager.onRecordingStart = { [weak self] in
            Task { @MainActor in
                await self?.startRecording()
            }
        }

        hotkeyManager.onRecordingStop = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe()
            }
        }

        hotkeyManager.start()
    }

    // MARK: - Recording

    private func startRecording() async {
        guard appState.state == .ready else {
            NSLog("[Murmur] Cannot record — state is \(appState.state.statusText)")
            return
        }

        // Check microphone permission at point of use
        if !Permissions.checkMicrophone() {
            NSLog("[Murmur] Microphone permission not granted, requesting...")
            let granted = await Permissions.requestMicrophone()
            appState.hasMicrophonePermission = granted
            if !granted {
                NSLog("[Murmur] Microphone permission denied")
                appState.state = .error("Microphone access required")
                SoundEffects.playError()
                try? await Task.sleep(for: .seconds(2))
                appState.state = .ready
                return
            }
        }

        let config = MurmurConfig.load()
        if config.playSounds { SoundEffects.playStart() }

        // Mute system audio if enabled
        if config.muteMediaDuringRecording {
            mediaController.muteSystemAudio()
        }

        // Try streaming mode first
        if config.useStreaming {
            do {
                try startStreamingRecording(config: config)
                return
            } catch {
                NSLog("[Murmur] Streaming init failed, falling back to batch: \(error)")
            }
        }

        // Batch mode fallback
        do {
            try audioRecorder.startRecording { level in
                Task { @MainActor [weak self] in
                    self?.appState.audioLevel = level
                }
            }
            appState.state = .recording
            menuBarIcon = "waveform.circle.fill"
            NSLog("[Murmur] Recording started (batch mode)")
        } catch {
            appState.state = .error(error.localizedDescription)
            NSLog("[Murmur] Recording failed: \(error)")
        }
    }

    private func startStreamingRecording(config: MurmurConfig) throws {
        // Start recording using our AudioRecorder (which works with AVCaptureDevice permission)
        try audioRecorder.startRecording { [weak self] level in
            Task { @MainActor [weak self] in
                self?.appState.audioLevel = level
                self?.overlay.updateAudioLevel(level)
            }
        }

        appState.state = .recording
        appState.isStreaming = true
        menuBarIcon = "waveform.circle.fill"

        // Show overlay near cursor
        overlay.show(near: NSEvent.mouseLocation)

        // Track last transcription to debounce (skip re-transcription if no new audio)
        var lastSampleCount = 0

        // Periodic transcription: every 1.0s, transcribe accumulated audio and update overlay
        streamingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(1000))
                if Task.isCancelled { break }

                let samples = self.audioRecorder.getAudioSamples()
                // Need at least 0.5s of audio
                guard samples.count > 8000 else { continue }

                // Debounce: skip if no significant new audio since last tick
                let newSamples = samples.count - lastSampleCount
                guard newSamples > 1600 else { continue } // at least 0.1s of new audio
                lastSampleCount = samples.count

                // Check audio energy before transcribing — skip if silence/noise
                let rms = samples.reduce(0.0) { $0 + $1 * $1 } / Float(samples.count)
                let rmsDb = 10 * log10(max(rms, 1e-10))
                if rmsDb < -45 {
                    NSLog("[Murmur] Streaming tick: audio too quiet (\(String(format: "%.1f", rmsDb)) dB), skipping")
                    continue
                }

                do {
                    let promptHint = CustomDictionary.promptHint(from: config.dictionaryEntries)
                    let result = try await self.transcriptionEngine.transcribe(
                        audioSamples: samples,
                        language: config.language,
                        promptText: promptHint
                    )
                    let text = Self.stripSpecialTokens(result.text)
                    if !text.isEmpty && !self.isHallucination(text) {
                        self.appState.streamingConfirmedText = text
                        self.appState.streamingUnconfirmedText = ""
                        self.overlay.update(confirmed: text, unconfirmed: "")
                    }
                } catch {
                    NSLog("[Murmur] Streaming transcription tick failed: \(error.localizedDescription)")
                }
            }
        }

        NSLog("[Murmur] Recording started (streaming mode)")
    }

    private func stopRecordingAndTranscribe() async {
        guard appState.state == .recording else { return }

        // Brief delay to capture the tail end of speech (user may still be finishing a word
        // when they lift their finger off the hotkey). Use try to allow cancellation on shutdown.
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return // Cancelled (e.g., app quitting)
        }

        let config = MurmurConfig.load()
        menuBarIcon = "waveform"

        // Restore system audio if it was muted
        mediaController.restoreSystemAudio()

        // Detect context before processing
        let context = ContextDetector.detectContext()
        NSLog("[Murmur] Detected context: \(context.rawValue)")

        if appState.isStreaming {
            await stopStreamingAndInsert(config: config, context: context)
        } else {
            await stopBatchAndInsert(config: config, context: context)
        }
    }

    // MARK: - Streaming Stop

    private func stopStreamingAndInsert(config: MurmurConfig, context: AppContext) async {
        // Capture last streaming result before cancelling (used as fallback)
        let lastStreamingText = appState.streamingConfirmedText

        // Stop periodic transcription
        streamingTask?.cancel()
        streamingTask = nil
        overlay.hide()

        // Stop recording and get ALL audio for final accurate transcription
        let allSamples = audioRecorder.stopRecording()
        appState.isStreaming = false

        guard allSamples.count > 8000 else {
            NSLog("[Murmur] Streaming: too short (\(allSamples.count) samples)")
            if config.playSounds { SoundEffects.playError() }
            appState.state = .ready
            return
        }

        // Trim trailing silence for cleaner final transcription
        let samples = Self.trimTrailingSilence(allSamples, threshold: 0.005, minTrailingSamples: 8000)
        NSLog("[Murmur] Trimmed audio: \(allSamples.count) → \(samples.count) samples")

        // Do one final full transcription on trimmed audio (most accurate)
        appState.state = .transcribing
        do {
            let promptHint = CustomDictionary.promptHint(from: config.dictionaryEntries)
            let result = try await transcriptionEngine.transcribe(
                audioSamples: samples,
                language: config.language,
                promptText: promptHint
            )
            let rawText = Self.stripSpecialTokens(result.text)

            if !rawText.isEmpty, !isHallucination(rawText) {
                NSLog("[Murmur] Final transcription (\(String(format: "%.1f", result.duration))s): \(rawText)")
                await processAndInsert(rawText: rawText, config: config, context: context)
                return
            }

            // Final transcription was empty — fall back to last streaming result
            if !lastStreamingText.isEmpty, !isHallucination(lastStreamingText) {
                NSLog("[Murmur] Final transcription empty, using last streaming result: '\(lastStreamingText)'")
                await processAndInsert(rawText: lastStreamingText, config: config, context: context)
                return
            }

            NSLog("[Murmur] Filtered hallucination or empty: '\(rawText)'")
            appState.state = .ready
        } catch {
            // On error, try streaming fallback
            if !lastStreamingText.isEmpty, !isHallucination(lastStreamingText) {
                NSLog("[Murmur] Final transcription error, using last streaming result: '\(lastStreamingText)'")
                await processAndInsert(rawText: lastStreamingText, config: config, context: context)
                return
            }
            NSLog("[Murmur] Final transcription error: \(error)")
            if config.playSounds { SoundEffects.playError() }
            appState.state = .ready
        }
    }

    // MARK: - Batch Stop

    private func stopBatchAndInsert(config: MurmurConfig, context: AppContext) async {
        let samples = audioRecorder.stopRecording()

        // Need at least 0.5s of audio (8000 samples at 16kHz)
        guard samples.count > 8000 else {
            NSLog("[Murmur] Too short (\(samples.count) samples), ignoring")
            if config.playSounds { SoundEffects.playError() }
            appState.state = .ready
            return
        }

        // Check audio energy
        let rms = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        let rmsDb = 10 * log10(max(rms, 1e-10))
        NSLog("[Murmur] Audio RMS: \(String(format: "%.1f", rmsDb)) dB (\(samples.count) samples)")

        if rmsDb < -50 {
            NSLog("[Murmur] Audio too quiet (silence), ignoring")
            appState.state = .ready
            return
        }

        appState.state = .transcribing
        NSLog("[Murmur] Transcribing \(samples.count) samples...")

        do {
            let promptHint = CustomDictionary.promptHint(from: config.dictionaryEntries)
            let result = try await transcriptionEngine.transcribe(
                audioSamples: samples,
                language: config.language,
                promptText: promptHint
            )

            let trimmed = Self.stripSpecialTokens(result.text)
            guard !trimmed.isEmpty, !isHallucination(trimmed) else {
                NSLog("[Murmur] Filtered hallucination or empty: '\(trimmed)'")
                appState.state = .ready
                return
            }

            NSLog("[Murmur] Batch result (\(String(format: "%.1f", result.duration))s): \(trimmed)")
            await processAndInsert(rawText: trimmed, config: config, context: context)

        } catch {
            NSLog("[Murmur] Transcription error: \(error)")
            if config.playSounds { SoundEffects.playError() }
            // Error recovery: return to .ready immediately instead of hanging
            appState.state = .ready
        }
    }

    // MARK: - Process & Insert

    private func processAndInsert(rawText: String, config: MurmurConfig, context: AppContext) async {
        // Check for voice commands
        if config.llmEnabled, llmProcessor.isReady, let parsed = VoiceCommandParser.parse(rawText, smartModes: config.smartModes) {
            NSLog("[Murmur] Voice command detected: \(parsed.command)")
            await handleVoiceCommand(parsed.command, config: config)
            return
        }

        // Partition dictionary entries: safe (regex) vs contextual (LLM)
        let (safeEntries, contextualEntries) = CustomDictionary.partition(config.dictionaryEntries)

        // Apply safe dictionary replacements via regex
        var text = CustomDictionary.apply(entries: safeEntries, to: rawText)

        // Post-process text with context
        let processor = TextPostProcessor(
            autoCapitalize: config.autoCapitalize,
            convertPunctuation: config.convertPunctuation,
            removeFiller: config.removeFiller
        )
        var processed = processor.process(text, context: context)

        // Optional LLM cleanup
        if config.llmEnabled && llmProcessor.isReady {
            appState.state = .transcribing
            // Pass safe dictionary terms for guaranteed replacement
            llmProcessor.dictionaryTerms = safeEntries
            // Pre-filter contextual entries: only include those whose spoken form appears in the text
            let relevant = CustomDictionary.relevantContextualEntries(from: contextualEntries, in: processed)
            llmProcessor.contextualDictionaryEntries = relevant
            if !relevant.isEmpty {
                NSLog("[Murmur] \(relevant.count) contextual dictionary entries injected into LLM prompt")
            }
            let llmStart = CFAbsoluteTimeGetCurrent()
            processed = await llmProcessor.process(text: processed, context: context)
            let llmElapsed = (CFAbsoluteTimeGetCurrent() - llmStart) * 1000
            NSLog("[Murmur] LLM processing took %.0fms", llmElapsed)
            // Write timing to file for debugging
            let logLine = "\(Date()): LLM took \(Int(llmElapsed))ms for \(processed.count) chars\n"
            if let data = logLine.data(using: .utf8) {
                let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Murmur/llm_timing.log")
                if FileManager.default.fileExists(atPath: logPath.path) {
                    if let handle = try? FileHandle(forWritingTo: logPath) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        handle.closeFile()
                    }
                } else {
                    try? data.write(to: logPath)
                }
            }
        } else if !contextualEntries.isEmpty {
            // LLM disabled — fall back to regex for all entries (preserves current behavior)
            processed = CustomDictionary.apply(entries: contextualEntries, to: processed)
        }

        NSLog("[Murmur] Final text: \(processed)")

        // Save to history
        if config.historyEnabled {
            TranscriptionHistory.shared.add(rawText: rawText, processedText: processed, appContext: context)
        }

        // Check accessibility before inserting — request only at point of use
        if !Permissions.checkAccessibility() {
            appState.hasAccessibilityPermission = false
            NSLog("[Murmur] Accessibility not granted — copying to clipboard only")
            // Graceful degradation: copy to clipboard, user can paste manually
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(processed, forType: .string)
            appState.lastTranscription = processed
            if config.playSounds { SoundEffects.playStop() }
            appState.state = .ready

            // Prompt for accessibility once (not every time)
            if !UserDefaults.standard.bool(forKey: "murmur_accessibility_prompted") {
                UserDefaults.standard.set(true, forKey: "murmur_accessibility_prompted")
                _ = Permissions.requestAccessibility()
            }
            return
        }

        appState.hasAccessibilityPermission = true

        // Insert text via paste
        appState.state = .inserting
        await textInserter.insert(processed)

        appState.lastTranscription = processed
        if config.playSounds { SoundEffects.playStop() }
        appState.state = .ready
    }

    // MARK: - Voice Commands

    private func handleVoiceCommand(_ command: VoiceCommand, config: MurmurConfig) async {
        NSLog("[Murmur] Executing voice command...")

        // Capture selected text from the active app
        guard let selectedText = await VoiceCommandParser.captureSelectedText(), !selectedText.isEmpty else {
            NSLog("[Murmur] No text selected for voice command")
            if config.playSounds { SoundEffects.playError() }
            appState.state = .ready
            return
        }

        // Process with LLM
        let result = await llmProcessor.executeCommand(command, on: selectedText)

        // Replace selection with result
        appState.state = .inserting
        await textInserter.insert(result)

        appState.lastTranscription = result
        if config.playSounds { SoundEffects.playStop() }
        appState.state = .ready
    }

    // MARK: - Hallucination Filter

    private func isHallucination(_ text: String) -> Bool {
        let exactHallucinations: Set<String> = [
            "you", "Thank you.", "Thanks for watching!",
            "Bye.", "Goodbye.", "...",
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return exactHallucinations.contains(trimmed)
    }

    /// Strip WhisperKit special tokens AND hallucination markers like [BLANK_AUDIO], [MUSIC], etc.
    private static func stripSpecialTokens(_ text: String) -> String {
        var result = text
        // Strip <|...|> special tokens
        result = result.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        // Strip hallucination markers that WhisperKit may embed in or append to real text
        let hallucinationMarkers = [
            "\\[BLANK_AUDIO\\]", "\\[BLANK AUDIO\\]", "\\(blank audio\\)",
            "\\[MUSIC\\]", "\\[SILENCE\\]", "\\[NOISE\\]",
            "\\[APPLAUSE\\]", "\\[LAUGHTER\\]",
        ]
        for marker in hallucinationMarkers {
            result = result.replacingOccurrences(
                of: marker,
                with: "",
                options: .regularExpression
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trim trailing silence from audio samples to improve transcription accuracy.
    /// WhisperKit struggles when short speech is followed by long silence.
    /// - Parameters:
    ///   - samples: Raw PCM audio samples
    ///   - threshold: RMS amplitude below which audio is considered silence
    ///   - minTrailingSamples: Minimum trailing silent samples before trimming (0.5s = 8000 at 16kHz)
    private static func trimTrailingSilence(_ samples: [Float], threshold: Float = 0.005, minTrailingSamples: Int = 8000) -> [Float] {
        guard samples.count > minTrailingSamples else { return samples }

        // Scan backwards to find where audio rises above silence threshold
        // Use a sliding window of 1600 samples (0.1s) for smoothing
        let windowSize = 1600
        var lastLoudIndex = samples.count

        var i = samples.count - windowSize
        while i >= 0 {
            let window = samples[i..<min(i + windowSize, samples.count)]
            let rms = sqrt(window.reduce(0) { $0 + $1 * $1 } / Float(window.count))
            if rms > threshold {
                lastLoudIndex = min(i + windowSize + minTrailingSamples / 2, samples.count) // keep 0.25s padding after last sound
                break
            }
            i -= windowSize
        }

        // Don't trim if silence portion is too small to matter
        let trimmedCount = samples.count - lastLoudIndex
        if trimmedCount < minTrailingSamples {
            return samples
        }

        return Array(samples.prefix(lastLoudIndex))
    }
}

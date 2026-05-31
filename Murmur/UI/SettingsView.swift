import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

struct SettingsView: View {
    @State private var config = MurmurConfig.load()
    @State private var showingHotkeyCapture = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            textTab
                .tabItem { Label("Text", systemImage: "textformat") }

            dictionaryTab
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

            featuresTab
                .tabItem { Label("Features", systemImage: "sparkles") }
        }
        .frame(width: 480, height: 420)
        .onChange(of: config.playSounds) { _, _ in config.save() }
        .onChange(of: config.autoCapitalize) { _, _ in config.save() }
        .onChange(of: config.convertPunctuation) { _, _ in config.save() }
        .onChange(of: config.removeFiller) { _, _ in config.save() }
        .onChange(of: config.recordingMode) { _, _ in config.save() }
        .onChange(of: config.useStreaming) { _, _ in config.save() }
        .onChange(of: config.llmEnabled) { _, _ in config.save() }
        .onChange(of: config.historyEnabled) { _, _ in config.save() }
        .onChange(of: config.muteMediaDuringRecording) { _, _ in config.save() }
        .onChange(of: config.launchAtLogin) { _, newValue in
            config.save()
            setLaunchAtLogin(newValue)
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Application") {
                Toggle("Play sounds", isOn: $config.playSounds)
                Toggle("Launch at login", isOn: $config.launchAtLogin)
                Toggle("Save transcription history", isOn: $config.historyEnabled)
                Toggle("Mute media during recording", isOn: $config.muteMediaDuringRecording)
            }

            Section("Hotkey") {
                Picker("Mode", selection: $config.recordingMode) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                HStack {
                    Text("Key")
                    Spacer()
                    Text(KeyCodes.displayName(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Model") {
                Picker("Language", selection: $config.language) {
                    Text("English").tag("en")
                    Divider()
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Dutch").tag("nl")
                    Text("Russian").tag("ru")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                    Text("Korean").tag("ko")
                    Text("Arabic").tag("ar")
                    Text("Hindi").tag("hi")
                    Text("Turkish").tag("tr")
                    Text("Polish").tag("pl")
                    Text("Swedish").tag("sv")
                    Divider()
                    Text("Auto-detect").tag("auto")
                }
                .onChange(of: config.language) { _, newLang in
                    // Auto-switch to multilingual model when non-English selected
                    if newLang != "en" && newLang != "auto" && config.modelName.hasSuffix(".en") {
                        config.modelName = String(config.modelName.dropLast(3)) // base.en → base
                    }
                    config.save()
                }

                Picker("Model", selection: $config.modelName) {
                    if config.language == "en" {
                        Text("tiny.en (75 MB, fastest)").tag("tiny.en")
                        Text("base.en (142 MB, recommended)").tag("base.en")
                        Text("small.en (466 MB, accurate)").tag("small.en")
                        Text("medium.en (1.5 GB, very accurate)").tag("medium.en")
                    } else {
                        Text("tiny (75 MB, fastest)").tag("tiny")
                        Text("base (142 MB, recommended)").tag("base")
                        Text("small (466 MB, accurate)").tag("small")
                        Text("medium (1.5 GB, very accurate)").tag("medium")
                        Text("large-v3 (3 GB, best multilingual)").tag("large-v3")
                    }
                }
                .onChange(of: config.modelName) { _, _ in config.save() }

                if config.language == "en" {
                    Text("Use .en models for English. base.en is recommended for real-time use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Multilingual models support all languages. large-v3 is most accurate but requires 3GB.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    if Permissions.checkMicrophone() {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Granted").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Grant") {
                            Task { _ = await Permissions.requestMicrophone() }
                        }
                    }
                }
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if Permissions.checkAccessibility() {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Granted").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Button("Open Settings") { Permissions.openAccessibilitySettings() }
                            Text("Optional — enables auto-paste").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Text Processing

    private var textTab: some View {
        Form {
            Section("Processing") {
                Toggle("Auto-capitalize sentences", isOn: $config.autoCapitalize)
                Toggle("Convert spoken punctuation", isOn: $config.convertPunctuation)
                Toggle("Remove filler words (um, uh, like)", isOn: $config.removeFiller)
            }

            Section("Clipboard") {
                HStack {
                    Text("Restore delay")
                    Spacer()
                    Text("\(Int(config.clipboardRestoreDelay * 1000))ms")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Context Detection") {
                Text("Murmur detects the active app and adjusts formatting — code editors preserve casing, chat apps remove trailing periods, emails add them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Dictionary

    private var dictionaryTab: some View {
        Form {
            Section {
                Text("Add words and their correct spellings. Murmur will replace spoken forms with the correct version after transcription and hint the speech model for better recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Warning when contextual entries exist but LLM is disabled
            if !config.llmEnabled && config.dictionaryEntries.contains(where: { !$0.isSafe }) {
                Section {
                    Label("Context-aware entries require LLM to be enabled. They will fall back to simple replacement.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Custom Terms") {
                if config.dictionaryEntries.isEmpty {
                    Text("No custom terms added yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach($config.dictionaryEntries) { $entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                TextField("Spoken", text: $entry.spoken)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                                    .onChange(of: entry.spoken) { _, _ in
                                        CustomDictionary.autoClassify(&entry)
                                    }
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                TextField("Replacement", text: $entry.replacement)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: .infinity)
                                // Safe/contextual indicator
                                Button {
                                    entry.isSafe.toggle()
                                    entry.safeOverridden = true
                                } label: {
                                    Image(systemName: entry.isSafe ? "bolt.fill" : "brain.head.profile")
                                        .foregroundStyle(entry.isSafe ? .green : .orange)
                                        .font(.caption)
                                        .help(entry.isSafe ? "Safe: always replaced via text matching" : "Contextual: LLM decides based on context")
                                }
                                .buttonStyle(.plain)
                                Button {
                                    config.dictionaryEntries.removeAll { $0.id == entry.id }
                                    config.save()
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            HStack(spacing: 8) {
                                TextField("Description (e.g. \"a person's name\")", text: $entry.context)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Button {
                    config.dictionaryEntries.append(DictionaryEntry(spoken: "", replacement: ""))
                    config.save()
                } label: {
                    Label("Add Term", systemImage: "plus")
                }

                if !config.dictionaryEntries.isEmpty {
                    Button("Save Changes") {
                        config.save()
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
    }

    // MARK: - Features

    private var featuresTab: some View {
        Form {
            Section("Streaming") {
                Toggle("Enable streaming transcription", isOn: $config.useStreaming)
                Text("Shows words live as you speak in a floating overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("LLM Post-Processing") {
                Toggle("Enable LLM cleanup", isOn: $config.llmEnabled)
                Text("Uses a local LLM (Qwen3-1.7B) to clean up transcriptions. Requires ~1GB download, runs entirely on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if config.llmEnabled {
                Section("Smart Modes") {
                    Text("Start your dictation with a trigger phrase to apply a Smart Mode to selected text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach($config.smartModes) { $mode in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $mode.isEnabled)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.name)
                                    .fontWeight(.medium)
                                Text("\"\(mode.triggerPhrase)\"")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                config.smartModes.removeAll { $0.id == mode.id }
                                config.save()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        config.smartModes.append(SmartMode(
                            name: "New Mode",
                            triggerPhrase: "",
                            systemPrompt: "Output ONLY the modified text, nothing else."
                        ))
                        config.save()
                    } label: {
                        Label("Add Smart Mode", systemImage: "plus")
                    }

                    if !config.smartModes.isEmpty {
                        Button("Save Changes") { config.save() }
                            .font(.caption)
                    }
                }

                Section("Built-in Commands") {
                    Text("These always work in addition to Smart Modes:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\"Translate to [language]\" — translates selected text")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    // MARK: - Launch at Login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            NSLog("[Murmur] Launch at login: \(enabled)")
        } catch {
            NSLog("[Murmur] Failed to set launch at login: \(error.localizedDescription)")
        }
    }
}

import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var app: AppDelegate
    @State private var supportedLocaleIDs: [String] = []
    @State private var whisperModelDownloaded = false
    @State private var showPurgeConfirm = false

    private var engineDetail: String {
        switch app.engine {
        case "whisper":
            return "Whisper: best accuracy on accents and jargon; " +
                "your vocabulary is fed to the model. Runs locally."
        case "parakeet":
            return app.parakeetReady
                ? "Parakeet: NVIDIA's speech model. More accurate than " +
                  "Apple's. Transcribes at your pauses while you talk, so even " +
                  "long dictations paste in about a tenth of a second. Runs locally."
                : "Parakeet: downloading or loading (one-time, about 600 MB). " +
                  "Apple engine covers dictations until it's ready."
        default:
            return "Apple: instant, built into macOS. Runs locally."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Permissions").font(.headline)
                    Spacer()
                    Label(
                        app.micAuthorized && app.axTrusted ? "Ready" : "Needs access",
                        systemImage: app.micAuthorized && app.axTrusted
                            ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(
                            app.micAuthorized && app.axTrusted ? .green : .orange)
                }
                permissionRow(
                    granted: app.micAuthorized,
                    title: "Microphone",
                    detail: "Required to hear your dictation.",
                    pane: "Privacy_Microphone")
                Divider()
                permissionRow(
                    granted: app.axTrusted,
                    title: "Accessibility",
                    detail: "Required for the global hotkey and pasting. " +
                            "Relaunch Murmur after granting.",
                    pane: "Privacy_Accessibility")
                if !app.axTrusted {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Toggle on in System Settings but still red here? " +
                             "The saved grant belongs to an older build. Click " +
                             "Reset Grant — the app relaunches, macOS asks once " +
                             "more, and the new grant sticks for all future updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Grant & Relaunch") {
                            app.resetAccessibilityGrant()
                        }
                        Button("Relaunch") { app.relaunch() }
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Dictation").font(.headline)
                HStack {
                    Text("Dictation key")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.hotkey },
                        set: { app.setHotkey($0) })) {
                        ForEach(HotkeyMonitor.Hotkey.allCases, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                toggleRow(
                    title: "Block macOS Dictation for fn",
                    detail: "Prevents the blue macOS microphone HUD from " +
                            "also seeing Murmur's fn gesture. Turn off only " +
                            "if you need fn+arrow, fn+Delete, or fn+F-key shortcuts.",
                    isOn: Binding(
                        get: { app.consumeHotkey },
                        set: { app.setConsumeHotkey($0) }))
                Divider()
                HStack {
                    Text("Language")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.localeID },
                        set: { app.setLocale($0) })) {
                        ForEach(pickerLocaleIDs, id: \.self) { identifier in
                            Text(Locale.current.localizedString(
                                forIdentifier: identifier) ?? identifier)
                                .tag(identifier)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recognition engine")
                        Text(engineDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.engine },
                        set: { app.setEngine($0) })) {
                        Text("Apple — instant").tag("apple")
                        if ParakeetEngine.isAvailableInBuild {
                            Text("Parakeet — fast + accurate").tag("parakeet")
                        }
                        if WhisperEngine.isAvailableInBuild {
                            Text("Whisper — precise").tag("whisper")
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if app.engine == "whisper" {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Whisper model")
                            Text(app.whisperReady
                                ? "Model loaded — Whisper is transcribing your dictations."
                                : whisperModelDownloaded
                                    ? "Model downloaded — loading. Apple engine covers " +
                                      "dictations until it's ready."
                                    : "Downloading in the background. Apple engine covers " +
                                      "dictations until it's ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.whisperModel },
                            set: { app.setWhisperModel($0) })) {
                            ForEach(WhisperEngine.availableModels, id: \.id) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Divider()
                toggleRow(
                    title: "Dictation indicator",
                    detail: "Shows a floating microphone and waveform while " +
                            "you dictate. It never displays transcript text.",
                    isOn: Binding(
                        get: { app.liveCaptions },
                        set: { app.setLiveCaptions($0) }))
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cleanup level")
                            Text("Cleaned is the default. Polished and Tightened " +
                                 "rewrite with the on-device model, which can " +
                                 "reword more than you intended.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.cleanupLevel },
                            set: { app.setCleanupLevel($0) })) {
                            Text("Verbatim").tag(0)
                            Text("Cleaned").tag(1)
                            Text("Polished").tag(2)
                            Text("Tightened").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    Text(cleanupStopBlurb(app.cleanupLevel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                toggleRow(
                    title: "Punctuate by grammar",
                    detail: "Puts commas and periods where the sentence needs " +
                            "them instead of wherever you paused. English only. " +
                            "Runs on this Mac in a few milliseconds after a " +
                            "one-time 210 MB download. Your words never change, " +
                            "only the punctuation.",
                    isOn: Binding(
                        get: { app.grammarPunctuation },
                        set: { app.setGrammarPunctuation($0) }))
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Spoken controls").font(.headline)
                Text("Murmur types what you say. These let it act on what " +
                     "you say instead. Spoken layout adds line breaks, and " +
                     "optional spoken edits can remove the last dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                toggleRow(
                    title: "Spoken edits",
                    detail: "Off by default. When on, saying \"scratch that\" " +
                            "or \"never mind\" edits or discards what you just " +
                            "dictated — which can fire when you only meant to " +
                            "say those words.",
                    isOn: Binding(
                        get: { app.spokenEdits },
                        set: { app.setSpokenEdits($0) }))
                Divider()
                toggleRow(
                    title: "Spoken layout",
                    detail: "Saying \"new line\" or \"new paragraph\" inserts a " +
                            "break. Turn off if you dictate those words literally.",
                    isOn: Binding(
                        get: { app.spokenLayout },
                        set: { app.setSpokenLayout($0) }))
                Divider()
                toggleRow(
                    title: "Spoken symbols",
                    detail: "On by default. Saying \"period\", \"question mark\", " +
                            "\"comma\", \"star\" or \"dash\" inserts the symbol " +
                            "instead of the word. Turn off if you need those " +
                            "words literally.",
                    isOn: Binding(
                        get: { app.spokenSymbols },
                        set: { app.setSpokenSymbols($0) }))
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy").font(.headline)
                toggleRow(
                    title: "Incognito for this session",
                    detail: "Dictation still works, but transcripts and usage " +
                            "statistics are not saved. Resets when Murmur quits.",
                    isOn: Binding(
                        get: { app.incognitoMode },
                        set: { app.setIncognitoMode($0) }))
                Divider()
                toggleRow(
                    title: "Pause history",
                    detail: "Transcripts are still inserted, just never written to disk.",
                    isOn: Binding(
                        get: { app.historyPaused },
                        set: { app.setHistoryPaused($0) }))
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep history for")
                        Text("Older transcripts are deleted automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.historyRetentionDays },
                        set: { app.setHistoryRetentionDays($0) })) {
                        Text("Forever").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep how many transcripts")
                        Text("Oldest are dropped as new dictations arrive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: Binding(
                        get: { app.historyLimit },
                        set: { app.setHistoryLimit($0) })) {
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("250").tag(250)
                        Text("500").tag(500)
                        Text("1000").tag(1000)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Divider()
                toggleRow(
                    title: "Add a period automatically",
                    detail: "Turning this off suits search fields, chat, and code.",
                    isOn: Binding(
                        get: { app.autoPeriod },
                        set: { app.setAutoPeriod($0) }))
                Divider()
                toggleRow(
                    title: "Launch at login",
                    detail: "Starts Murmur automatically when you sign in.",
                    isOn: Binding(
                        get: { app.launchAtLogin },
                        set: { app.setLaunchAtLogin($0) }))
                if let note = app.launchAtLoginNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Panic purge")
                        Text("Deletes transcripts, statistics, learned corrections, " +
                             "dictionary, snippets, presets, styles, and scratchpad.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Purge Personal Data…", role: .destructive) {
                        showPurgeConfirm = true
                    }
                }
            }
            .card()
            .confirmationDialog(
                "Permanently purge all personal Murmur data?",
                isPresented: $showPurgeConfirm
            ) {
                Button("Purge Personal Data", role: .destructive) {
                    app.purgePersonalData()
                }
            } message: {
                Text("Downloaded speech models, preferences, and macOS permission " +
                     "grants are kept. Everything else listed here is deleted. " +
                     "This cannot be undone.")
            }
        }
        .onAppear {
            loadLocales()
            refreshWhisperModelDownloaded()
        }
        .onChange(of: app.whisperModel) { _, _ in refreshWhisperModelDownloaded() }
        .onChange(of: app.engine) { _, _ in refreshWhisperModelDownloaded() }
    }

    /// Recursively walks the Whisper models directory, so it's cached in
    /// `@State` and only recomputed on appear or when the selected engine
    /// or model changes — not from `body`, which the 2s permission-refresh
    /// timer re-evaluates continuously while this page is open.
    private func refreshWhisperModelDownloaded() {
        whisperModelDownloaded = app.whisperEngine.isModelDownloaded(app.whisperModel)
    }

    /// Blurbs come from the shared cleanup-stop enum; `resolve` clamps any
    /// persisted Int so a garbage value still renders the default stop.
    private func cleanupStopBlurb(_ level: Int) -> String {
        CleanupLevel.resolve(level).blurb
    }

    private var pickerLocaleIDs: [String] {
        var ids = supportedLocaleIDs
        if !ids.contains(app.localeID) {
            ids.insert(app.localeID, at: 0)
        }
        return ids
    }

    private func loadLocales() {
        Task {
            let locales = await SpeechTranscriber.supportedLocales
            supportedLocaleIDs = locales
                .map { $0.identifier(.bcp47) }
                .sorted {
                    (Locale.current.localizedString(forIdentifier: $0) ?? $0)
                    < (Locale.current.localizedString(forIdentifier: $1) ?? $1)
                }
        }
    }

    private func permissionRow(
        granted: Bool, title: String, detail: String, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") {
                    let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func toggleRow(
        title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

// MARK: - Help

struct HelpPage: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Help")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)

            VStack(alignment: .leading, spacing: 14) {
                helpRow("hand.tap", "Push-to-talk",
                    "Click into any text field, hold \(app.hotkey.displayName), speak, " +
                    "release. The cleaned-up text is pasted at your cursor.")
                Divider()
                helpRow("wand.and.sparkles", "Polished dictation",
                    "Tap \(app.hotkey.displayName), then hold the second press while " +
                    "you speak. Murmur turns false starts, repetition, and jumbled " +
                    "speech into your finished thought. Two quick taps also arm the " +
                    "next hold, then Murmur returns to Fast.")
                Divider()
                helpRow("text.insert", "Spoken layout",
                    "Say “new line” or “new paragraph” to add line breaks " +
                    "while dictating.")
                Divider()
                helpRow("lock.shield", "Private by design",
                    "Audio and transcripts stay on this Mac. Murmur connects to " +
                    "Apple for speech assets, Hugging Face for optional Whisper " +
                    "models, and GitHub for signed app updates; those requests " +
                    "download models or updates, not dictation.")
            }
            .padding(20)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func helpRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Snippets

struct SnippetsPage: View {
    @State private var snippets: [Snippet] = []
    @State private var newTrigger = ""
    @State private var newExpansion = ""
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Snippets")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Say the trigger phrase while dictating and the whole block is " +
                 "inserted instead — signatures, addresses, meeting links, " +
                 "canned replies.")
                .foregroundStyle(.secondary)

            ForEach($snippets) { $snippet in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "quote.bubble")
                            .foregroundStyle(Palette.accent)
                        TextField("trigger phrase (what you say)",
                                  text: $snippet.trigger)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                        Button {
                            snippets.removeAll { $0.id == snippet.id }
                            save()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    TextEditor(text: $snippet.expansion)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 64)
                        .background(Palette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.border, lineWidth: 1))
                        .onChange(of: snippet.expansion) { _, _ in scheduleSave() }
                }
                .padding(16)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add new").font(.headline)
                TextField("trigger phrase (what you say)", text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newExpansion)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 64)
                    .background(Palette.panel,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.border, lineWidth: 1))
                HStack {
                    Spacer()
                    Button("Add snippet") {
                        snippets.append(Snippet(
                            trigger: newTrigger.trimmingCharacters(in: .whitespaces),
                            expansion: newExpansion))
                        newTrigger = ""
                        newExpansion = ""
                        save()
                    }
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty
                              || newExpansion.isEmpty)
                }
            }
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear { snippets = SnippetStore.load() }
    }

    /// Debounces the per-keystroke expansion edits so a full JSON rewrite
    /// isn't happening on every character — waits for a short pause in
    /// typing before persisting.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        // Blank-trigger rows are persisted as-is rather than dropped here:
        // SnippetStore.expand() already filters empty triggers at expansion
        // time, so saving them is safe and avoids silently discarding a
        // snippet's expansion text while the user is mid-retype of its
        // trigger (e.g. selected-all-deleted the field to type a new one).
        SnippetStore.save(snippets)
    }
}

import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

// MARK: - My Voice

struct MyVoicePage: View {
    @ObservedObject var app: AppDelegate
    @ObservedObject var voiceStore: VoiceInstructionStore
    @State private var editingPreset: VoiceInstruction?
    @State private var editingIsNew = false
    @State private var pendingDelete: VoiceInstruction?
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("My Voice")
                    .font(.system(size: 30, weight: .medium))
                Spacer()
                Button {
                    newPreset()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("New preset")
            }
            .padding(.top, 24)
            Text("Presets rewrite your dictations before they're inserted — " +
                 "your phrasing, enforced everywhere you talk.")
                .foregroundStyle(.secondary)

            if voiceStore.instructions.isEmpty {
                emptyState
            } else {
                presetList
            }
        }
        .sheet(item: $editingPreset) { preset in
            VoicePresetEditorView(
                preset: preset,
                isNew: editingIsNew,
                onSave: { updated in
                    if editingIsNew {
                        voiceStore.add(updated)
                    } else {
                        voiceStore.update(updated)
                    }
                    editingPreset = nil
                },
                onCancel: { editingPreset = nil })
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.name ?? "")\u{201D}?",
            isPresented: $showDeleteConfirm,
            presenting: pendingDelete) { preset in
            Button("Delete Preset", role: .destructive) {
                voiceStore.remove(id: preset.id)
            }
        } message: { preset in
            Text("This permanently deletes \u{201C}\(preset.name)\u{201D}. " +
                 "This can't be undone.")
        }
    }

    private func newPreset() {
        editingIsNew = true
        editingPreset = VoiceInstruction(name: "", instructions: "")
    }

    // MARK: Empty state

    /// Shown until the first preset exists: what My Voice does plus how a
    /// preset gets activated — menu-bar quick-switcher or per-app bindings.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 28))
                .foregroundStyle(Palette.accent)
            Text("Murmur sounds like everyone. Fix that.")
                .font(.headline)
            Text("A preset is a standing instruction — \u{201C}tighten my phrasing\u{201D}, " +
                 "\u{201C}always contractions\u{201D}, \u{201C}no exclamation marks\u{201D} — applied " +
                 "to your dictations right before they're inserted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Activate one from the menu-bar mic icon under My Voice, or " +
                 "bind it to specific apps and it applies only while those apps " +
                 "are frontmost.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                newPreset()
            } label: {
                Label("Create your first preset", systemImage: "plus.circle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.onInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Preset list

    private var presetList: some View {
        VStack(spacing: 0) {
            ForEach(Array(voiceStore.instructions.enumerated()),
                    id: \.element.id) { index, preset in
                presetRow(preset)
                if index != voiceStore.instructions.count - 1 {
                    Divider().opacity(0.6)
                }
            }
        }
        .background(Palette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Palette.border, lineWidth: 1))
    }

    private func presetRow(_ preset: VoiceInstruction) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name.isEmpty ? "Untitled preset" : preset.name)
                    .font(.body.weight(.medium))
                Text(firstLine(of: preset.instructions))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(preset.appBundleIDs.isEmpty
                    ? "All apps"
                    : "\(preset.appBundleIDs.count) app" +
                      "\(preset.appBundleIDs.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { preset.isEnabled },
                set: { enabled in
                    var updated = preset
                    updated.isEnabled = enabled
                    voiceStore.update(updated)
                }))
                .toggleStyle(.switch)
                .labelsHidden()
                .fixedSize()
                .help(preset.isEnabled ? "Enabled" : "Off")
            Button {
                editingIsNew = false
                editingPreset = preset
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button {
                pendingDelete = preset
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func firstLine(of text: String) -> String {
        guard let line = text.components(separatedBy: .newlines)
            .first(where: { !$0.isEmpty }) else {
            return "No instructions yet"
        }
        return line
    }
}

/// Create/edit sheet for one My Voice preset: name, freeform rewriting
/// instructions with a placeholder hint, and per-app bindings.
private struct VoicePresetEditorView: View {
    let preset: VoiceInstruction
    let isNew: Bool
    let onSave: (VoiceInstruction) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var instructions: String
    @State private var appBundleIDs: [String]
    // Cheap placeholders like StylePage's — NSWorkspace enumeration is an
    // AppKit round-trip, so it's cached in @State on appear instead of
    // re-running on every body evaluation.
    @State private var runningAppsList: [(bundleID: String, name: String)] = []
    @State private var manualBundleID = ""

    init(preset: VoiceInstruction, isNew: Bool,
         onSave: @escaping (VoiceInstruction) -> Void,
         onCancel: @escaping () -> Void) {
        self.preset = preset
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: preset.name)
        _instructions = State(initialValue: preset.instructions)
        _appBundleIDs = State(initialValue: preset.appBundleIDs)
    }

    private static let instructionsHint =
        "e.g. Tighten my phrasing. Always contractions. No exclamation " +
        "marks. Keep lists as bullets."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(isNew ? "New Preset" : "Edit Preset",
                  systemImage: isNew ? "plus.circle" : "pencil")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions").font(.subheadline.weight(.medium))
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $instructions)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 120)
                        .background(Palette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.border, lineWidth: 1))
                    if instructions.isEmpty {
                        Text(Self.instructionsHint)
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                Text("Applied to every matching dictation right before it's " +
                     "inserted — Murmur rewrites what you dictated to follow " +
                     "these rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Applies to").font(.subheadline.weight(.medium))
                if appBundleIDs.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                        Text("All apps").font(.callout)
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 8)],
                        alignment: .leading, spacing: 8) {
                        ForEach(appBundleIDs, id: \.self) { bundleID in
                            bindingChip(bundleID)
                        }
                    }
                }
                Text("With no bindings a preset applies everywhere; bound ones " +
                     "apply only while that app is frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Menu {
                        ForEach(runningAppsList, id: \.bundleID) { appInfo in
                            Button(appInfo.name) { addBinding(appInfo.bundleID) }
                                .disabled(appBundleIDs.contains(appInfo.bundleID))
                        }
                    } label: {
                        Label("Add app…", systemImage: "plus")
                    }
                    .fixedSize()
                    TextField("or paste a bundle ID, e.g. com.apple.Notes",
                              text: $manualBundleID)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addManual)
                    Button("Add", action: addManual)
                        .disabled(manualBundleID
                            .trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isNew ? "Create Preset" : "Save Changes") {
                    onSave(VoiceInstruction(
                        id: preset.id,
                        name: name.trimmingCharacters(in: .whitespaces),
                        instructions: instructions,
                        isEnabled: preset.isEnabled,
                        appBundleIDs: appBundleIDs,
                        createdAt: preset.createdAt))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                          instructions.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear(perform: refreshRunningApps)
    }

    private func bindingChip(_ bundleID: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "app")
                .foregroundStyle(Palette.accent)
            Text(Self.displayName(forBundleID: bundleID))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                appBundleIDs.removeAll { $0 == bundleID }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Palette.border, lineWidth: 1))
    }

    private func addManual() {
        addBinding(manualBundleID.trimmingCharacters(in: .whitespaces))
        manualBundleID = ""
    }

    private func addBinding(_ bundleID: String) {
        guard !bundleID.isEmpty, !appBundleIDs.contains(bundleID) else { return }
        appBundleIDs.append(bundleID)
    }

    private func refreshRunningApps() {
        runningAppsList = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier,
                      let name = application.localizedName else { return nil }
                return (bundleID, name)
            }
            .sorted { $0.name < $1.name }
    }

    /// Friendly app name for a stored bundle ID; falls back to the raw id
    /// when no installed app matches (e.g. uninstalled or hand-typed).
    static func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
               ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
               ?? bundle.infoDictionary?["CFBundleName"] as? String,
           !name.isEmpty {
            return name
        }
        return bundleID
    }
}

// MARK: - Style

struct StylePage: View {
    @ObservedObject var app: AppDelegate
    // Cheap placeholders — the real values are UserDefaults reads + JSON
    // decodes, so they're loaded once in `.onAppear` rather than in this
    // initializer, which would otherwise re-run (and be discarded) every
    // time this view's parent reconstructs it, including on every tick of
    // the 2s permission-refresh timer while this page is open.
    @State private var defaultStyle: WritingStyle = .none
    @State private var overrides: [String: AppStyleRule] = [:]
    @State private var pickedBundleID: String = ""
    @State private var runningAppsList: [(bundleID: String, name: String)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Style")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Murmur adapts your tone to where you're writing — formal in docs, " +
                 "casual in chat. Rewriting runs on-device with Apple Intelligence.")
                .foregroundStyle(.secondary)

            if let note = app.rewriteEngine.availabilityNote {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(note).font(.callout)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Default style").font(.headline)
                Text("Used in every app unless overridden below.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $defaultStyle) {
                    ForEach(WritingStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: defaultStyle) { _, newValue in
                    StyleSettings.defaultStyle = newValue
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Per-app styles").font(.headline)
                if overrides.isEmpty {
                    Text("No app rules yet.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(overrides.sorted(by: { $0.value.appName < $1.value.appName }),
                        id: \.key) { bundleID, rule in
                    HStack {
                        Text(rule.appName)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { rule.style },
                            set: { newStyle in
                                overrides[bundleID] = AppStyleRule(
                                    appName: rule.appName, style: newStyle)
                                StyleSettings.overrides = overrides
                            })) {
                            ForEach(WritingStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            overrides.removeValue(forKey: bundleID)
                            StyleSettings.overrides = overrides
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                }
                HStack {
                    Picker("", selection: $pickedBundleID) {
                        Text("Choose a running app…").tag("")
                        ForEach(runningAppsList, id: \.bundleID) { appInfo in
                            Text(appInfo.name).tag(appInfo.bundleID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Add rule") {
                        guard let appInfo = runningAppsList.first(
                            where: { $0.bundleID == pickedBundleID }) else { return }
                        overrides[appInfo.bundleID] = AppStyleRule(
                            appName: appInfo.name, style: .casual)
                        StyleSettings.overrides = overrides
                        pickedBundleID = ""
                    }
                    .disabled(pickedBundleID.isEmpty)
                }
            }
            .card()
        }
        .onAppear {
            defaultStyle = StyleSettings.defaultStyle
            overrides = StyleSettings.overrides
            refreshRunningApps()
        }
    }

    /// Enumerates `NSWorkspace.shared.runningApplications`, so it's cached
    /// in `@State` and only refreshed on appear rather than every `body`
    /// evaluation (see the `.onAppear` comment above).
    private func refreshRunningApps() {
        runningAppsList = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { application in
                guard let bundleID = application.bundleIdentifier,
                      let name = application.localizedName else { return nil }
                return (bundleID, name)
            }
            .sorted { $0.name < $1.name }
    }
}

// MARK: - Transforms

struct TransformsPage: View {
    @ObservedObject var app: AppDelegate
    @State private var tryText = ""
    @State private var result = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Transforms")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Select text in any app, press the shortcut, and it's rewritten " +
                 "in place — on-device.")
                .foregroundStyle(.secondary)

            if let note = app.rewriteEngine.availabilityNote {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(note).font(.callout)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Transform.all) { transform in
                    HStack(alignment: .top) {
                        Text(transform.keyLabel)
                            .font(.system(size: 13, weight: .semibold,
                                          design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Palette.panel,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(Palette.border, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transform.name).font(.body.weight(.medium))
                            Text(transform.description)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if transform.id != Transform.all.last?.id {
                        Divider()
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Text("Try it here").font(.headline)
                TextEditor(text: $tryText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 70)
                    .background(Palette.panel,
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Palette.border, lineWidth: 1))
                HStack {
                    ForEach(Transform.all) { transform in
                        Button(transform.name) { runTransform(transform) }
                            .disabled(running || tryText.isEmpty
                                      || !app.rewriteEngine.isAvailable)
                    }
                    if running { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if !result.isEmpty {
                    Text(result)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.panel,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Palette.border, lineWidth: 1))
                }
            }
            .card()
        }
    }

    private func runTransform(_ transform: Transform) {
        running = true
        result = ""
        Task {
            defer { running = false }
            do {
                result = try await app.transformManager.apply(transform, to: tryText)
            } catch {
                result = "Failed: \(error.localizedDescription)"
            }
        }
    }
}


// MARK: - Voice Training

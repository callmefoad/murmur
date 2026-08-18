import AppKit
import AVFoundation
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    enum UIState {
        case idle, recording, processing
    }

    // Observable state for the dashboard window.
    @Published var uiState: UIState = .idle { didSet { updateIcon() } }
    @Published var isHandsFree = false
    @Published var entries: [HistoryEntry] = []
    @Published var micAuthorized = false
    @Published var axTrusted = false
    @Published var hotkey: HotkeyMonitor.Hotkey = Settings.hotkey
    @Published var localeID: String = Settings.locale.identifier
    @Published var lastError: String?
    @Published var autoPeriod: Bool = Settings.autoPeriod
    @Published var historyPaused: Bool = Settings.historyPaused
    @Published var historyRetentionDays: Int = Settings.historyRetentionDays
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginNote: String?
    @Published var stats = LifetimeStats()

    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let recorder = AudioRecorder()
    private let history = HistoryStore()
    private let statsStore = StatsStore()
    private var transcriber = Transcriber(locale: Settings.locale)
    private lazy var hotkeyMonitor = HotkeyMonitor(hotkey: Settings.hotkey)
    let rewriteEngine = RewriteEngine()
    let whisperEngine = WhisperEngine()
    @Published var engine: String = Settings.engine
    @Published var whisperModel: String = Settings.whisperModel
    @Published var whisperReady = false
    @Published var voiceProfile: VoiceProfile? = VoiceProfileStore.load()
    /// Guards against stacking multiple concurrent `LanguageModelSession`
    /// generations: without it, every dictation that lands while a refresh
    /// is already running would see the still-stale `wordCountAtGeneration`
    /// and kick off another one, and the manual refresh button had no guard
    /// at all — stacking one session per click.
    private var voiceProfileTaskInFlight = false
    private(set) lazy var transformManager = TransformManager(engine: rewriteEngine)

    /// Extra status line shown in the top bar while a transform runs.
    @Published var transformStatus: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioRecorder.sweepStaleRecordings()
        AppPaths.secureExistingFiles()
        entries = history.entries
        statsStore.seed(from: history.entries)
        stats = statsStore.stats
        setUpStatusItem()
        refreshPermissions(promptAccessibility: true)
        wireHotkey()
        hotkeyMonitor.startMonitoring()
        transformManager.onStatus = { [weak self] status in
            self?.transformStatus = status
        }
        transformManager.onError = { [weak self] message in
            self?.lastError = message
        }
        transformManager.startMonitoring()
        whisperEngine.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.transformStatus = status
                self.whisperReady = self.whisperEngine.isReady(
                    model: Settings.whisperModel)
            }
        }
        whisperEngine.onError = { [weak self] message in
            Task { @MainActor in
                self?.lastError = message
            }
        }
        if Settings.engine == "whisper" {
            whisperEngine.preload(model: Settings.whisperModel)
        }
        showMainWindow()

        Task {
            micAuthorized = await AudioRecorder.requestMicrophoneAccess()
        }
        // Warm up the on-device speech model in the background.
        Task.detached { [transcriber] in
            try? await transcriber.ensureModelInstalled()
        }
        refreshVoiceProfileIfDue()
    }

    /// Regenerates the Voice Profile persona once enough new dictation has
    /// accumulated. Runs quietly in the background; failures keep the old
    /// one. `force: true` (the manual refresh button) always reports back
    /// via `lastError`/`transformStatus` — automatic background refreshes
    /// stay quiet on failure so they don't spam the user every dictation.
    func refreshVoiceProfileIfDue(force: Bool = false) {
        // Lifetime word count, not `entries.reduce`: `entries` mirrors
        // HistoryStore, which is capped at 50 and pruned by retention, so
        // its sum plateaus (or even drops) once the cap is hit and
        // `totalWords - wordCountAtGeneration >= refreshThreshold` would
        // become permanently unreachable. `statsStore.stats.words` is the
        // monotonic lifetime counter.
        let totalWords = statsStore.stats.words
        guard force || VoiceProfileStore.shouldRefresh(totalWords: totalWords)
        else { return }
        guard totalWords >= VoiceProfileStore.minimumWords else {
            if force {
                lastError = "Dictate at least \(VoiceProfileStore.minimumWords) words " +
                    "before Murmur can build a Voice Profile — \(totalWords) so far."
            }
            return
        }
        guard !voiceProfileTaskInFlight else {
            if force {
                lastError = "Voice Profile is already refreshing — hang tight."
            }
            return
        }
        voiceProfileTaskInFlight = true
        let snapshot = entries
        transformStatus = "Refreshing Voice Profile…"
        Task { [rewriteEngine] in
            defer {
                voiceProfileTaskInFlight = false
                transformStatus = nil
            }
            do {
                voiceProfile = try await VoiceProfileStore.generate(
                    from: snapshot, totalWords: totalWords, engine: rewriteEngine)
            } catch {
                if force {
                    lastError = "Couldn't refresh Voice Profile: " +
                        "\(error.localizedDescription)"
                }
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Main window

    func showMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(app: self))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Murmur"
            newWindow.styleMask = [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
            ]
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.setContentSize(NSSize(width: 1180, height: 840))
            newWindow.minSize = NSSize(width: 900, height: 600)
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshPermissions()
    }

    // MARK: - Permissions

    /// Polled every couple of seconds by the window. Each assignment below is
    /// guarded on an actual change: assigning an equal value to a @Published
    /// property still fires objectWillChange, which would re-evaluate the whole
    /// view tree on every tick for no reason.
    func refreshPermissions(promptAccessibility: Bool = false) {
        let trusted: Bool
        if promptAccessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        } else {
            trusted = AXIsProcessTrusted()
        }
        if axTrusted != trusted { axTrusted = trusted }

        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if micAuthorized != mic { micAuthorized = mic }

        let ready = whisperEngine.isReady(model: Settings.whisperModel)
        if whisperReady != ready { whisperReady = ready }
    }

    // MARK: - Settings changes (from window or menu)

    func setHotkey(_ key: HotkeyMonitor.Hotkey) {
        Settings.hotkey = key
        hotkey = key
        hotkeyMonitor.hotkey = key
        rebuildMenu()
    }

    func setEngine(_ newEngine: String) {
        Settings.engine = newEngine
        engine = newEngine
        if newEngine == "whisper" {
            whisperEngine.preload(model: Settings.whisperModel)
        }
    }

    func setWhisperModel(_ model: String) {
        Settings.whisperModel = model
        whisperModel = model
        if Settings.engine == "whisper" {
            whisperEngine.preload(model: model)
        }
    }

    func setLocale(_ identifier: String) {
        Settings.localeIdentifier = identifier
        localeID = identifier
        transcriber = Transcriber(locale: Locale(identifier: identifier))
        Task.detached { [transcriber] in
            try? await transcriber.ensureModelInstalled()
        }
    }

    func clearHistoryEntries() {
        history.clear()
        entries = []
        rebuildMenu()
    }

    func setAutoPeriod(_ on: Bool) {
        Settings.autoPeriod = on
        autoPeriod = on
    }

    func setHistoryPaused(_ on: Bool) {
        Settings.historyPaused = on
        historyPaused = on
    }

    func setHistoryRetentionDays(_ days: Int) {
        Settings.historyRetentionDays = days
        historyRetentionDays = days
        history.prune()
        entries = history.entries
        rebuildMenu()
    }

    /// Registers/unregisters Murmur as a login item via SMAppService. Note:
    /// the login item points at the bundle's current on-disk path, so a
    /// build launched from `build/` (rather than /Applications) registers
    /// that path — reinstalling elsewhere requires re-registering.
    func setLaunchAtLogin(_ on: Bool) {
        var registrationError: String?
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            registrationError = error.localizedDescription
        }

        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin = true
            launchAtLoginNote = registrationError
        case .requiresApproval:
            // Registered, but macOS is waiting on the user to flip it on in
            // System Settings — that's still "on" from Murmur's point of
            // view. Forcing the toggle back off here (as before) made it
            // un-settable: the user re-enables it, sees it snap back off,
            // and repeats forever. Un-registering still works fine from
            // this state via the `unregister()` branch above.
            launchAtLogin = true
            launchAtLoginNote = registrationError ??
                "Enable Murmur in System Settings › General › Login Items."
        default:
            launchAtLogin = false
            launchAtLoginNote = registrationError
        }
    }

    var dayStreak: Int { statsStore.dayStreak }
    var wordsPerMinute: Int? { statsStore.wordsPerMinute }

    /// Deletes any stale Accessibility grant (recorded against an older
    /// build's signature) and relaunches so macOS asks again — the new grant
    /// is recorded against the stable certificate and survives updates.
    func resetAccessibilityGrant() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = [
            "reset", "Accessibility",
            Bundle.main.bundleIdentifier ?? "local.murmur",
        ]
        try? process.run()
        process.waitUntilExit()
        relaunch()
    }

    /// Starts a fresh instance of the app and quits this one. Needed after
    /// granting Accessibility, which macOS only applies to new processes.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func deleteHistoryEntry(id: String) {
        history.delete(id: id)
        entries = history.entries
        rebuildMenu()
    }

    /// Applies a user correction to a transcript and learns the
    /// misheard → intended word mappings from it. Returns how many were learned.
    @discardableResult
    func correctHistoryEntry(id: String, newText: String) -> Int {
        guard let entry = history.entries.first(where: { $0.id == id }),
              entry.text != newText else { return 0 }
        let learnedCount = LearnedStore.learn(original: entry.text, corrected: newText)
        history.update(id: id, text: newText)
        entries = history.entries
        rebuildMenu()
        return learnedCount
    }

    /// Raw transcription without biasing or cleanup — used by Voice Training
    /// to see what the model naturally hears.
    func transcribeRaw(fileAt url: URL) async throws -> String {
        try await transcriber.transcribe(fileAt: url)
    }

    /// Runs the user's chosen recognition engine. Dictation never waits on
    /// Whisper: while its model is still downloading or loading, Apple's
    /// engine handles the dictation, and Whisper takes over once ready.
    /// Whisper failures also fall back to Apple so a keypress always
    /// produces text.
    private func recognize(fileAt url: URL) async throws -> String {
        let biasTerms = LearnedStore.biasTerms()
        if Settings.engine == "whisper" {
            if whisperEngine.isReady(model: Settings.whisperModel) {
                do {
                    return try await whisperEngine.transcribe(
                        fileAt: url, model: Settings.whisperModel,
                        localeID: Settings.localeIdentifier, biasTerms: biasTerms)
                } catch {
                    lastError = "Whisper engine failed " +
                        "(\(error.localizedDescription)) — used Apple engine instead."
                }
            } else {
                whisperEngine.preload(model: Settings.whisperModel)
                lastError = "Whisper model is still preparing — used Apple " +
                    "engine for this dictation. Whisper takes over when ready."
            }
        }
        return try await transcriber.transcribe(fileAt: url, biasTerms: biasTerms)
    }

    // MARK: - Hotkey wiring

    private func wireHotkey() {
        hotkeyMonitor.onStart = { [weak self] in
            DispatchQueue.main.async { self?.startRecording() }
        }
        hotkeyMonitor.onStop = { [weak self] in
            DispatchQueue.main.async { self?.stopAndTranscribe() }
        }
        hotkeyMonitor.onCancel = { [weak self] in
            DispatchQueue.main.async {
                self?.recorder.cancel()
                self?.uiState = .idle
            }
        }
        hotkeyMonitor.onHandsFreeChange = { [weak self] active in
            DispatchQueue.main.async {
                self?.isHandsFree = active
                self?.updateIcon()
                if active { NSSound(named: "Pop")?.play() }
            }
        }
    }

    private var recordingStartedAt: Date?
    private var recordingTargetBundleID: String?

    private func startRecording() {
        guard uiState != .recording else { return }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            recordingTargetBundleID =
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            uiState = .recording
            lastError = nil
            NSSound(named: "Pop")?.play()
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            NSSound(named: "Basso")?.play()
        }
    }

    private func stopAndTranscribe() {
        isHandsFree = false
        guard let url = recorder.stop() else {
            uiState = .idle
            return
        }
        NSSound(named: "Tink")?.play()
        uiState = .processing
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) }
        recordingStartedAt = nil
        let targetBundleID = recordingTargetBundleID
        recordingTargetBundleID = nil

        Task { [history, rewriteEngine] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let raw = try await recognize(fileAt: url)
                var formatted = TextFormatter().format(raw)
                formatted = LearnedStore.apply(in: formatted)
                formatted = SnippetStore.expand(in: formatted)

                // Per-app style: rewrite tone on-device (Apple Intelligence).
                let style = StyleSettings.style(forBundleID: targetBundleID)
                if let instructions = style.instructions,
                   !formatted.isEmpty,
                   rewriteEngine.isAvailable {
                    transformStatus = "Applying \(style.displayName) style…"
                    do {
                        let rewritten = try await rewriteEngine.rewrite(
                            formatted, instructions: instructions)
                        if !rewritten.isEmpty {
                            formatted = rewritten
                        }
                    } catch {
                        // Don't fail silently: the Style setting would look
                        // on but simply stop applying past some length with
                        // no indication why.
                        lastError = "Style wasn't applied: \(error.localizedDescription)"
                    }
                    transformStatus = nil
                }
                if !formatted.isEmpty {
                    history.add(formatted, duration: duration)
                    entries = history.entries
                    // Stats are aggregate counters only (no transcript
                    // text), so pausing History — which is about not
                    // persisting transcripts to disk — shouldn't freeze
                    // them too. `history.add` early-returns without
                    // creating an entry when paused, so `history.entries
                    // .first` would NOT be the new entry in that case;
                    // build the entry for stats directly from what was
                    // just dictated instead of reading it back off history.
                    statsStore.record(
                        HistoryEntry(text: formatted, date: Date(), duration: duration))
                    stats = statsStore.stats
                    refreshVoiceProfileIfDue()
                    if AXIsProcessTrusted() {
                        TextInserter.insert(formatted)
                    } else {
                        // Can't synthesize ⌘V without Accessibility — never
                        // fail silently: leave the transcript on the clipboard.
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(formatted, forType: .string)
                        lastError = "Accessibility isn't active for this build, " +
                            "so the text was copied to your clipboard instead — " +
                            "press ⌘V to paste it. Fix this in Settings."
                        NSSound(named: "Basso")?.play()
                    }
                    rebuildMenu()
                }
            } catch {
                lastError = "Transcription failed: \(error.localizedDescription)"
                NSSound(named: "Basso")?.play()
            }
            uiState = .idle
        }
    }

    // MARK: - Status item / menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        let symbol: String
        switch uiState {
        case .idle: symbol = "mic"
        case .recording: symbol = isHandsFree ? "mic.badge.plus" : "mic.fill"
        case .processing: symbol = "hourglass"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Murmur")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open Murmur…", action: #selector(openMainWindow),
            keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let hint = NSMenuItem(
            title: "Hold \(hotkeyMonitor.hotkey.displayName) to dictate",
            action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        if history.entries.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, entry) in history.entries.prefix(8).enumerated() {
                let preview = entry.text.count > 60
                    ? String(entry.text.prefix(57)) + "…" : entry.text
                let item = NSMenuItem(
                    title: preview.replacingOccurrences(of: "\n", with: " "),
                    action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Menu actions

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard sender.tag < history.entries.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(history.entries[sender.tag].text, forType: .string)
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// One-time import of preferences saved under the app's pre-rename
    /// bundle id (local.whisperflow). Call before anything reads Settings.
    static func migrateLegacyDefaults() {
        guard defaults.object(forKey: "hotkey") == nil,
              defaults.object(forKey: "locale") == nil,
              let legacy = UserDefaults(suiteName: "local.whisperflow")
        else { return }
        for key in ["hotkey", "locale", "styleDefault", "styleOverrides"] {
            if defaults.object(forKey: key) == nil,
               let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    static var hotkey: HotkeyMonitor.Hotkey {
        get {
            HotkeyMonitor.Hotkey(
                rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var localeIdentifier: String {
        get { defaults.string(forKey: "locale") ?? "en-US" }
        set { defaults.set(newValue, forKey: "locale") }
    }

    /// Recognition engine: "apple" (instant) or "whisper" (precise).
    static var engine: String {
        get { defaults.string(forKey: "engine") ?? "apple" }
        set { defaults.set(newValue, forKey: "engine") }
    }

    static var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "small" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    /// Whether recognized text gets a trailing period auto-appended.
    static var autoPeriod: Bool {
        get { defaults.object(forKey: "autoPeriod") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoPeriod") }
    }

    /// When true, dictations are not written to History.
    static var historyPaused: Bool {
        get { defaults.bool(forKey: "historyPaused") }
        set { defaults.set(newValue, forKey: "historyPaused") }
    }

    /// Days of History to retain; 0 means keep forever.
    static var historyRetentionDays: Int {
        get { defaults.integer(forKey: "historyRetentionDays") }
        set { defaults.set(newValue, forKey: "historyRetentionDays") }
    }

    static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }
}

import AppKit
import AVFoundation
import Combine
import Foundation
import os
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    ObservableObject {

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
    /// Every error surfaced anywhere in the app funnels through this
    /// property, so `didSet` is the single choke point for posting the
    /// matching user notification. The red caption in the window stays the
    /// primary in-app surface; notifications cover the dashboard-closed case.
    @Published var lastError: String? {
        didSet {
            guard let message = lastError else { return }
            Notifier.postError(message)
        }
    }
    @Published var autoPeriod: Bool = Settings.autoPeriod
    /// Opt-in: let "scratch that"/"never mind" edit or discard a dictation.
    @Published var spokenEdits: Bool = Settings.spokenEdits
    /// Whether "new line"/"new paragraph" become real breaks.
    @Published var spokenLayout: Bool = Settings.spokenLayout
    /// Opt-in: whether spoken symbol tokens ("comma", "star") convert.
    @Published var spokenSymbols: Bool = Settings.spokenSymbols
    @Published var liveCaptions: Bool = Settings.liveCaptions
    @Published var historyPaused: Bool = Settings.historyPaused
    @Published var historyRetentionDays: Int = Settings.historyRetentionDays
    @Published var historyLimit: Int = Settings.historyLimit
    /// Cleanup stop applied to every dictation: 0 Verbatim, 1 Cleaned,
    /// 2 Polished (default), 3 Tightened.
    @Published var cleanupLevel: Int = Settings.cleanupLevel
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var launchAtLoginNote: String?
    @Published var stats = LifetimeStats()

    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let hud = DictationHUD.shared
    private let recorder = AudioRecorder()
    private let history = HistoryStore()
    private let statsStore = StatsStore()
    let voiceStore = VoiceInstructionStore()
    private var transcriber = Transcriber(locale: Settings.locale)
    private lazy var hotkeyMonitor = HotkeyMonitor(hotkey: Settings.hotkey)
    let rewriteEngine = RewriteEngine()
    /// Cleanup-stop polish failures degrade silently back to rules-only
    /// output — this is their only trace, by design never a notification.
    private static let cleanupLogger = Logger(
        subsystem: "local.murmur", category: "cleanup")
    let whisperEngine = WhisperEngine()
    @Published var engine: String = Settings.engine
    @Published var whisperModel: String = Settings.whisperModel
    @Published var whisperReady = false
    /// My Voice preset forced onto every dictation regardless of app
    /// bindings. nil means no forcing — resolution falls through to the
    /// store's per-app bindings. Persisted in Settings so the menu-bar
    /// selection survives relaunches.
    @Published var selectedVoicePresetID: UUID? = Settings.selectedVoicePresetID
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

    /// Generation guard for `flashTransformStatus`: a delayed clear only
    /// wins if no newer status landed since its flash began.
    private var transformStatusGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    /// Shows `message` in the top bar briefly, then clears it — used for
    /// post-hoc confirmations like "✓ <preset>" once a voice rewrite lands.
    private func flashTransformStatus(_ message: String) {
        transformStatusGeneration += 1
        let generation = transformStatusGeneration
        transformStatus = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, generation == self.transformStatusGeneration else { return }
            self.transformStatus = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        HistoryStore.flushPendingWrites()
        StatsStore.flushPendingWrites()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioRecorder.sweepStaleRecordings()
        AppPaths.secureExistingFiles()
        entries = history.entries
        statsStore.seed(from: history.entries)
        stats = statsStore.stats
        setUpStatusItem()
        // Keep the menu-bar My Voice submenu in sync with preset edits made
        // in the dashboard. objectWillChange fires before the mutation lands,
        // so hop to the next main-queue turn to rebuild against final state.
        voiceStore.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        UNUserNotificationCenter.current().delegate =
            NotifierPresentationDelegate.shared
        // Mic level → HUD meter. The callback is already hopped to main.
        recorder.onLevel = { [weak self] rms in
            self?.hud.update(level: rms)
        }
        // The input device changed under us mid-dictation — AirPods dropping
        // out, a dock unplugged. Everything captured after this point is
        // silence or the wrong device, so finish now with what we have.
        recorder.onInputDeviceLost = { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            self.lastError = "Microphone changed during dictation \u{2014} "
                + "stopping with what was captured."
            self.stopAndTranscribe()
        }
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
            restoreSavedFrame(of: newWindow)
            // Delegate assigned after frame restoration so the windowDidMove
            // fired by center()/setFrame can't rewrite the value just read.
            newWindow.delegate = self
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshPermissions()
    }

    /// Restores the persisted dashboard frame when it would land visibly on
    /// at least one connected screen; otherwise keeps the centred default.
    private func restoreSavedFrame(of window: NSWindow) {
        guard let saved = Settings.dashboardWindowFrame else { return }
        let frame = NSRectFromString(saved)
        let usable = frame.width >= window.minSize.width
            && frame.height >= window.minSize.height
        guard usable, frameIsVisible(frame) else { return }
        window.setFrame(frame, display: false)
    }

    /// True when the frame overlaps some screen's visible frame by enough to
    /// remain usable — a one-pixel sliver counts as lost.
    private func frameIsVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width > 100 && overlap.height > 100
        }
    }

    private func persistWindowFrame() {
        guard let window else { return }
        Settings.dashboardWindowFrame = NSStringFromRect(window.frame)
    }

    func windowDidMove(_ notification: Notification) {
        persistWindowFrame()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistWindowFrame()
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

    func setSpokenEdits(_ on: Bool) {
        Settings.spokenEdits = on
        spokenEdits = on
    }

    func setSpokenLayout(_ on: Bool) {
        Settings.spokenLayout = on
        spokenLayout = on
    }

    func setSpokenSymbols(_ on: Bool) {
        Settings.spokenSymbols = on
        spokenSymbols = on
    }

    func setLiveCaptions(_ on: Bool) {
        Settings.liveCaptions = on
        liveCaptions = on
        if !on { hud.hide() }
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

    func setHistoryLimit(_ limit: Int) {
        Settings.historyLimit = limit
        historyLimit = Settings.historyLimit
        history.enforceLimit()
        entries = history.entries
        rebuildMenu()
    }

    func setCleanupLevel(_ level: Int) {
        Settings.cleanupLevel = level
        cleanupLevel = level
    }

    // MARK: History export

    /// JSON of every stored transcript, same Codable shape as history.json.
    func exportHistoryJSONData() throws -> Data {
        try history.exportJSONData()
    }

    /// Markdown rendering of every stored transcript, one bullet each.
    func exportHistoryMarkdown() -> String {
        history.exportMarkdown()
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
    /// misheard → intended word mappings from it. Returns how many were
    /// learned. Async because the diff/merge work runs off the main actor.
    @discardableResult
    func correctHistoryEntry(id: String, newText: String) async -> Int {
        guard let entry = history.entries.first(where: { $0.id == id }),
              entry.text != newText else { return 0 }
        let learnedCount = await LearnedStore.learn(
            original: entry.text, corrected: newText)
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

    // MARK: - My Voice

    func selectVoicePreset(_ id: UUID?) {
        Settings.selectedVoicePresetID = id
        selectedVoicePresetID = id
        rebuildMenu()
    }

    /// Which My Voice instruction applies to this dictation, if any: a
    /// forced selection (while still enabled) beats the store's first
    /// enabled instruction bound to the target app. nil means the dictation
    /// is inserted without voice rewriting.
    func resolveVoiceInstruction(forApp bundleID: String?) -> VoiceInstruction? {
        if let selectedVoicePresetID,
           let forced = voiceStore.instructions.first(
            where: { $0.id == selectedVoicePresetID }),
           forced.isEnabled {
            return forced
        }
        return voiceStore.preset(for: bundleID)
    }

    /// Runs the user's chosen recognition engine. Dictation never waits on
    /// Whisper: while its model is still downloading or loading, Apple's
    /// engine handles the dictation, and Whisper takes over once ready.
    /// Whisper failures also fall back to Apple so a keypress always
    /// produces text.
    private func recognize(fileAt url: URL) async throws -> String {
        // Nonisolated async: the up-to-four-file vocabulary read runs off
        // the main actor instead of stalling it before transcription starts.
        let biasTerms = await LearnedStore.biasTerms()
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


    // MARK: - The one model pass a dictation gets

    /// One on-device model pass over a finished transcript, plus what to do
    /// with whatever comes back.
    ///
    /// A My Voice preset, a per-app Style and the automatic cleanup polish
    /// do the same four steps and differ only in policy. Keeping that policy
    /// in one value puts the three side by side instead of nested three deep,
    /// each with its own copy of the same call.
    private struct RewritePass {
        /// Caption shown while the pass runs. Nil runs silently, and a
        /// silent pass never touches `transformStatus` at all.
        let announcement: String?
        /// Caption flashed after a rewrite is accepted. Nil stays silent.
        let confirmation: String?
        /// How far the result may diverge before it is discarded.
        let profile: RewriteEngine.RewriteProfile
        /// Log label, so a discarded rewrite names the pass that made it.
        let context: String
        /// Prefix for a user-facing error. Nil logs instead of notifying,
        /// which is right for a pass whose absence the user cannot see.
        let failureLabel: String?
        /// The call itself. My Voice takes a different `rewrite` overload.
        let run: (String) async throws -> String
    }

    /// The single model pass this insertion gets, or nil for none.
    ///
    /// Precedence is deliberate and total: a My Voice preset replaces an app
    /// Style, and either replaces the automatic cleanup polish. They never
    /// stack, so one dictation is never rewritten twice.
    ///
    /// Only cleanup is gated on `needsPolish`. A preset or a Style is an
    /// explicit choice by the user, so it applies however short the text.
    /// Cleanup is automatic, so it has to earn the latency it costs.
    private func rewritePass(
        for text: String, targetBundleID: String?
    ) -> RewritePass? {
        guard !text.isEmpty, rewriteEngine.isAvailable else { return nil }
        let engine = rewriteEngine

        if let voice = resolveVoiceInstruction(forApp: targetBundleID) {
            return RewritePass(
                announcement: "Applying \(voice.name)…",
                confirmation: "✓ \(voice.name)",
                profile: .freeform,
                context: "my-voice",
                failureLabel: voice.name,
                run: { try await engine.rewrite(
                    $0, voiceInstructions: voice.instructions) })
        }

        let style = StyleSettings.style(forBundleID: targetBundleID)
        if let instructions = style.instructions {
            return RewritePass(
                announcement: "Applying \(style.displayName) style…",
                confirmation: nil,
                profile: .preserving,
                context: "style",
                // Don't fail silently: the Style setting would look on but
                // simply stop applying past some length with no reason given.
                failureLabel: "Style",
                run: { try await engine.rewrite($0, instructions: instructions) })
        }

        let level = CleanupLevel.resolve(Settings.cleanupLevel)
        if let instructions = level.polishInstructions,
           RewriteEngine.needsPolish(text) {
            return RewritePass(
                announcement: nil,
                confirmation: nil,
                profile: level == .tightened ? .condensing : .preserving,
                context: "cleanup-\(level.rawValue)",
                // A failure here degrades invisibly to rules-only output.
                // The user still gets correct text, so no banner.
                failureLabel: nil,
                run: { try await engine.rewrite($0, instructions: instructions) })
        }
        return nil
    }

    /// Runs one pass and returns the text to insert.
    ///
    /// The model saw the user's own speech, so a result that is no longer
    /// recognizably that dictation means the pass lost control of it: keep
    /// the rules-only text and let the log record why. A thrown error
    /// degrades the same way. Either way the dictation is never dropped.
    private func applying(_ pass: RewritePass, to text: String) async -> String {
        // Clear only a caption this pass actually set, so a silent pass
        // cannot wipe a caption something else put there.
        let announced = pass.announcement != nil
        if announced { transformStatus = pass.announcement }
        do {
            let rewritten = try await pass.run(text)
            guard let accepted = RewriteEngine.acceptedRewrite(
                original: text, rewritten: rewritten,
                profile: pass.profile, context: pass.context)
            else {
                if announced { transformStatus = nil }
                return text
            }
            if let confirmation = pass.confirmation {
                flashTransformStatus(confirmation)
            } else if announced {
                transformStatus = nil
            }
            return accepted
        } catch {
            if announced { transformStatus = nil }
            if let label = pass.failureLabel {
                lastError = "\(label) wasn't applied: \(error.localizedDescription)"
            } else {
                Self.cleanupLogger.error(
                    "Polish pass failed, inserting rules-only text: \(String(describing: error), privacy: .public)")
            }
            return text
        }
    }

    // MARK: - Hotkey wiring

    private func wireHotkey() {
        hotkeyMonitor.onUndoAttempt = { [weak self] in
            guard let self else { return false }
            return self.undoLastInsertionIfEligible()
        }
        hotkeyMonitor.onStart = { [weak self] in
            DispatchQueue.main.async { self?.startRecording() }
        }
        hotkeyMonitor.onStop = { [weak self] in
            DispatchQueue.main.async { self?.stopAndTranscribe() }
        }
        hotkeyMonitor.onCancel = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // `cancel()` finishes the buffer stream, so the streaming task
                // returns on its own; cancelling it just drops the result.
                self.recorder.cancel()
                 self.streamingTask?.cancel()
                 self.streamingTask = nil
                 self.hud.hide()
                 self.uiState = .idle
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
    /// Most recent successful insertion, for hotkey-triggered undo.
    private var lastInsertion: LastInsertion?
    /// Live transcription in flight, when `Settings.streamingTranscription`
    /// is on. Nil for the default file-based path.
    private var streamingTask: Task<String, Error>?

    /// Live transcription only applies to Apple's SpeechAnalyzer — WhisperKit
    /// transcribes a finished file, so the Whisper engine always takes the
    /// file path regardless of the flag.
    private var streamingEnabled: Bool {
        Settings.streamingTranscription && Settings.engine != "whisper"
    }

    /// Consumes a hotkey press as an undo when the last insertion is still
    /// pending, inside the window, and this frontmost app is the app it went
    /// into. Runs on the main thread straight from the monitor's state
    /// machine, before any recording could start.
    private func undoLastInsertionIfEligible() -> Bool {
        guard let last = lastInsertion else { return false }
        let action = InsertionTracker.action(
            now: Date(), last: last,
            frontAppBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            windowSeconds: InsertionTracker.windowSeconds)
        guard action == .undo else { return false }
        // Clear first so a failed mechanical undo can't loop on retry.
        lastInsertion = nil
        TextInserter.undo(last)
        NSSound(named: "Tink")?.play()
        return true
    }

    /// Skips for spoken edit commands: failures and stand-downs are worth a
    /// breadcrumb, successes stay silent.
    private static let editsLogger = Logger(
        subsystem: "local.murmur", category: "edits")

    /// Reverses the most recent insertion on behalf of a spoken edit command
    /// ("scratch that", "delete last sentence"). Unlike the hotkey undo there
    /// is no time window — any age within this session qualifies — but the
    /// frontmost app must still be the one the text went into (unknown on
    /// either side is forgiven), so a scratch never deletes another app's
    /// text. With nothing recorded this logs and does nothing; callers skip
    /// the insertion either way. No notification on success.
    private func undoPendingInsertion(reason: String) {
        guard let last = lastInsertion else {
            Self.editsLogger.info(
                "\(reason, privacy: .public): no pending insertion to undo")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard frontmost == nil || last.bundleID == nil || frontmost == last.bundleID
        else {
            Self.editsLogger.info(
                "\(reason, privacy: .public): skipped — frontmost app changed since insertion")
            return
        }
        // Clear first so a failed mechanical undo can't loop on retry.
        lastInsertion = nil
        TextInserter.undo(last)
        NSSound(named: "Tink")?.play()
    }

    private func startRecording() {
        guard uiState != .recording else { return }
        do {
            if streamingEnabled {
                let started = try recorder.startStreaming()
                let transcriber = self.transcriber
                transcriber.onPartialTranscript = { [weak self] text in
                    DispatchQueue.main.async { self?.hud.update(caption: text) }
                }
                streamingTask = Task {
                    // The vocabulary read touches several JSON files; fetch
                    // it inside the task (off main via the nonisolated async
                    // call) so key-down handling never waits on disk.
                    let biasTerms = await LearnedStore.biasTerms()
                    return try await transcriber.transcribe(
                        buffers: started.stream, inputFormat: started.format,
                        biasTerms: biasTerms)
                }
            } else {
                try recorder.start()
            }
            recordingStartedAt = Date()
            recordingTargetBundleID =
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            uiState = .recording
            lastError = nil
            NSSound(named: "Pop")?.play()
            if Settings.liveCaptions { hud.show() }
        } catch {
            hud.hide()
            lastError = "Could not start recording: \(error.localizedDescription)"
            NSSound(named: "Basso")?.play()
        }
    }

    /// Awaits the live transcript, falling back to the file that was recorded
    /// alongside it if streaming produced nothing usable. A dictation is never
    /// lost to a streaming failure — the user just waits the old amount of time
    /// and sees why in `lastError`.
    private func streamedTranscript(
        from task: Task<String, Error>, fallingBackTo url: URL) async throws -> String {
        do {
            let text = try await task.value
            if !text.isEmpty { return text }
            lastError = "Live transcription returned nothing — " +
                "transcribed the recording instead."
        } catch {
            lastError = "Live transcription failed (\(error.localizedDescription)) — " +
                "transcribed the recording instead."
        }
        return try await recognize(fileAt: url)
    }

    private func stopAndTranscribe() {
        isHandsFree = false
        hud.hide()
        let streaming = streamingTask
        streamingTask = nil
        guard let url = recorder.stop() else {
            streaming?.cancel()
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
                let raw: String
                if let streaming {
                    raw = try await streamedTranscript(from: streaming, fallingBackTo: url)
                } else {
                    raw = try await recognize(fileAt: url)
                }
                // Regex passes plus the dictionary/learned/snippet JSON
                // lookups are pure CPU+disk work over value types — run
                // them off the main actor and await only the result. UI
                // state below stays on the main actor untouched.
                var formatted = await Task.detached(priority: .userInitiated) { () -> String in
                    let formatter = TextFormatter(locale: Settings.locale)
                    // Stop 0 keeps filler words and skips caps/period;
                    // the dictionary and spoken layout commands stay
                    // active at every stop — they are deliberate intents.
                    // Spoken layout ("new line") is a deliberate intent at
                    // every stop, verbatim included — but only while the
                    // user leaves it on. Threaded explicitly so the
                    // formatter stays a pure function of its arguments.
                    let spokenLayout = Settings.spokenLayout
                    // Spoken symbol tokens ("comma", "star", "dash") are a
                    // separate opt-in, off by default: both recognizers
                    // already punctuate, so the tokens are mostly redundant
                    // while the false-positive rate on ordinary words is high.
                    let spokenSymbols = Settings.spokenSymbols
                    var text = CleanupLevel.resolve(Settings.cleanupLevel) == .verbatim
                        ? formatter.formatVerbatim(
                            raw, spokenLayout: spokenLayout,
                            spokenSymbols: spokenSymbols)
                        : formatter.format(
                            raw, spokenLayout: spokenLayout,
                            spokenSymbols: spokenSymbols)
                    text = LearnedStore.apply(in: text)
                    return SnippetStore.expand(in: text)
                }.value

                // Spoken edit commands ("scratch that", "delete last
                // sentence") act on the cleaned text before any model pass:
                // an utterance about to scratch itself should never pay for
                // a rewrite, and the delete command needs to know what the
                // previous insertion was. SpeechEdits owns all decisions;
                // this is purely their application.
                // ...and only when the user asked for them. Off (the
                // default) the transcript is never scanned for command
                // phrases at all, so saying "sorry, I meant Tuesday" or
                // "never mind the second option" inserts those words
                // instead of deleting the dictation.
                let editPlan = SpeechEdits.gatedPlan(
                    currentTranscript: formatted,
                    previousText: lastInsertion?.text,
                    enabled: Settings.spokenEdits)
                if let replacement = editPlan.combinedReplacement {
                    undoPendingInsertion(reason: "delete last sentence")
                    formatted = replacement
                } else {
                    switch editPlan.outcome {
                    case .discardAll:
                        undoPendingInsertion(reason: "scratch command")
                        uiState = .idle
                        return
                    case .replaceCurrent(let remainder):
                        formatted = remainder
                    case .none:
                        break
                    }
                }

                // At most one model pass, chosen by a precedence that lives
                // in `rewritePass` rather than in nesting here.
                if let pass = rewritePass(
                    for: formatted, targetBundleID: targetBundleID) {
                    formatted = await applying(pass, to: formatted)
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
                        let outcome = TextInserter.insert(formatted)
                        lastInsertion = LastInsertion(
                            text: formatted, method: outcome.method, date: Date(),
                            bundleID: NSWorkspace.shared.frontmostApplication?
                                .bundleIdentifier ?? targetBundleID,
                            replacedText: outcome.replacedText)
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

        let voiceItem = NSMenuItem(title: "My Voice", action: nil, keyEquivalent: "")
        let voiceSubmenu = NSMenu()
        let none = NSMenuItem(
            title: "None (no rewriting)",
            action: #selector(selectVoicePresetFromMenu(_:)), keyEquivalent: "")
        none.target = self
        none.state = selectedVoicePresetID == nil ? .on : .off
        voiceSubmenu.addItem(none)
        for instruction in voiceStore.instructions {
            let item = NSMenuItem(
                title: instruction.isEnabled
                    ? instruction.name
                    : "\(instruction.name) (off)",
                action: #selector(selectVoicePresetFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = instruction.id.uuidString
            item.isEnabled = instruction.isEnabled
            item.state = selectedVoicePresetID == instruction.id ? .on : .off
            voiceSubmenu.addItem(item)
        }
        voiceItem.submenu = voiceSubmenu
        menu.addItem(voiceItem)

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

    /// Menu-bar My Voice quick-switch. "None" carries no representedObject,
    /// so an unparseable payload resolves to clearing the selection.
    @objc private func selectVoicePresetFromMenu(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let id = UUID(uuidString: identifier) else {
            selectVoicePreset(nil)
            return
        }
        selectVoicePreset(id)
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

    /// Live transcription: feed the microphone to SpeechAnalyzer while the
    /// user speaks instead of transcribing the finished file afterwards.
    /// Apple engine only (WhisperKit needs a finished file).
    ///
    /// On by default, because transcribing after release is pure added wait:
    /// measured at ~230 ms for 11 s of speech, plus the four-file vocabulary
    /// read that the file path performs after key-up and this path performs
    /// at key-down. The `.caf` is still written either way, so a streaming
    /// failure falls back to the file and costs only the time it saved.
    /// Turn it off with
    /// `defaults write local.murmur streamingTranscription -bool false`.
    static var streamingTranscription: Bool {
        get { defaults.object(forKey: "streamingTranscription") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "streamingTranscription") }
    }

    /// Whether recognized text gets a trailing period auto-appended.
    static var autoPeriod: Bool {
        get { defaults.object(forKey: "autoPeriod") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoPeriod") }
    }

    /// Rejoins sentences the recognizer split at a breath rather than at a
    /// real boundary ("the primary blender. Motor." -> "the primary
    /// blender motor"). Punctuation repair only: the pass deletes a
    /// period and lowercases the letter behind it, never touching words,
    /// so it cannot reinterpret what was said. On by default.
    static var joinFragments: Bool {
        get { defaults.object(forKey: "joinFragments") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "joinFragments") }
    }

    /// How aggressively dictations are cleaned up: 0 Verbatim,
    /// 1 Cleaned (default), 2 Polished, 3 Tightened.
    ///
    /// The unset default is Polished, which DOES run the on-device model.
    ///
    /// It was Cleaned (model-free) until the owner supplied a written voice
    /// guide and asked for the rewrite explicitly. That is a deliberate
    /// trade, not a relaxation: the model pass is the only way to compress
    /// a rambling dictation, and it is also the path that once turned a
    /// dictation mentioning "caveman mode" into caveman speech. Four
    /// independent defences stand between those facts, none of which is a
    /// prompt asking the model to behave:
    ///   1. the transcript is delimited as data, with lookalike tags
    ///      neutralized, so it is never the conversational turn;
    ///   2. `isPlausibleRewrite` discards output that diverges from the
    ///      input in length, content-word recall, or precision;
    ///   3. `introducedBannedPhrasing` discards output that reaches for
    ///      vocabulary or punctuation the speaker did not use;
    ///   4. every rejection degrades to the rules-only text, silently.
    /// Set this to 1 to get the model out of the path entirely.
    static var cleanupLevel: Int {
        get {
            let level = defaults.object(forKey: "cleanupLevel") as? Int ?? 2
            return min(max(level, 0), 3)
        }
        set { defaults.set(newValue, forKey: "cleanupLevel") }
    }

    /// Spoken edit commands ("scratch that", "never mind", "delete last
    /// sentence") acting on the finished dictation. OFF by default: those
    /// are ordinary English phrases, and Murmur cannot tell a retraction
    /// from someone simply saying the words, so an un-opted-in user must
    /// never have text silently eaten. When false, `SpeechEdits` never
    /// runs and the transcript passes through byte-for-byte.
    static var spokenEdits: Bool {
        get { defaults.object(forKey: "spokenEdits") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "spokenEdits") }
    }

    /// Spoken layout commands ("new line", "new paragraph") turning into
    /// real breaks. ON by default — standard dictation behavior and the
    /// only way to produce a paragraph by voice — but killable for anyone
    /// who dictates those words literally. Additive only: it can insert a
    /// break, never delete text.
    static var spokenLayout: Bool {
        get { defaults.object(forKey: "spokenLayout") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "spokenLayout") }
    }

    /// Spoken symbol tokens ("comma" -> ",", "star" -> "*", "dash" -> "-")
    /// converting into glyphs. OFF by default: both recognition engines
    /// already insert punctuation on their own, so the tokens are largely
    /// redundant, while the false-positive rate on ordinary words like
    /// "period", "star", "dash" and "colon" is high ("add a star there").
    /// When false, `applySymbolsAndLayout` never runs and those words are
    /// typed as spoken.
    static var spokenSymbols: Bool {
        get { defaults.object(forKey: "spokenSymbols") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "spokenSymbols") }
    }

    /// Floating live-caption/waveform HUD shown while dictating.
    static var liveCaptions: Bool {
        get { defaults.object(forKey: "liveCaptions") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "liveCaptions") }
    }

    /// Last-known dashboard window frame, encoded with `NSStringFromRect`.
    static var dashboardWindowFrame: String? {
        get { defaults.string(forKey: "dashboardWindowFrame") }
        set { defaults.set(newValue, forKey: "dashboardWindowFrame") }
    }

    /// When true, the dictation hotkey is swallowed via a session event tap
    /// so the frontmost app never sees it. Off by default: fn is also a live
    /// modifier (fn+arrows for Home/End, fn+Delete, fn+F-keys), and swallowing
    /// its flagsChanged can break those combos system-wide.
    static var consumeHotkey: Bool {
        get { defaults.bool(forKey: "consumeHotkey") }
        set { defaults.set(newValue, forKey: "consumeHotkey") }
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

    /// Maximum number of transcripts kept in History. Values outside
    /// 10...1000 are clamped on both read and write; unset means 50.
    static var historyLimit: Int {
        get {
            let raw = defaults.object(forKey: "historyLimit") as? Int ?? 50
            return min(max(raw, 10), 1000)
        }
        set { defaults.set(min(max(newValue, 10), 1000), forKey: "historyLimit") }
    }

    /// UUID of the My Voice preset forced onto every dictation; nil means
    /// no forced preset (per-app bindings still resolve normally).
    static var selectedVoicePresetID: UUID? {
        get {
            guard let raw = defaults.string(forKey: "selectedVoicePresetID")
            else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.uuidString, forKey: "selectedVoicePresetID")
            } else {
                defaults.removeObject(forKey: "selectedVoicePresetID")
            }
        }
    }

    static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }
}

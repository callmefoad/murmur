import AppKit
import Carbon.HIToolbox
import Foundation

struct Transform: Identifiable {
    let id: String
    let name: String
    let keyLabel: String
    let keyCode: UInt16
    let description: String
    let instructions: String

    static let all: [Transform] = [
        Transform(
            id: "polish",
            name: "Polish",
            keyLabel: "⌃⌥1",
            keyCode: UInt16(kVK_ANSI_1),
            description: "Fixes grammar, spelling and punctuation and tightens " +
                         "the wording without changing meaning or tone.",
            instructions: "Polish the user's text: fix grammar, spelling and " +
                "punctuation, and improve clarity and flow. Keep the meaning, " +
                "tone, formatting and language unchanged."),
        Transform(
            id: "promptEngineer",
            name: "Prompt Engineer",
            keyLabel: "⌃⌥2",
            keyCode: UInt16(kVK_ANSI_2),
            description: "Turns a rough idea into a clear, well-structured " +
                         "prompt for an AI assistant.",
            instructions: "Rewrite the user's rough notes as a clear, " +
                "well-structured prompt for an AI assistant: state the goal, " +
                "the relevant context, explicit instructions, and any " +
                "constraints or output format requirements."),
    ]
}

/// Global ⌃⌥1 / ⌃⌥2 hotkeys that rewrite the currently selected text in place,
/// in any app — like Wispr Flow's Transforms. Uses the on-device model.
@MainActor
final class TransformManager {
    enum Mode {
        /// A `CGEventTap` is installed; the chord never reaches the frontmost app.
        case consuming
        /// Passive `NSEvent` monitors; the chord still reaches other apps.
        case passive
        case off
    }

    private let engine: RewriteEngine
    private var eventTap: EventTap?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRunning = false

    private(set) var mode: Mode = .off
    var isConsuming: Bool { mode == .consuming }

    /// Status line for the UI; nil clears it.
    var onStatus: ((String?) -> Void)?
    var onError: ((String) -> Void)?

    init(engine: RewriteEngine) {
        self.engine = engine
    }

    func startMonitoring() {
        stopMonitoring()

        // Preferred path: a session event tap, so the chord is swallowed and
        // never reaches the frontmost app.
        let tap = EventTap { [weak self] _, event in
            guard self != nil else { return event }
            // Only the match decision happens here — cheap, no blocking.
            guard let nsEvent = NSEvent(cgEvent: event),
                  let transform = TransformManager.matchingTransform(for: nsEvent)
            else { return event }
            Task { @MainActor [weak self] in self?.run(transform) }
            return nil  // consume: nothing else matches this chord
        }

        if tap.start(mask: .mask(for: .keyDown)) == nil {
            eventTap = tap
            mode = .consuming
            return
        }

        // Fallback: passive monitors. Cannot consume, but keeps the chord alive.
        mode = .passive
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return }
            guard let transform = TransformManager.matchingTransform(for: event) else { return }
            Task { @MainActor in self.run(transform) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            guard let transform = TransformManager.matchingTransform(for: event) else { return event }
            Task { @MainActor in self.run(transform) }
            return nil
        }
    }

    func stopMonitoring() {
        eventTap?.stop()
        eventTap = nil
        mode = .off
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
    }

    /// Returns the transform matching this key event's modifiers and key code, if any.
    /// `nonisolated static` so the event-tap callback (which is not on the
    /// main actor) can call it without hopping.
    nonisolated static func matchingTransform(for event: NSEvent) -> Transform? {
        let modifiers = event.modifierFlags.intersection(
            [.command, .option, .control, .shift])
        guard modifiers == [.control, .option] else { return nil }
        return Transform.all.first(where: { $0.keyCode == event.keyCode })
    }

    func run(_ transform: Transform) {
        guard !isRunning else { return }
        guard engine.isAvailable else {
            onError?(engine.availabilityNote ?? "On-device model unavailable.")
            NSSound(named: "Basso")?.play()
            return
        }
        isRunning = true
        onStatus?("\(transform.name): reading selection…")

        Task {
            defer {
                isRunning = false
                onStatus?(nil)
            }
            // Establishes (or joins) the shared pending restore before
            // doing anything that could fail — see TextInserter's
            // RestoreOwner for why this must not snapshot independently
            // of any concurrent TextInserter.insert(_:) in flight.
            TextInserter.beginClipboardHold()
            guard let selection = await TextInserter.copySelection(),
                  !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                TextInserter.restoreHeldClipboard()
                onError?("Select some text first, then press " +
                         "\(transform.keyLabel).")
                NSSound(named: "Basso")?.play()
                return
            }

            onStatus?("\(transform.name): rewriting…")
            do {
                let rewritten = try await engine.rewrite(
                    selection, instructions: transform.instructions)
                guard !rewritten.isEmpty else {
                    throw NSError(domain: "Murmur", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Model returned empty text",
                    ])
                }
                let stamp = TextInserter.writeConcealed(rewritten)
                TextInserter.sendKeystroke(kVK_ANSI_V, flags: .maskCommand)
                NSSound(named: "Tink")?.play()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                TextInserter.attemptRestore(expectedStamp: stamp)
            } catch {
                TextInserter.restoreHeldClipboard()
                onError?("\(transform.name) failed: \(error.localizedDescription)")
                NSSound(named: "Basso")?.play()
            }
        }
    }

    /// Runs a transform on arbitrary text (used by the Transforms page).
    func apply(_ transform: Transform, to text: String) async throws -> String {
        try await engine.rewrite(text, instructions: transform.instructions)
    }
}

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
    private let engine: RewriteEngine
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRunning = false

    /// Status line for the UI; nil clears it.
    var onStatus: ((String?) -> Void)?
    var onError: ((String) -> Void)?

    init(engine: RewriteEngine) {
        self.engine = engine
    }

    func startMonitoring() {
        stopMonitoring()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return }
            guard let transform = self.matchingTransform(for: event) else { return }
            Task { @MainActor in self.run(transform) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            guard let transform = self.matchingTransform(for: event) else { return event }
            Task { @MainActor in self.run(transform) }
            return nil
        }
    }

    func stopMonitoring() {
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
    private func matchingTransform(for event: NSEvent) -> Transform? {
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

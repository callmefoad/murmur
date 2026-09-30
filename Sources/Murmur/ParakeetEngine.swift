import Foundation
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

/// Murmur's "Parakeet" recognition engine: NVIDIA's Parakeet TDT model
/// (moondream's "Ultra" post-training) running locally on the Neural Engine
/// through FluidAudio. Transcribes a finished recording in a fraction of a
/// second and catches words Apple's recognizer drops. It still ends
/// sentences at long pauses, so the Punctuator pass runs after it too.
/// The same engine FluidVoice and VoiceInk use.
/// The model downloads once (about 600 MB); recognition is offline.
@MainActor
final class ParakeetEngine {

    static let isAvailableInBuild: Bool = {
        #if canImport(FluidAudio)
        true
        #else
        false
        #endif
    }()

    /// Status line for the UI (downloading/loading); nil clears.
    var onStatus: ((String?) -> Void)?
    var onError: ((String) -> Void)?

    #if canImport(FluidAudio)
    private static let version: AsrModelVersion = .ultra
    private var loadTask: Task<AsrManager, Error>?
    private var manager: AsrManager?
    #endif

    /// True once the model is loaded and can transcribe now.
    var isReady: Bool {
        #if canImport(FluidAudio)
        manager != nil
        #else
        false
        #endif
    }

    var isModelDownloaded: Bool {
        #if canImport(FluidAudio)
        AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: Self.version), version: Self.version)
        #else
        false
        #endif
    }

    /// Kicks off the model download/load in the background.
    func preload() {
        #if canImport(FluidAudio)
        Task { _ = try? await self.loadedManager() }
        #endif
    }

    #if canImport(FluidAudio)
    private func loadedManager() async throws -> AsrManager {
        if let manager { return manager }
        if let loadTask { return try await loadTask.value }

        onStatus?(isModelDownloaded
            ? "Loading Parakeet model…"
            : "Downloading Parakeet model (one-time, about 600 MB)…")
        let task = Task { () -> AsrManager in
            let models = try await AsrModels.downloadAndLoad(version: Self.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        loadTask = task
        defer { onStatus?(nil) }
        do {
            let loaded = try await task.value
            manager = loaded
            loadTask = nil
            return loaded
        } catch {
            // Evict the failed load so the next attempt retries.
            loadTask = nil
            if !(error is CancellationError) {
                onError?("Parakeet model failed to load: \(error.localizedDescription)")
            }
            throw error
        }
    }
    #endif

    func transcribe(fileAt url: URL) async throws -> String {
        #if canImport(FluidAudio)
        let manager = try await loadedManager()
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(url, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw NSError(domain: "Murmur", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "This Murmur build does not include Parakeet.",
        ])
        #endif
    }
}

import AVFoundation
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
    /// Silero voice-activity model (about 2 MB) for live segmenting.
    private var vad: VadManager?
    private var vadTask: Task<Void, Never>?
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
        loadVad()
        #endif
    }

    /// Transcribes while the user is still talking, or nil when the live
    /// path isn't loaded yet (the finished file is transcribed instead).
    func liveTranscriber() -> ParakeetLiveTranscriber? {
        #if canImport(FluidAudio)
        guard let manager, let vad else {
            if self.vad == nil { loadVad() }
            return nil
        }
        return ParakeetLiveTranscriber(manager: manager, vad: vad)
        #else
        return nil
        #endif
    }

    #if canImport(FluidAudio)
    private func loadVad() {
        guard vad == nil, vadTask == nil else { return }
        vadTask = Task {
            // Failure only disables the live path; dictation still works.
            self.vad = try? await VadManager(config: .default)
            self.vadTask = nil
        }
    }
    #endif

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

/// Live half of the Parakeet engine. Audio is resampled to 16 kHz, a
/// voice-activity model scores each 256 ms, and every time the user pauses
/// the speech since the last pause is transcribed in the background. On
/// release only the final stretch is left, so a long dictation pastes about
/// as fast as a short one. Silence between pauses is never sent to the
/// model. Segment rules live in `SpeechSegmenter`.
struct ParakeetLiveTranscriber: Sendable {
    struct Result: Sendable {
        let text: String
        /// Input-format frames that actually arrived, so the caller can
        /// tell whether the stream dropped audio under load.
        let inputFrames: Int64
        let segments: Int
    }

    #if canImport(FluidAudio)
    let manager: AsrManager
    let vad: VadManager
    #endif

    func transcribe(
        buffers: AsyncStream<AVAudioPCMBuffer>, inputFormat: AVAudioFormat
    ) async throws -> Result {
        #if canImport(FluidAudio)
        guard let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else {
            throw NSError(domain: "Murmur", code: 43, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported microphone format for live Parakeet.",
            ])
        }
        let chunk = SpeechSegmenter.chunkSamples
        var samples: [Float] = []
        samples.reserveCapacity(16_000 * 60)
        var fed = 0
        var inputFrames: Int64 = 0
        var segmenter = SpeechSegmenter()
        var vadState = await vad.makeStreamState()
        var jobs: [Task<String, Error>] = []

        func startJob(_ chunks: Range<Int>) {
            let range = SpeechSegmenter.sampleRange(chunks, totalSamples: samples.count)
            var audio = Array(samples[range])
            // Parakeet refuses clips under 0.3 s; pad a short word with silence.
            if audio.count < 16_000 / 2 { audio += [Float](repeating: 0, count: 16_000 / 2 - audio.count) }
            let manager = self.manager
            jobs.append(Task {
                var state = TdtDecoderState.make()
                return try await manager.transcribe(audio, decoderState: &state).text
            })
        }

        func score(_ window: [Float]) async throws {
            let result = try await vad.processStreamingChunk(window, state: vadState)
            vadState = result.state
            if let cut = segmenter.feed(result.probability) { startJob(cut) }
        }

        do {
            for await buffer in buffers {
                inputFrames += Int64(buffer.frameLength)
                samples += Self.convert(buffer, with: converter, to: target)
                while samples.count - fed >= chunk {
                    let window = Array(samples[fed..<fed + chunk])
                    fed += chunk
                    try await score(window)
                }
            }
            if samples.count > fed {
                try await score(Array(samples[fed...]))
            }
            if let cut = segmenter.finish() { startJob(cut) }

            var parts: [String] = []
            for job in jobs { parts.append(try await job.value) }
            return Result(text: SpeechSegmenter.join(parts),
                          inputFrames: inputFrames, segments: jobs.count)
        } catch {
            jobs.forEach { $0.cancel() }
            throw error
        }
        #else
        throw NSError(domain: "Murmur", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "This Murmur build does not include Parakeet.",
        ])
        #endif
    }

    /// Resamples one tap buffer to 16 kHz mono. The converter is reused
    /// across buffers so its filter state carries over and there are no
    /// clicks at buffer edges.
    private static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return [] }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

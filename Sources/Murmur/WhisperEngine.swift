import AVFAudio
import Foundation
#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

/// Murmur's optional "Precise" recognition engine: OpenAI's Whisper model
/// running locally via WhisperKit (CoreML on the Neural Engine). Slower to
/// warm up than Apple's engine but stronger on accents and jargon, and it
/// supports vocabulary biasing through the decoder prompt — the user's
/// dictionary, snippets and learned terms are fed in before recognition.
/// The model downloads once into Application Support; recognition is offline.
@MainActor
final class WhisperEngine {

    static let isAvailableInBuild: Bool = {
        #if canImport(WhisperKit)
        true
        #else
        false
        #endif
    }()

    static let availableModels: [(id: String, label: String)] = [
        ("base", "Base — fastest, ~150 MB"),
        ("small", "Small — balanced, recommended, ~500 MB"),
        ("distil-whisper_distil-large-v3_turbo",
         "Distil Large v3 — fast + precise, English only, ~600 MB"),
        ("large-v3-v20240930_turbo", "Large v3 Turbo — most precise, slow, ~1.6 GB"),
    ]

    /// Status line for the UI (loading/downloading/transcribing); nil clears.
    var onStatus: ((String?) -> Void)?
    /// Fired when a model load fails, separate from `onStatus` so the
    /// `defer { onStatus?(nil) }` in `pipeline(model:)` doesn't clear it.
    var onError: ((String) -> Void)?

    #if canImport(WhisperKit)
    private var loadTask: Task<WhisperKit, Error>?
    #endif
    private var loadedModel: String?
    /// Set only after the pipeline has fully loaded and prewarmed.
    private var readyModel: String?

    private var modelsDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent(
            "whisper-models", isDirectory: true)
    }

    /// True once the pipeline is loaded in memory and can transcribe now.
    func isReady(model: String) -> Bool {
        #if canImport(WhisperKit)
        readyModel == model
        #else
        false
        #endif
    }

    /// True once all model files exist locally (no download needed).
    func isModelDownloaded(_ model: String) -> Bool {
        #if canImport(WhisperKit)
        guard let contents = try? FileManager.default.subpathsOfDirectory(
            atPath: modelsDirectory.path) else { return false }
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
                        "MelSpectrogram.mlmodelc"]
        return required.allSatisfy { component in
            contents.contains {
                $0.contains(model) && $0.contains(component)
                    && $0.hasSuffix("coremldata.bin")
            }
        }
        #else
        false
        #endif
    }

    /// Kicks off model load/download in the background.
    func preload(model: String) {
        #if canImport(WhisperKit)
        Task { _ = try? await self.pipeline(model: model) }
        #endif
    }

    #if canImport(WhisperKit)
    private func pipeline(model: String) async throws -> WhisperKit {
        if loadedModel == model, let loadTask {
            return try await loadTask.value
        }
        loadTask?.cancel()
        loadedModel = model
        readyModel = nil

        let needsDownload = !isModelDownloaded(model)
        onStatus?(needsDownload
            ? "Downloading Whisper model (one-time)…"
            : "Loading Whisper model…")
        let directory = modelsDirectory
        let task = Task { () -> WhisperKit in
            let config = WhisperKitConfig(
                model: model,
                downloadBase: directory,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true)
            return try await WhisperKit(config)
        }
        loadTask = task
        defer { onStatus?(nil) }
        do {
            let pipe = try await task.value
            if loadedModel == model {
                readyModel = model
            }
            return pipe
        } catch {
            // Evict the failed load so the next attempt actually retries,
            // instead of rethrowing the same cached error forever.
            if loadedModel == model {
                loadTask = nil
                loadedModel = nil
            }
            // Switching models cancels the in-flight load (see `loadTask?.cancel()`
            // above) — that cancellation surfaces here as an error too, but it
            // isn't a failure and shouldn't produce a "failed to load" banner
            // every time the user changes models.
            if !(error is CancellationError) && !Task.isCancelled {
                onError?("Whisper model failed to load: \(error.localizedDescription)")
            }
            throw error
        }
    }
    #endif

    // MARK: - Language mapping

    /// The full set of language tokens Whisper's multilingual models accept,
    /// grounded in the vendored WhisperKit list
    /// (`TextDecoder Constants.languages`, Models.swift).
    static let whisperTokens: Set<String> = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr",
        "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi",
        "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no",
        "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk",
        "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk",
        "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
        "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc",
        "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl",
        "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su", "yue",
    ]

    /// BCP-47 primary subtags that need more than region-stripping to become
    /// a valid Whisper token.
    static let languageOverrides: [String: String] = [
        "nb": "no",   // Norwegian Bokmål — Whisper only has "no"/"nn"
        "cmn": "zh",  // Mandarin macrolanguage tag
        "iw": "he",   // legacy Hebrew code still emitted by some APIs
        "in": "id",   // legacy Indonesian code
        "ji": "yi",   // legacy Yiddish code
        "jv": "jw",   // Javanese: ISO 639-1 "jv" vs Whisper token "jw"
    ]

    /// Maps a BCP-47 locale identifier ("en-US", "zh-Hant-TW", "yue-Hant-HK")
    /// to the closest Whisper language token. Pure function; falls back to
    /// "en" when nothing matches. Script/region variants of Chinese all map
    /// to "zh" because that is all the model offers ("yue" requires an
    /// explicit yue-* locale).
    static func whisperLanguage(for localeID: String) -> String {
        guard let primary = localeID.split(separator: "-").first else {
            return "en"
        }
        let code = primary.lowercased()
        if let override = languageOverrides[code] { return override }
        return whisperTokens.contains(code) ? code : "en"
    }

    func transcribe(
        fileAt url: URL, model: String, localeID: String,
        biasTerms: [String]) async throws -> String {
        #if canImport(WhisperKit)
        let pipe = try await pipeline(model: model)

        var options = DecodingOptions()
        options.language = Self.whisperLanguage(for: localeID)
        // Timestamps aren't needed for dictation — skipping them trims
        // decoding work. VAD chunking only pays off on long recordings.
        options.withoutTimestamps = true
        if let audioFile = try? AVAudioFile(forReading: url),
           audioFile.fileFormat.sampleRate > 0 {
            let seconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            options.chunkingStrategy = seconds > 25 ? .vad : nil
        } else {
            options.chunkingStrategy = .vad
        }

        // Vocabulary biasing: Whisper conditions on a decoder prompt, so
        // listing the user's terms makes it far likelier to spell them right.
        if !biasTerms.isEmpty, let tokenizer = pipe.tokenizer {
            let prompt = "Vocabulary: "
                + biasTerms.prefix(60).joined(separator: ", ") + "."
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.prefix(200))
            options.usePrefillPrompt = true
        }

        onStatus?("Transcribing (Whisper)…")
        defer { onStatus?(nil) }
        let results = try await pipe.transcribe(
            audioPath: url.path, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw NSError(domain: "Murmur", code: 41, userInfo: [
            NSLocalizedDescriptionKey: "This Murmur build does not include Whisper.",
        ])
        #endif
    }
}

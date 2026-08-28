import AVFAudio
import Foundation
import Speech

/// Wraps Apple's on-device SpeechAnalyzer/SpeechTranscriber (macOS 26+).
/// Fully local — the language model asset is downloaded once by macOS itself.
final class Transcriber {
    let locale: Locale

    /// Optional sink for interim streaming transcripts — invoked as partial
    /// results arrive during `transcribe(buffers:)` (used by the dictation
    /// HUD). Never called by the file-based path.
    var onPartialTranscript: ((String) -> Void)?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    /// Downloads the on-device speech model for the locale if missing.
    func ensureModelInstalled() async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if await SpeechTranscriber.installedLocales.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) {
            return
        }
        FileHandle.standardError.write(
            Data("Downloading on-device speech model for \(locale.identifier)…\n".utf8))
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// Transcribes an audio file and returns the raw text.
    /// `biasTerms` predisposes the on-device model toward the user's own
    /// vocabulary (names, jargon) via contextual strings.
    func transcribe(fileAt url: URL, biasTerms: [String] = []) async throws -> String {
        try await ensureModelInstalled()

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !biasTerms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: biasTerms]
            try await analyzer.setContext(context)
        }
        let audioFile = try AVAudioFile(forReading: url)

        async let transcript: AttributedString = transcriber.results
            .reduce(into: AttributedString("")) { partial, result in
                partial.append(result.text)
                partial.append(AttributedString(" "))
            }

        if let last = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return String((try await transcript).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // MARK: - Live streaming

    /// Transcribes microphone audio as it arrives, returning the final
    /// transcript once `buffers` finishes (which `AudioRecorder` does on
    /// `stop()` and `cancel()`). Behaviourally identical to
    /// `transcribe(fileAt:biasTerms:)` — same locale, same preset, same
    /// contextual-strings biasing — it just does the work while the user is
    /// still speaking instead of afterwards.
    ///
    /// `inputFormat` is the hardware tap format. `SpeechAnalyzer` publishes
    /// the formats its modules accept, so the buffers are converted to
    /// `bestAvailableAudioFormat` before being handed over; the hardware
    /// format is never assumed to be acceptable.
    func transcribe(
        buffers: AsyncStream<AVAudioPCMBuffer>,
        inputFormat: AVAudioFormat,
        biasTerms: [String] = []
    ) async throws -> String {
        try await ensureModelInstalled()

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !biasTerms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: biasTerms]
            try await analyzer.setContext(context)
        }

        guard let analysisFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: inputFormat) else {
            throw NSError(
                domain: "Murmur", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "No audio format compatible with the speech analyzer"])
        }
        let converter: AVAudioConverter?
        if analysisFormat == inputFormat {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: inputFormat, to: analysisFormat) else {
                throw NSError(
                    domain: "Murmur", code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Cannot convert microphone audio to the analyzer's format"])
            }
            converter = made
        }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(64))

        async let transcript: AttributedString = transcriber.results
            .reduce(into: AttributedString("")) { partial, result in
                partial.append(result.text)
                partial.append(AttributedString(" "))
                if let onPartial = self.onPartialTranscript {
                    let text = String(partial.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { onPartial(text) }
                }
            }

        do {
            try await analyzer.start(inputSequence: inputStream)
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            _ = try? await transcript
            throw error
        }

        // Pumping happens here rather than in the tap callback: resampling is
        // far too much work for the render thread.
        for await buffer in buffers {
            guard let converter else {
                inputContinuation.yield(AnalyzerInput(buffer: buffer))
                continue
            }
            if let converted = Self.convert(buffer, using: converter, to: analysisFormat) {
                inputContinuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        inputContinuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return String((try await transcript).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resamples/reformats one tap buffer. The converter is reused across the
    /// whole session so the resampler keeps its filter state between buffers.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

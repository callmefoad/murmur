import AVFoundation
import Foundation

/// Captures microphone audio into a temporary file while the hotkey is held.
///
/// Deliberately simple: the engine starts on key-down and stops on release.
/// Two "improvements" were tried and reverted after breaking things:
/// - setVoiceProcessingEnabled: its echo canceller ducks/mutes other apps'
///   audio system-wide and can feed the recognizer silence.
/// - A warm always-on engine with a pre-roll ring buffer: wedged the engine
///   so recording never started.
final class AudioRecorder {
    /// Rebuilt for every recording. On macOS an `AVAudioEngine`'s input node
    /// binds to whatever audio device was default when the node was first
    /// instantiated, and it does not follow later changes — so a long-lived
    /// engine keeps capturing from the built-in mic after you connect AirPods.
    /// Constructing one is cheap (microseconds) and we already start and stop
    /// per dictation, so a fresh engine each time is the reliable fix.
    private var engine = AVAudioEngine()
    /// Observes `AVAudioEngineConfigurationChange`, non-nil only while
    /// recording. Fires when the input device disappears mid-dictation
    /// (AirPods going out of range, a dock unplugged).
    private var configurationObserver: NSObjectProtocol?
    private var file: AVAudioFile?
    /// Guards `file` and `streamContinuation`, both written on the caller's
    /// thread in `start()`/`stop()` but read (and, for the continuation,
    /// yielded into) on the AVAudioEngine render thread inside the tap
    /// closure. `removeTap(onBus:)` does not wait for an in-flight callback, so
    /// without this lock the render thread can race a `stop()` that nils `file`.
    /// Locking on the render thread is acceptable here: `AVAudioFile.write(from:)`
    /// already performs file I/O and allocation on that thread, so an uncontended
    /// lock introduces no new class of problem.
    private let fileLock = NSLock()
    /// Live buffer sink, non-nil only while a streaming recording is in flight.
    private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private(set) var currentFileURL: URL?
    private(set) var isRecording = false

    /// Called with each tap buffer's RMS level (~every 85 ms at the standard
    /// 4096-frame/48 kHz tap), hopped to the main queue. Set once at launch,
    /// before any tap exists, so no synchronisation is needed. Used by the
    /// dictation HUD's input meter.
    var onLevel: ((Float) -> Void)?

    /// How many tap buffers may queue up for a slow consumer before the
    /// oldest are dropped. At the usual 4096-frame/48 kHz tap that is a
    /// little over five seconds of audio — enough to cover analyzer startup
    /// without letting a stalled consumer grow the queue without bound.
    private static let streamBufferCount = 64

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start() throws {
        try start(publishingBuffers: false)
    }

    /// Starts recording exactly as `start()` does — the temp `.caf` is still
    /// written, so a failed live transcription can fall back to the file —
    /// and additionally publishes every tap buffer to the returned stream.
    ///
    /// The stream is bounded (`bufferingNewest`), so a consumer that stalls
    /// drops the oldest audio rather than growing without limit, and it is
    /// finished by both `stop()` and `cancel()` so the consuming task can
    /// never hang waiting for more input.
    ///
    /// `format` is the hardware input format the buffers are in — the caller
    /// is responsible for any conversion its consumer needs.
    func startStreaming() throws -> (stream: AsyncStream<AVAudioPCMBuffer>, format: AVAudioFormat) {
        // Renew before reading the format: the old engine's format belongs to
        // the old device, and handing a stale sample rate to the analyzer makes
        // every transcription come back empty.
        renewEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.streamBufferCount))
        fileLock.withLock {
            streamContinuation = continuation
        }
        do {
            try start(publishingBuffers: true)
        } catch {
            fileLock.withLock {
                streamContinuation = nil
            }
            continuation.finish()
            throw error
        }
        return (stream, format)
    }

    private func start(publishingBuffers: Bool) throws {
        guard !isRecording else { return }

        if !publishingBuffers { renewEngine() }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Murmur", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input available. Check System Settings \u{203A} Sound \u{203A} Input."])
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-\(UUID().uuidString).caf")
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // A tap buffer is only valid for the duration of this callback,
            // so anything handed to another thread must be copied first. The
            // copy is one fixed-size allocation per callback (~85 ms of audio)
            // and only happens in streaming mode; everything heavier —
            // format conversion, recognition — happens on the consumer side.
            let copy = publishingBuffers ? Self.copy(buffer) : nil
            self.fileLock.withLock {
                try? self.file?.write(from: buffer)
                if let copy {
                    self.streamContinuation?.yield(copy)
                }
            }
            if let onLevel = self.onLevel {
                let level = Self.rms(of: buffer)
                DispatchQueue.main.async { onLevel(level) }
            }
        }

        fileLock.withLock {
            file = audioFile
        }
        currentFileURL = url
        engine.prepare()
        try engine.start()
        isRecording = true
        observeConfigurationChanges()
    }

    /// Discards the current engine and its device binding.
    /// Only safe when no recording is in flight.
    private func renewEngine() {
        guard !isRecording else { return }
        engine = AVAudioEngine()
    }

    /// The engine posts this when its input device is replaced or removed.
    /// Mid-recording that means the audio we would keep capturing is either
    /// silence or from the wrong device, so end the recording and let the
    /// caller transcribe whatever was captured before the change.
    private func observeConfigurationChanges() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                guard let self, self.isRecording else { return }
                self.onInputDeviceLost?()
            }
    }

    /// Called on the main queue when the input device changes while recording.
    /// Set once at launch, before any recording exists.
    var onInputDeviceLost: (() -> Void)?

    /// Stops recording and returns the captured audio file URL,
    /// or nil if nothing was recorded.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        let continuation = fileLock.withLock { () -> AsyncStream<AVAudioPCMBuffer>.Continuation? in
            file = nil
            let continuation = streamContinuation
            streamContinuation = nil
            return continuation
        }
        continuation?.finish()
        let url = currentFileURL
        currentFileURL = nil
        return url
    }

    /// Stops and deletes the in-progress recording.
    func cancel() {
        if let url = stop() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Root-mean-square amplitude of one buffer across all channels.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = data[channel]
            for index in 0..<frames {
                let sample = samples[index]
                sum += sample * sample
            }
        }
        let count = Float(frames * Int(buffer.format.channelCount))
        return sqrt(sum / count)
    }

    /// Duplicates a tap buffer so it can safely outlive the render callback.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
            let source = buffer.floatChannelData,
            let destination = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: frames)
        }
        return copy
    }

    /// Removes recordings left behind by a crash or force-quit.
    /// Safe to call only at launch, before any recording can be in flight.
    static func sweepStaleRecordings() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: manager.temporaryDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files
        where file.lastPathComponent.hasPrefix("murmur-") && file.pathExtension == "caf" {
            try? manager.removeItem(at: file)
        }
    }
}

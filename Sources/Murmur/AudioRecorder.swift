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
    private let engine = AVAudioEngine()
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

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Murmur", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
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
        }

        fileLock.withLock {
            file = audioFile
        }
        currentFileURL = url
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops recording and returns the captured audio file URL,
    /// or nil if nothing was recorded.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
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

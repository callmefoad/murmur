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
    /// Guards `file`, which is written on the caller's thread in `start()`/`stop()`
    /// but read and written on the AVAudioEngine render thread inside the tap
    /// closure. `removeTap(onBus:)` does not wait for an in-flight callback, so
    /// without this lock the render thread can race a `stop()` that nils `file`.
    /// Locking on the render thread is acceptable here: `AVAudioFile.write(from:)`
    /// already performs file I/O and allocation on that thread, so an uncontended
    /// lock introduces no new class of problem.
    private let fileLock = NSLock()
    private(set) var currentFileURL: URL?
    private(set) var isRecording = false

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
            self.fileLock.withLock {
                try? self.file?.write(from: buffer)
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
        fileLock.withLock {
            file = nil
        }
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

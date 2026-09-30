import AVFoundation
import AppKit
import Foundation

@main
struct MurmurMain {
    @MainActor
    static func main() async {
        Settings.migrateLegacyDefaults()
        var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
        var mode: Mode = .app
        var localeIdentifier = "en-US"
        var engineName = "apple"
        var whisperModel = Settings.whisperModel

        while let argument = arguments.next() {
            switch argument {
            case "--transcribe":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .transcribe(path)
            case "--engine":
                engineName = arguments.next() ?? engineName
            case "--whisper-model":
                whisperModel = arguments.next() ?? whisperModel
            case "--format":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .format(text)
            case "--transform":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .transform(text)
            case "--polish":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .polish(text)
            case "--needs-polish":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .needsPolish(text)
            case "--punctuate":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .punctuate(text)
            case "--selftest":
                mode = .selftest
            case "--locale":
                localeIdentifier = arguments.next() ?? localeIdentifier
            case "--help", "-h":
                usageAndExit()
            default:
                usageAndExit()
            }
        }

        switch mode {
        case .selftest:
            let formatterPassed = TextFormatter.runSelfTest()
            let learnedPassed = LearnedStore.runSelfTest()
            exit(formatterPassed && learnedPassed ? 0 : 1)

        case .needsPolish(let text):
            // Debug aid for tuning the post-release latency gate: prints
            // whether this text would pay for a model polish pass.
            print(RewriteEngine.needsPolish(text) ? "MODEL" : "SKIP")
            exit(0)

        case .punctuate(let text):
            // Debug aid: the grammar punctuation pass on its own, with timing.
            guard Punctuator.shared.warmUp() else {
                FileHandle.standardError.write(Data("Punctuation model not installed\n".utf8))
                exit(1)
            }
            let started = Date()
            let result = Punctuator.shared.punctuate(TextFormatter().format(text))
            print(result)
            FileHandle.standardError.write(Data(String(
                format: "%.0f ms\n", Date().timeIntervalSince(started) * 1000).utf8))
            exit(0)

        case .format(let text):
            // Same pipeline as live dictation: format, apply learned
            // corrections, then expand snippets.
            print(SnippetStore.expand(
                in: LearnedStore.apply(in: TextFormatter().format(text))))
            exit(0)

        case .transform(let text):
            let engine = RewriteEngine()
            if let note = engine.availabilityNote {
                FileHandle.standardError.write(Data("Unavailable: \(note)\n".utf8))
                exit(1)
            }
            do {
                let polished = try await engine.rewrite(
                    text, instructions: Transform.all[0].instructions)
                print(polished)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
                exit(1)
            }

        case .polish(let text):
            let engine = RewriteEngine()
            if let note = engine.availabilityNote {
                FileHandle.standardError.write(Data("Unavailable: \(note)\n".utf8))
                exit(1)
            }
            do {
                let polished = try await engine.rewrite(
                    text, instructions: RewriteEngine.polishPrompt(level: .tightened))
                print(polished)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
                exit(1)
            }
        case .transcribe(let path):
            do {
                let raw: String
                if engineName == "parakeet" {
                    let parakeet = ParakeetEngine()
                    parakeet.onStatus = { status in
                        if let status {
                            FileHandle.standardError.write(Data("\(status)\n".utf8))
                        }
                    }
                    let started = Date()
                    raw = try await parakeet.transcribe(fileAt: URL(fileURLWithPath: path))
                    FileHandle.standardError.write(Data(String(
                        format: "parakeet %.0f ms (includes load)\n",
                        Date().timeIntervalSince(started) * 1000).utf8))
                } else if engineName == "parakeet-live" {
                    // Plays the file into the live path at real-time pace,
                    // as if spoken, and times release-to-text.
                    let parakeet = ParakeetEngine()
                    parakeet.preload()
                    var live = parakeet.liveTranscriber()
                    while live == nil {
                        try await Task.sleep(for: .milliseconds(200))
                        live = parakeet.liveTranscriber()
                    }
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                    let format = file.processingFormat
                    let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
                    let task = Task { try await live!.transcribe(buffers: stream, inputFormat: format) }
                    while file.framePosition < file.length {
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)
                        else { break }
                        try file.read(into: buffer, frameCount: 4096)
                        continuation.yield(buffer)
                        try await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate))
                    }
                    let released = Date()
                    continuation.finish()
                    let result = try await task.value
                    raw = result.text
                    FileHandle.standardError.write(Data(String(
                        format: "parakeet-live release-to-text %.0f ms, %d segments, %lld/%lld frames\n",
                        Date().timeIntervalSince(released) * 1000, result.segments,
                        result.inputFrames, file.length).utf8))
                } else if engineName == "whisper" {
                    let whisper = WhisperEngine()
                    whisper.onStatus = { status in
                        if let status {
                            FileHandle.standardError.write(Data("\(status)\n".utf8))
                        }
                    }
                    raw = try await whisper.transcribe(
                        fileAt: URL(fileURLWithPath: path),
                        model: whisperModel,
                        localeID: localeIdentifier,
                        biasTerms: await LearnedStore.biasTerms())
                } else {
                    let transcriber = Transcriber(
                        locale: Locale(identifier: localeIdentifier))
                    raw = try await transcriber.transcribe(
                        fileAt: URL(fileURLWithPath: path),
                        biasTerms: await LearnedStore.biasTerms())
                }
                // Full live-dictation pipeline: format → learned corrections
                // → snippet expansion.
                let formatted = SnippetStore.expand(
                    in: LearnedStore.apply(in: TextFormatter().format(raw)))
                print("RAW: \(raw)")
                print("FORMATTED: \(formatted)")
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("Transcription failed: \(error)\n".utf8))
                exit(1)
            }

        case .app:
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }

    private enum Mode {
        case app
        case transcribe(String)
        case format(String)
        case transform(String)
        case polish(String)
        case needsPolish(String)
        case punctuate(String)
        case selftest
    }

    private static func usageAndExit() -> Never {
        print("""
        Murmur — local dictation (hold fn to talk, release to paste)

        Usage:
          Murmur                      run as menu bar app
          Murmur --transcribe <file>  transcribe an audio file
                                      [--locale en-US] [--engine apple|parakeet|parakeet-live|whisper]
                                      [--whisper-model base|small|large-v3-v20240930_turbo]
          Murmur --format "<text>"    run the text formatter on a string
          Murmur --polish "<text>"    run the tap-then-hold model cleanup
          Murmur --needs-polish "<t>" would this text pay for a model pass?
          Murmur --punctuate "<t>"   format, then punctuate by grammar
          Murmur --selftest           run formatter self-tests
        """)
        exit(0)
    }
}

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
                if engineName == "whisper" {
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
        case selftest
    }

    private static func usageAndExit() -> Never {
        print("""
        Murmur — local dictation (hold fn to talk, release to paste)

        Usage:
          Murmur                      run as menu bar app
          Murmur --transcribe <file>  transcribe an audio file
                                      [--locale en-US] [--engine apple|whisper]
                                      [--whisper-model base|small|large-v3-v20240930_turbo]
          Murmur --format "<text>"    run the text formatter on a string
          Murmur --polish "<text>"    run the tap-then-hold model cleanup
          Murmur --needs-polish "<t>" would this text pay for a model pass?
          Murmur --selftest           run formatter self-tests
        """)
        exit(0)
    }
}

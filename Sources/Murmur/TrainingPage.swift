import AppKit
import Speech
import SwiftUI
import UniformTypeIdentifiers

/// Records a short sample, shows what the model heard, and saves the
/// misheard → intended mapping so Murmur learns the user's pronunciation.
@MainActor
final class TrainingModel: ObservableObject {
    @Published var isRecording = false
    @Published var isProcessing = false
    @Published var heard: String?
    @Published var result: String?

    private let recorder = AudioRecorder()

    func toggle(app: AppDelegate, target: String) {
        if isRecording {
            stop(app: app, target: target)
        } else {
            start()
        }
    }

    private func start() {
        heard = nil
        result = nil
        do {
            try recorder.start()
            isRecording = true
            NSSound(named: "Pop")?.play()
        } catch {
            result = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stop(app: AppDelegate, target: String) {
        isRecording = false
        guard let url = recorder.stop() else { return }
        NSSound(named: "Tink")?.play()
        isProcessing = true
        Task {
            defer {
                isProcessing = false
                try? FileManager.default.removeItem(at: url)
            }
            do {
                let raw = try await app.transcribeRaw(fileAt: url)
                let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?"))
                heard = cleaned.isEmpty ? nil : cleaned
                let intended = target.trimmingCharacters(in: .whitespaces)
                guard let heardText = heard else {
                    result = "Nothing was heard — try again, a bit louder."
                    return
                }
                if heardText.lowercased() == intended.lowercased() {
                    LearnedStore.addTerm(intended)
                    result = "Recognized correctly! Added “\(intended)” to your " +
                             "vocabulary so it stays reliable."
                } else {
                    LearnedStore.add(heard: heardText, intended: intended)
                    result = "Learned: “\(heardText)” → “\(intended)”. Murmur will " +
                             "make this correction automatically from now on."
                }
            } catch {
                result = "Transcription failed: \(error.localizedDescription)"
            }
        }
    }
}

struct TrainingPage: View {
    @ObservedObject var app: AppDelegate
    @StateObject private var model = TrainingModel()
    @State private var target = ""
    @State private var learned = LearnedData()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Voice Training")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Teach Murmur how you pronounce names and jargon. Type a word, " +
                 "say it, and Murmur learns what it hears from you — the mapping " +
                 "is applied to every future dictation, and the word is fed to " +
                 "the speech model as expected vocabulary.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text("Teach a word or phrase").font(.headline)
                HStack(spacing: 10) {
                    TextField("word or phrase, e.g. “Søren” or “Baseten”",
                              text: $target)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.toggle(app: app, target: target)
                    } label: {
                        Label(model.isRecording ? "Stop" : "Record",
                              systemImage: model.isRecording
                                ? "stop.circle.fill" : "mic.circle.fill")
                            .foregroundStyle(model.isRecording ? .red : Palette.accent)
                    }
                    .disabled(model.isProcessing || !app.micAuthorized
                              || (!model.isRecording
                                  && target.trimmingCharacters(in: .whitespaces).isEmpty))
                    if model.isProcessing {
                        ProgressView().controlSize(.small)
                    }
                }
                if model.isRecording {
                    Label("Say “\(target)” now, then press Stop.",
                          systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let result = model.result {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(Palette.accent)
                        .onAppear { learned = LearnedStore.load() }
                }
                Text("Tip: repeat a word 2–3 times — different mishearings each " +
                     "become their own correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                Text("Learned corrections").font(.headline)
                Text("Also learned automatically when you fix a transcript in " +
                     "History (pencil icon).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if learned.corrections.isEmpty {
                    Text("Nothing learned yet.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(learned.corrections.reversed()) { correction in
                        HStack {
                            Text("“\(correction.heard)”")
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Text("“\(correction.intended)”")
                                .fontWeight(.medium)
                            if correction.timesSeen > 1 {
                                Text("×\(correction.timesSeen)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                var data = LearnedStore.load()
                                data.corrections.removeAll { $0.id == correction.id }
                                LearnedStore.save(data)
                                learned = data
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.system(size: 13))
                        Divider()
                    }
                }
                if !learned.terms.isEmpty {
                    Text("Vocabulary hints: " + learned.terms.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .card()
        }
        .onAppear { learned = LearnedStore.load() }
    }
}

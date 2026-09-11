import Combine
import Foundation
import os

/// One user-authored "My Voice" instruction: freeform rewriting directions
/// ("no filler words", "always British spelling") applied to every matching
/// dictation before insertion. Unlike a Style, the wording is entirely the
/// user's — the engine wraps it in strict anti-hallucination framing.
struct VoiceInstruction: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var instructions: String
    var isEnabled: Bool = true
    /// Bundle identifiers this instruction applies to. Empty means all apps.
    var appBundleIDs: [String] = []
    var createdAt: Date = Date()

    private enum CodingKeys: String, CodingKey {
        case id, name, instructions, isEnabled, appBundleIDs, createdAt
    }

    init(
        id: UUID = UUID(), name: String, instructions: String,
        isEnabled: Bool = true, appBundleIDs: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.isEnabled = isEnabled
        self.appBundleIDs = appBundleIDs
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        instructions = try container.decode(String.self, forKey: .instructions)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        appBundleIDs = try container.decodeIfPresent(
            [String].self, forKey: .appBundleIDs) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Store of My Voice instructions, persisted as JSON in the support
/// directory. Mutations save through immediately, mirroring `SnippetStore`,
/// so a crash never loses more than the edit in flight.
@MainActor
final class VoiceInstructionStore: ObservableObject {
    private nonisolated static let logger = Logger(
        subsystem: "local.murmur", category: "voice-instructions")

    nonisolated static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("voice-instructions.json")
    }

    @Published private(set) var instructions: [VoiceInstruction]

    init() {
        instructions = Self.load()
    }

    func add(_ instruction: VoiceInstruction) {
        instructions.append(instruction)
        save()
    }

    /// Replaces the stored entry with a matching id; unknown ids are ignored.
    func update(_ instruction: VoiceInstruction) {
        guard let index = instructions.firstIndex(where: { $0.id == instruction.id })
        else { return }
        instructions[index] = instruction
        save()
    }

    func remove(at index: Int) {
        guard instructions.indices.contains(index) else { return }
        instructions.remove(at: index)
        save()
    }

    func remove(id: UUID) {
        guard let index = instructions.firstIndex(where: { $0.id == id }) else { return }
        instructions.remove(at: index)
        save()
    }

    func clear() {
        instructions = []
        save()
    }

    /// First enabled instruction that applies to the given app, or nil.
    /// An empty `appBundleIDs` list matches every app (and a nil bundle id,
    /// when the frontmost app can't be identified); otherwise the bundle id
    /// must be listed explicitly.
    func preset(for bundleID: String?) -> VoiceInstruction? {
        instructions.first { instruction in
            instruction.isEnabled && instruction.applies(to: bundleID)
        }
    }

    private func save() {
        Self.save(instructions)
    }

    nonisolated static func load() -> [VoiceInstruction] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(
                LossyArray<VoiceInstruction>.self, from: data).elements
        } catch {
            logger.error(
                """
                Failed to load \(fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            return []
        }
    }

    nonisolated static func save(_ instructions: [VoiceInstruction]) {
        do {
            let data = try JSONEncoder().encode(instructions)
            try data.write(to: fileURL, options: .atomic)
            AppPaths.secure(fileURL)
        } catch {
            logger.error(
                """
                Failed to save \(fileURL.path, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
        }
    }
}

extension VoiceInstruction {
    /// Whether this instruction applies to dictation that targeted the given
    /// app. Unbound instructions apply everywhere; bound ones require an
    /// exact match, so an unidentifiable target app only ever receives
    /// unbound instructions.
    func applies(to bundleID: String?) -> Bool {
        guard !appBundleIDs.isEmpty else { return true }
        guard let bundleID else { return false }
        return appBundleIDs.contains(bundleID)
    }
}

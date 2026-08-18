import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Murmur", isDirectory: true)

        // One-time migration from the app's pre-rename data folder, so
        // history, dictionary, snippets and scratchpad survive.
        let legacy = base.appendingPathComponent("WhisperFlow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: directory)
        }

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Restricts a support-directory item to the current user.
    /// Directories get 0700 — without the execute bit they cannot be
    /// traversed, which would strand anything stored inside them
    /// (notably the downloaded Whisper models).
    static func secure(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory)
        guard exists else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: isDirectory.boolValue ? 0o700 : 0o600],
            ofItemAtPath: url.path)
    }

    /// Tightens the support directory and everything already inside it.
    /// Runs at launch so files created before this existed are fixed too.
    static func secureExistingFiles() {
        let manager = FileManager.default
        try? manager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
        guard let items = try? manager.contentsOfDirectory(
            at: supportDirectory, includingPropertiesForKeys: nil) else { return }
        for item in items { secure(item) }
    }
}

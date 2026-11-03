import Foundation
import os

/// Writes Codable snapshots off the main thread, in submission order.
final class JSONFileWriter {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func write<Value: Encodable>(_ value: Value, to url: URL, logger: Logger) {
        queue.async {
            do {
                let data = try JSONEncoder().encode(value)
                try data.write(to: url, options: .atomic)
                AppPaths.secure(url)
            } catch {
                logger.error(
                    """
                    Failed to save \(url.path, privacy: .public): \\
                    \(String(describing: error), privacy: .public)
                    """)
            }
        }
    }

    func flush() {
        queue.sync(flags: .barrier) {}
    }
}

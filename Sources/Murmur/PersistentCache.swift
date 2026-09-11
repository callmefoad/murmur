import Foundation

/// Small, thread-safe cache for the JSON files read on every dictation.
/// A cheap file signature check keeps direct edits and test fixtures visible.
final class PersistentCache<Value: Codable>: @unchecked Sendable {
    private struct Signature: Equatable {
        let modified: Date?
        let size: UInt64?
    }

    private let lock = NSLock()
    private var cached: (signature: Signature, value: Value)?

    func load(from url: URL) throws -> Value {
        let signature = Self.signature(for: url)
        lock.lock()
        if let cached, cached.signature == signature {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let value = try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        lock.lock()
        cached = (signature, value)
        lock.unlock()
        return value
    }

    func store(_ value: Value, for url: URL) {
        let signature = Self.signature(for: url)
        lock.lock()
        cached = (signature, value)
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    private static func signature(for url: URL) -> Signature {
        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey, .fileSizeKey,
        ])
        return Signature(
            modified: values?.contentModificationDate,
            size: values?.fileSize.map(UInt64.init))
    }
}

/// Decodes the valid members of a JSON array while skipping damaged entries.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                // `decode` leaves the cursor on a malformed value. A super
                // decoder consumes that one value regardless of its shape.
                _ = try? container.superDecoder()
            }
        }
        self.elements = elements
    }
}

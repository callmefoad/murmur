import Foundation
import os

/// Lightweight release-build timing for the path users actually feel:
/// key release through insertion. Values stay in Unified Logging and never
/// include dictated text.
struct PipelineTelemetry {
    private static let logger = Logger(
        subsystem: "local.murmur", category: "pipeline")

    private let started = ContinuousClock.now
    private var checkpoint = ContinuousClock.now
    private var stages: [(String, Double)] = []

    mutating func finish(_ stage: String) {
        let now = ContinuousClock.now
        stages.append((stage, Self.milliseconds(from: checkpoint, to: now)))
        checkpoint = now
    }

    func commit(wordCount: Int, usedModel: Bool, inserted: Bool) {
        let total = Self.milliseconds(from: started, to: ContinuousClock.now)
        let detail = stages.map { "\($0.0)=\(Int($0.1.rounded()))ms" }
            .joined(separator: " ")
        Self.logger.info(
            "release-to-end=\(Int(total.rounded()))ms words=\(wordCount) model=\(usedModel) inserted=\(inserted) \(detail, privacy: .public)")
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant, to end: ContinuousClock.Instant
    ) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

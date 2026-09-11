import XCTest
@testable import Murmur

final class HotkeyMonitorTests: XCTestCase {
    func testTapThenSecondHoldStartsPolishedOnSecondPress() {
        let monitor = HotkeyMonitor()
        var events: [String] = []
        monitor.onStart = { events.append("start") }
        monitor.onStop = { events.append("stop") }
        monitor.onCancel = { events.append("cancel") }
        monitor.onPolishedRequested = { events.append("polished") }
        monitor.onUndoAttempt = { false }

        let start = Date(timeIntervalSince1970: 100)
        monitor.apply(pressed: true, now: start)
        monitor.apply(pressed: false, now: start.addingTimeInterval(0.1))
        monitor.apply(pressed: true, now: start.addingTimeInterval(0.2))

        XCTAssertEqual(events, ["start", "cancel", "polished", "start"])

        monitor.apply(pressed: false, now: start.addingTimeInterval(0.8))
        XCTAssertEqual(events.last, "stop")
        XCTAssertEqual(events.filter { $0 == "polished" }.count, 1)
    }

    func testTwoQuickTapsRearmPolishedForNextHold() {
        let monitor = HotkeyMonitor()
        var events: [String] = []
        monitor.onStart = { events.append("start") }
        monitor.onCancel = { events.append("cancel") }
        monitor.onPolishedRequested = { events.append("polished") }
        monitor.onUndoAttempt = { false }

        let start = Date(timeIntervalSince1970: 200)
        monitor.apply(pressed: true, now: start)
        monitor.apply(pressed: false, now: start.addingTimeInterval(0.1))
        monitor.apply(pressed: true, now: start.addingTimeInterval(0.2))
        monitor.apply(pressed: false, now: start.addingTimeInterval(0.3))

        XCTAssertEqual(
            events,
            ["start", "cancel", "polished", "start", "cancel", "polished"])
    }

    func testOrdinaryHoldRemainsFast() {
        let monitor = HotkeyMonitor()
        var polishedCount = 0
        var stopped = false
        monitor.onPolishedRequested = { polishedCount += 1 }
        monitor.onStop = { stopped = true }
        monitor.onUndoAttempt = { false }

        let start = Date(timeIntervalSince1970: 300)
        monitor.apply(pressed: true, now: start)
        monitor.apply(pressed: false, now: start.addingTimeInterval(0.5))

        XCTAssertTrue(stopped)
        XCTAssertEqual(polishedCount, 0)
    }
}

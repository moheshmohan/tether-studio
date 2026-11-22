import XCTest
@testable import TetherStudio

final class StopAlertTests: XCTestCase {
    private func snap(left: Int? = 7200, battery: Int? = 80, hot: Bool = false) -> CameraSnapshot {
        var s = CameraSnapshot()
        s.remainingSeconds = left
        s.batteryPercent = battery
        s.overheating = hot
        return s
    }

    func testTheCauseIsReadFromWhatTheCameraReportedWithTheStop() {
        XCTAssertEqual(StopAlert.cause(state: "0", snapshot: snap(left: 0)), .cardFull)
        XCTAssertEqual(StopAlert.cause(state: "0", snapshot: snap(left: 12)), .cardFull)
        XCTAssertEqual(StopAlert.cause(state: "0", snapshot: snap(hot: true)), .hot)
        XCTAssertEqual(StopAlert.cause(state: "0", snapshot: snap(battery: 3)), .battery)
        XCTAssertEqual(StopAlert.cause(state: "0", snapshot: snap()), .onCamera)
        XCTAssertEqual(StopAlert.cause(state: "0", snapshot: snap(left: nil, battery: nil)), .onCamera)
    }

    func testAFailedRecordingIsSaidFirst() {
        // State 2 is the camera's own word; the readings are only guesses beside it.
        XCTAssertEqual(StopAlert.cause(state: "2", snapshot: snap(left: 0, battery: 2, hot: true)), .failed)
    }

    func testAFullCardWinsOverHeatAndBattery() {
        XCTAssertEqual(StopAlert.cause(state: "0", snapshot: snap(left: 5, battery: 3, hot: true)), .cardFull)
        XCTAssertEqual(StopAlert.cause(state: "0", snapshot: snap(battery: 3, hot: true)), .hot)
    }

    func testOnlyTheCamerasOwnButtonAndAKeptTakeAreQuiet() {
        let quiet: [StopAlert.Kind] = [.onCamera, .kept]
        let loud: [StopAlert.Kind] = [.cardFull, .hot, .failed, .battery, .linkLost, .endedWhileAway]
        for kind in quiet { XCTAssertFalse(StopAlert(kind: kind, at: Date(), length: nil).serious, "\(kind)") }
        for kind in loud { XCTAssertTrue(StopAlert(kind: kind, at: Date(), length: nil).serious, "\(kind)") }
    }

    func testALostLinkOnALowBatterySaysTheCameraHasProbablySwitchedOff() {
        let low = StopAlert(kind: .linkLost, at: Date(), length: 60, lastBattery: 8)
        XCTAssertTrue(low.detail.contains("8 %"))
        XCTAssertTrue(low.detail.contains("switched off"))
        let fine = StopAlert(kind: .linkLost, at: Date(), length: 60, lastBattery: 70)
        XCTAssertFalse(fine.detail.contains("switched off"))
        XCTAssertTrue(fine.detail.contains("may still be recording"))
    }

    func testTheLengthOfTheTakeIsWrittenOut() {
        XCTAssertEqual(StopAlert.duration(42), "42 s")
        XCTAssertEqual(StopAlert.duration(754), "12 min 34 s")
        XCTAssertEqual(StopAlert.duration(3 * 3600 + 5 * 60 + 9), "3 h 05 min")
        let alert = StopAlert(kind: .onCamera, at: Date(), length: 65)
        XCTAssertTrue(alert.when.hasSuffix(", after 1 min 05 s"), alert.when)
        XCTAssertFalse(StopAlert(kind: .endedWhileAway, at: Date(), length: nil).when.contains("after"))
    }

    func testEveryKindHasItsOwnWords() {
        let kinds: [StopAlert.Kind] = [.cardFull, .hot, .failed, .battery, .onCamera, .linkLost, .kept, .endedWhileAway]
        let titles = Set(kinds.map { StopAlert(kind: $0, at: Date(), length: nil).title })
        XCTAssertEqual(titles.count, kinds.count)
        for kind in kinds { XCTAssertFalse(StopAlert(kind: kind, at: Date(), length: nil).detail.isEmpty) }
    }
}

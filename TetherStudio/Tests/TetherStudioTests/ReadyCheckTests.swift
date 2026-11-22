import XCTest
@testable import TetherStudio

final class ReadyCheckTests: XCTestCase {
    private func choice(_ leaf: String, _ current: String) -> CameraConfig {
        CameraConfig(path: CameraService.path(forLeaf: leaf), label: leaf, type: "RADIO", readOnly: false, current: current,
                     options: [ConfigOption(index: 0, value: current)], bottom: nil, top: nil, step: nil)
    }

    private func camera(mode: String = "Movie (P)", quality: String = "33", focus: String = "AF-C") -> [String: CameraConfig] {
        ["expprogram": choice("expprogram", mode), "d241": choice("d241", "8"), "d242": choice("d242", quality),
         "focusmode": choice("focusmode", focus)]
    }

    private func snapshot(card: Int? = 8000, battery: Int? = 100, hot: Bool = false) -> CameraSnapshot {
        var s = CameraSnapshot()
        s.remainingSeconds = card
        s.batteryPercent = battery
        s.overheating = hot
        return s
    }

    private func issues(_ snapshot: CameraSnapshot, _ configs: [String: CameraConfig], autoCopy: Bool = true,
                        macFree: Int64? = 200_000_000_000) -> [ReadyIssue] {
        ReadyCheck.issues(snapshot: snapshot, configs: configs, preferredMovieMode: "Movie (P)", autoCopy: autoCopy, macFree: macFree)
    }

    func testNothingToSayWhenAllIsWell() {
        XCTAssertEqual(issues(snapshot(), camera()), [])
        // What the camera does not report is not guessed at.
        XCTAssertEqual(issues(snapshot(card: nil, battery: nil), [:], macFree: nil), [])
    }

    func testInAPhotoModeTheCardIsCountedInPhotos() {
        // 21 Nov 2026: in P the camera reports 0 movie seconds and 6907 photos; that is not a full card.
        var s = snapshot(card: 0)
        s.photoMode = true
        s.photosLeft = 6907
        let photo = camera(mode: "P")
        XCTAssertEqual(issues(s, photo), [ReadyIssue(level: .note, text: "Photo mode (P): Record switches the camera to Movie (P)")])
        XCTAssertEqual(s.remainingLabel, "6907 photos left")
        s.photosLeft = 40
        XCTAssertEqual(issues(s, photo).first, ReadyIssue(level: .warning, text: "Room for only 40 photos on the card"))
        s.photosLeft = 0
        XCTAssertEqual(issues(s, photo).first?.level, .stop)
        XCTAssertTrue(CameraService.isPhotoMode("P"))
        XCTAssertTrue(CameraService.isPhotoMode("Intelligent Auto"))
        XCTAssertFalse(CameraService.isPhotoMode("Movie (Scene)"))
        XCTAssertFalse(CameraService.isPhotoMode("Movie S&Q Motion (P)"))
        XCTAssertFalse(CameraService.isPhotoMode(nil))
    }

    func testTheCardRunningOut() {
        XCTAssertEqual(issues(snapshot(card: 299), camera()), [ReadyIssue(level: .warning, text: "Only 4 min left on the card")])
        XCTAssertEqual(issues(snapshot(card: 300), camera()), [])
        XCTAssertEqual(issues(snapshot(card: 59), camera()).first?.level, .stop)
        XCTAssertEqual(issues(snapshot(card: 0), camera()),
                       [ReadyIssue(level: .stop, text: "No recording time left on the card (full, or no card in the camera)")])
    }

    func testBatteryAndHeat() {
        XCTAssertEqual(issues(snapshot(battery: 31), camera()), [])
        XCTAssertEqual(issues(snapshot(battery: 30), camera()), [ReadyIssue(level: .warning, text: "Camera battery at 30 %")])
        XCTAssertEqual(issues(snapshot(battery: 15), camera()), [ReadyIssue(level: .stop, text: "Camera battery at 15 %")])
        XCTAssertEqual(issues(snapshot(hot: true), camera()).first?.level, .stop)
    }

    func testTheModeIsSaidWhenItMatters() {
        XCTAssertEqual(issues(snapshot(), camera(mode: "Movie (Scene)")), [])
        XCTAssertEqual(issues(snapshot(), camera(mode: "Movie S&Q Motion (P)")),
                       [ReadyIssue(level: .note, text: "S&Q mode: Record switches the camera to Movie (P)")])
        XCTAssertEqual(issues(snapshot(), camera(mode: "Intelligent Auto")),
                       [ReadyIssue(level: .note, text: "Photo mode (Intelligent Auto): Record switches the camera to Movie (P)")])
        XCTAssertEqual(issues(snapshot(), camera(focus: "Manual")), [ReadyIssue(level: .note, text: "Manual focus")])
    }

    func testRoomOnTheMacCountsOnlyWhenClipsAreCopiedByThemselves() {
        // 4K 100M is 750 MB a minute; ten minutes plus the 500 MB always kept free is 8 GB.
        XCTAssertEqual(issues(snapshot(), camera(), macFree: 8_000_000_000), [])
        let tight = issues(snapshot(), camera(), macFree: 3_500_000_000)
        XCTAssertEqual(tight.first?.level, .warning)
        XCTAssertTrue(tight.first?.text.contains("about 4 min of clips") == true, tight.first?.text ?? "")
        XCTAssertTrue(issues(snapshot(), camera(), macFree: 400_000_000).first?.text.hasPrefix("No room on this Mac") == true)
        XCTAssertEqual(issues(snapshot(), camera(), autoCopy: false, macFree: 400_000_000), [])
        // The same disk is plenty at 16 Mbit/s (120 MB a minute).
        XCTAssertEqual(issues(snapshot(), camera(quality: "27"), macFree: 3_500_000_000), [])
    }

    func testTheWorstComesFirst() {
        let all = issues(snapshot(card: 200, battery: 10, hot: false), camera(focus: "Manual"))
        XCTAssertEqual(all.map(\.level), [.stop, .warning, .note])
    }

    func testTheLineForWhenNothingIsWrong() {
        XCTAssertEqual(ReadyCheck.summary(snapshot: snapshot(card: 8007), configs: camera(mode: "Movie (Scene)")),
                       "Movie Scene · 4K 25p 100M · 2 h 13 min on the card · battery 100 %")
        XCTAssertEqual(ReadyCheck.summary(snapshot: CameraSnapshot(), configs: [:]), "")
    }
}

import XCTest
@testable import TetherStudio

final class CardVolumeTests: XCTestCase {
    private var volumes: URL!

    override func setUpWithError() throws {
        volumes = FileManager.default.temporaryDirectory.appendingPathComponent("zve10-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: volumes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: volumes)
    }

    private func write(_ path: String, bytes: Int, age: TimeInterval) throws {
        let url = volumes.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    func testFindsOnlyAVolumeWithTheCameraClipFolder() throws {
        try write("Macintosh HD/Users/readme.txt", bytes: 1, age: 0)
        XCTAssertNil(CardVolume.find(under: volumes))
        try write("Untitled/PRIVATE/M4ROOT/CLIP/C0001.MP4", bytes: 10, age: 0)
        XCTAssertEqual(CardVolume.find(under: volumes)?.lastPathComponent, "Untitled")
    }

    func testListsClipsAndStillsNewestFirstAndSkipsOtherFiles() throws {
        try write("Untitled/PRIVATE/M4ROOT/CLIP/C0001.MP4", bytes: 100, age: 300)
        try write("Untitled/PRIVATE/M4ROOT/CLIP/C0002.MP4", bytes: 200, age: 100)
        try write("Untitled/PRIVATE/M4ROOT/CLIP/C0002M01.XML", bytes: 5, age: 100)
        try write("Untitled/PRIVATE/M4ROOT/CLIP/._C0002.MP4", bytes: 5, age: 100)
        try write("Untitled/DCIM/100MSDCF/DSC00001.JPG", bytes: 50, age: 200)
        let files = CardVolume.list(volumes.appendingPathComponent("Untitled"))
        XCTAssertEqual(files.map(\.name), ["C0002.MP4", "DSC00001.JPG", "C0001.MP4"])
        XCTAssertEqual(files.map(\.sizeBytes), [200, 50, 100])
        XCTAssertEqual(files.map(\.isVideo), [true, false, true])
    }

    func testCopyKeepsAFinishedCopyAndNeverReplacesADifferentFile() throws {
        try write("Untitled/PRIVATE/M4ROOT/CLIP/C0001.MP4", bytes: 1000, age: 60)
        let clip = try XCTUnwrap(CardVolume.list(volumes.appendingPathComponent("Untitled")).first)
        let out = volumes.appendingPathComponent("out/\(clip.dayFolder)")

        let first = try CardVolume.copy(clip, to: out)
        XCTAssertEqual(try Data(contentsOf: first).count, 1000)
        XCTAssertEqual(clip.dayFolder.count, 10)                                // yyyy-MM-dd, from the file's date

        XCTAssertEqual(try CardVolume.copy(clip, to: out), first)              // already here: not copied again

        // A file of the same name but another size is someone's other file (cameras reuse
        // numbers): it stays, and the clip is saved beside it. Nothing is ever replaced.
        try Data(repeating: 1, count: 3).write(to: first)
        let second = try CardVolume.copy(clip, to: out)
        XCTAssertEqual(second.lastPathComponent, "C0001 (2).MP4")
        XCTAssertEqual(try Data(contentsOf: second), Data(repeating: 7, count: 1000))
        XCTAssertEqual(try Data(contentsOf: first).count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["C0001 (2).MP4", "C0001.MP4"])
    }
}

final class ZoomPositionTests: XCTestCase {
    // Values read from a ZV-E10 while zooming (property 0xD25D, 0xD25C).
    func testOpticalRange() throws {
        let z = try XCTUnwrap(ZoomPosition(bar: "33554499", scale: "1000"))     // 0x02000043
        XCTAssertEqual(z.ranges, 2)
        XCTAssertEqual(z.range, 0)
        XCTAssertEqual(z.position, 67)
        XCTAssertEqual(z.fraction, 0.335, accuracy: 0.001)
        XCTAssertEqual(z.label, "Optical 67%")
    }

    func testClearImageZoomRange() throws {
        let z = try XCTUnwrap(ZoomPosition(bar: "33620068", scale: "2000"))     // 0x02010064
        XCTAssertEqual(z.range, 1)
        XCTAssertEqual(z.position, 100)
        XCTAssertEqual(z.fraction, 1.0, accuracy: 0.001)
        XCTAssertEqual(z.label, "Clear Image Zoom 2.0×")
    }

    func testWideEndAndUnreadableValues() throws {
        XCTAssertEqual(try XCTUnwrap(ZoomPosition(bar: "33554432", scale: "1000")).fraction, 0)
        XCTAssertNil(ZoomPosition(bar: nil, scale: "1000"))
        XCTAssertNil(ZoomPosition(bar: "n/a", scale: nil))
    }
}

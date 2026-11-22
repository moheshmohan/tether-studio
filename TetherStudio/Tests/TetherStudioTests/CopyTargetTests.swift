import XCTest
@testable import TetherStudio

/// Copying must never delete or overwrite anything on this Mac. On 18 Nov 2026 a file
/// description with an empty name made the copy routine take the download folder itself
/// for the destination and remove it; these tests pin the rule that replaced that code.
final class CopyTargetTests: XCTestCase {
    private var folder: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent("zve10-copy-\(UUID().uuidString)/2026-11-18")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: folder.deletingLastPathComponent())
    }

    private func write(_ name: String, bytes: Int) throws {
        try Data(repeating: 1, count: bytes).write(to: folder.appendingPathComponent(name))
    }

    private func contents() throws -> [String] {
        try fm.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func testNamesThatAreNotPlainFileNamesAreRefused() throws {
        try write("C0189.MP4", bytes: 10)
        for bad in ["", ".", "..", " ", "../C0001.MP4", "a/b.MP4", "/etc/hosts", ".hidden", "a:b.MP4", "x\0y.MP4"] {
            XCTAssertNil(CopyTarget.safeName(bad), "\"\(bad)\"")
            XCTAssertThrowsError(try CopyTarget.plan(name: bad, size: 5, in: folder), "\"\(bad)\"")
        }
        XCTAssertEqual(CopyTarget.safeName("C0189.MP4"), "C0189.MP4")
        XCTAssertEqual(try contents(), ["C0189.MP4"], "the folder and what is in it are untouched")
        XCTAssertTrue(fm.fileExists(atPath: folder.path))
    }

    func testANewFileGetsItsOwnNameAndAHiddenPartFile() throws {
        let plan = try CopyTarget.plan(name: "C0192.MP4", size: 100, in: folder)
        XCTAssertEqual(plan, .copy(to: folder.appendingPathComponent("C0192.MP4"),
                                   partial: folder.appendingPathComponent(".C0192.MP4.part")))
    }

    func testAFileOfTheSameSizeIsKeptAndNotCopiedAgain() throws {
        try write("C0190.MP4", bytes: 64)
        XCTAssertEqual(try CopyTarget.plan(name: "C0190.MP4", size: 64, in: folder),
                       .alreadyHere(folder.appendingPathComponent("C0190.MP4")))
    }

    func testADifferentFileOfTheSameNameIsKeptAndTheNewOneGetsANumber() throws {
        try write("C0001.MP4", bytes: 64)                       // cameras reuse numbers
        XCTAssertEqual(try CopyTarget.plan(name: "C0001.MP4", size: 99, in: folder),
                       .copy(to: folder.appendingPathComponent("C0001 (2).MP4"),
                             partial: folder.appendingPathComponent(".C0001 (2).MP4.part")))
        try write("C0001 (2).MP4", bytes: 99)
        XCTAssertEqual(try CopyTarget.plan(name: "C0001.MP4", size: 99, in: folder),
                       .alreadyHere(folder.appendingPathComponent("C0001 (2).MP4")))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("C0001.MP4")).count, 64)
    }

    func testAFolderOfTheSameNameIsLeftAlone() throws {
        let inTheWay = folder.appendingPathComponent("C0002.MP4")
        try fm.createDirectory(at: inTheWay, withIntermediateDirectories: true)
        try Data([1]).write(to: inTheWay.appendingPathComponent("keep.txt"))
        XCTAssertEqual(try CopyTarget.plan(name: "C0002.MP4", size: 5, in: folder),
                       .copy(to: folder.appendingPathComponent("C0002 (2).MP4"),
                             partial: folder.appendingPathComponent(".C0002 (2).MP4.part")))
        XCTAssertTrue(fm.fileExists(atPath: inTheWay.appendingPathComponent("keep.txt").path))
    }

    func testFinishingNeverReplacesWhatIsThere() throws {
        try write(".C0003.MP4.part", bytes: 30)
        try write("C0003.MP4", bytes: 7)                        // turned up while the copy ran
        let partial = folder.appendingPathComponent(".C0003.MP4.part"), dest = folder.appendingPathComponent("C0003.MP4")
        XCTAssertThrowsError(try CopyTarget.finish(partial: partial, dest: dest))
        XCTAssertEqual(try Data(contentsOf: dest).count, 7)
        XCTAssertEqual(try Data(contentsOf: partial).count, 30, "the new copy is not lost either")

        try write(".C0004.MP4.part", bytes: 30)
        try CopyTarget.finish(partial: folder.appendingPathComponent(".C0004.MP4.part"),
                              dest: folder.appendingPathComponent("C0004.MP4"))
        XCTAssertEqual(try contents(), [".C0003.MP4.part", "C0003.MP4", "C0004.MP4"])
    }

    func testAFileOfUnknownSizeThatIsThereIsNotCopiedAgain() throws {
        try write("C0005.MP4", bytes: 12)
        XCTAssertEqual(try CopyTarget.plan(name: "C0005.MP4", size: nil, in: folder),
                       .alreadyHere(folder.appendingPathComponent("C0005.MP4")))
    }

    func testCopyingFromAMountedCardKeepsADifferentFileOfTheSameName() throws {
        let card = folder.deletingLastPathComponent().appendingPathComponent("card")
        try fm.createDirectory(at: card, withIntermediateDirectories: true)
        let source = card.appendingPathComponent("C0006.MP4")
        try Data(repeating: 9, count: 50).write(to: source)
        try write("C0006.MP4", bytes: 20)
        let clip = ClipFile(number: 0, folder: card.path, name: "C0006.MP4", sizeBytes: 50, width: nil, height: nil,
                            mime: "video/mp4", unixTime: 0, diskURL: source)
        let copied = try CardVolume.copy(clip, to: folder)
        XCTAssertEqual(copied.lastPathComponent, "C0006 (2).MP4")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("C0006.MP4")).count, 20)
        XCTAssertEqual(try Data(contentsOf: copied).count, 50)
        XCTAssertEqual(try CardVolume.copy(clip, to: folder).lastPathComponent, "C0006 (2).MP4", "and not copied a third time")
    }

    // MARK: room on the disk

    func testACopyNeedsItsSizePlusTheSpareRoom() {
        let spare = UInt64(CopyTarget.spare)
        XCTAssertTrue(CopyTarget.hasRoom(free: Int64(spare) + 1000, needed: 1000))
        XCTAssertFalse(CopyTarget.hasRoom(free: Int64(spare) + 999, needed: 1000))
        XCTAssertFalse(CopyTarget.hasRoom(free: 0, needed: 1))
        XCTAssertTrue(CopyTarget.hasRoom(free: 0, needed: 0))          // nothing left to copy
        XCTAssertFalse(CopyTarget.hasRoom(free: -5, needed: 1))        // a disk reporting nonsense is "full", not a crash
    }

    func testACopyThatCannotFitIsRefusedBeforeAnythingIsWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zve10-room-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try CopyTarget.ensureRoom(for: 1, name: "C0001.MP4", in: dir))
        XCTAssertThrowsError(try CopyTarget.ensureRoom(for: UInt64(1) << 60, name: "C0001.MP4", in: dir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("not enough room"), error.localizedDescription)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    // MARK: a value on its way to the camera

    func testAControlShowsANumberHoweverItIsWritten() {
        let range = CameraConfig(path: "/main/imgsettings/colortemperature", label: "", type: "RANGE", readOnly: false,
                                 current: "4300.0", options: [], bottom: 2500, top: 9900, step: 100)
        XCTAssertTrue(range.shows("4300"))
        XCTAssertFalse(range.shows("4400"))
        let choice = CameraConfig(path: "/main/imgsettings/iso", label: "", type: "RADIO", readOnly: false,
                                  current: "Auto ISO", options: [], bottom: nil, top: nil, step: nil)
        XCTAssertTrue(choice.shows("Auto ISO"))
        XCTAssertFalse(choice.shows("400"))
        XCTAssertEqual(choice.with(current: "400").current, "400")
        XCTAssertEqual(choice.with(current: "400").path, choice.path)
    }
}

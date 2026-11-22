import XCTest
@testable import TetherStudio

final class CardWipeTests: XCTestCase {
    private var volumes: URL!
    private var card: URL!
    private let removable = CardWipe.VolumeFacts(isInternal: false, isRemovableMedia: true, isEjectableOrRemovable: true,
                                                 isRootVolume: false, capacity: 64_000_000_000, name: "Untitled")

    override func setUpWithError() throws {
        volumes = FileManager.default.temporaryDirectory.appendingPathComponent("wipe-test-\(UUID().uuidString)", isDirectory: true)
        card = volumes.appendingPathComponent("Untitled", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP"), withIntermediateDirectories: true)
        try fm.createDirectory(at: card.appendingPathComponent("DCIM/100MSDCF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: card.appendingPathComponent(".Spotlight-V100"), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        try Data(count: 500).write(to: card.appendingPathComponent("PRIVATE/M4ROOT/MEDIAPRO.XML"))
        try Data(count: 300).write(to: card.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG"))
        try Data(count: 200).write(to: card.appendingPathComponent("DCIM/100MSDCF/DSC00002.JPG"))
        try Data(count: 10).write(to: card.appendingPathComponent(".Spotlight-V100/store"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: volumes)        // this test's own temporary folder only
    }

    func testOnlyARemovableDiskWithTheCamerasFoldersIsTakenForTheCard() throws {
        XCTAssertNoThrow(try CardWipe.check(card, facts: removable, volumes: volumes))
        var inside = removable; inside.isInternal = true; inside.isRemovableMedia = false
        XCTAssertThrowsError(try CardWipe.check(card, facts: inside, volumes: volumes), "a fixed disk inside the Mac")
        var slot = removable; slot.isInternal = true
        XCTAssertNoThrow(try CardWipe.check(card, facts: slot, volumes: volumes), "a card in the Mac's own SD slot")
        var image = removable; image.isInternal = nil
        XCTAssertNoThrow(try CardWipe.check(card, facts: image, volumes: volumes), "macOS does not say for a disk image")
        var boot = removable; boot.isRootVolume = true
        XCTAssertThrowsError(try CardWipe.check(card, facts: boot, volumes: volumes))
        var fixed = removable; fixed.isEjectableOrRemovable = false
        XCTAssertThrowsError(try CardWipe.check(card, facts: fixed, volumes: volumes))
        var huge = removable; huge.capacity = 4_000_000_000_000
        XCTAssertThrowsError(try CardWipe.check(card, facts: huge, volumes: volumes))
        XCTAssertThrowsError(try CardWipe.check(card.appendingPathComponent("DCIM"), facts: removable, volumes: volumes),
                             "a folder inside a disk is not a disk")
        XCTAssertThrowsError(try CardWipe.check(card, facts: removable), "the real /Volumes is the default")
        try FileManager.default.removeItem(at: card.appendingPathComponent("PRIVATE"))
        XCTAssertThrowsError(try CardWipe.check(card, facts: removable, volumes: volumes), "no clip folder: not the camera's card")
    }

    func testThePlanCountsEverythingAndSaysWhatIsOnlyOnTheCard() throws {
        let plan = try CardWipe.plan(card, facts: removable, volumes: volumes) { $0.name == "C0001.MP4" }
        XCTAssertEqual(plan.items.map(\.lastPathComponent), ["DCIM", "PRIVATE"], "macOS's own folders stay")
        XCTAssertEqual(plan.files, 4)
        XCTAssertEqual(plan.bytes, 2000)
        XCTAssertEqual(plan.clips, 1)
        XCTAssertEqual(plan.photos, 2)
        XCTAssertEqual(Set(plan.notOnMac), ["DSC00001.JPG", "DSC00002.JPG"])
    }

    func testNothingIsErasedWithoutTheWord() throws {
        let plan = try CardWipe.plan(card, facts: removable, volumes: volumes) { _ in true }
        XCTAssertThrowsError(try CardWipe.erase(plan, facts: removable, typed: "erase", volumes: volumes) { _, _ in })
        XCTAssertThrowsError(try CardWipe.erase(plan, facts: removable, typed: "", volumes: volumes) { _, _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4").path))
    }

    func testTheEraseDeletesWhatThePlanListedAndNothingElse() throws {
        let plan = try CardWipe.plan(card, facts: removable, volumes: volumes) { _ in true }
        let outside = volumes.appendingPathComponent("Other disk file")
        try Data([1]).write(to: outside)
        let result = try CardWipe.erase(plan, facts: removable, typed: " ERASE ", volumes: volumes) { _, _ in }
        XCTAssertEqual(result.deleted, 2)
        XCTAssertEqual(result.failed, [])
        let left = try FileManager.default.contentsOfDirectory(atPath: card.path)
        XCTAssertEqual(left, [".Spotlight-V100"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "nothing next to the card is touched")
    }

    func testTheEraseChecksTheDiskAgain() throws {
        let plan = try CardWipe.plan(card, facts: removable, volumes: volumes) { _ in true }
        var nowInternal = removable; nowInternal.isInternal = true; nowInternal.isRemovableMedia = false
        XCTAssertThrowsError(try CardWipe.erase(plan, facts: nowInternal, typed: "ERASE", volumes: volumes) { _, _ in })
        let tampered = CardWipe.Plan(volume: plan.volume, volumeName: plan.volumeName,
                                     items: [volumes.appendingPathComponent("Other disk file")], files: 1, bytes: 1,
                                     clips: 0, photos: 0, notOnMac: [])
        XCTAssertThrowsError(try CardWipe.erase(tampered, facts: removable, typed: "ERASE", volumes: volumes) { _, _ in },
                             "an item that is not on the card is refused")
    }
}

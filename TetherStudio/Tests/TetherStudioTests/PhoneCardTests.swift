import XCTest
@testable import TetherStudio

final class BridgeFrameTests: XCTestCase {
    func testAChannelTheBoardNeverConfirmsIsAskedAgainAndThenTakenBack() {
        let start = Date()
        XCTAssertEqual(EspBridge.closingStep(since: start, askedAgain: false, now: start.addingTimeInterval(1)), .wait)
        XCTAssertEqual(EspBridge.closingStep(since: start, askedAgain: false, now: start.addingTimeInterval(3.5)), .askAgain)
        XCTAssertEqual(EspBridge.closingStep(since: start, askedAgain: true, now: start.addingTimeInterval(3.5)), .wait)
        XCTAssertEqual(EspBridge.closingStep(since: start, askedAgain: true, now: start.addingTimeInterval(6.5)), .giveUp)
        XCTAssertEqual(EspBridge.closingStep(since: start, askedAgain: false, now: start.addingTimeInterval(60)), .giveUp)
    }

    func testOnlyOneWindowHoldsTheLock() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(SingleInstance.windowIsOpen(url))
        XCTAssertTrue(SingleInstance.claim(url))
        XCTAssertTrue(SingleInstance.windowIsOpen(url))
        XCTAssertFalse(SingleInstance.claim(url), "a second window must not get the lock")
        // A lock file that cannot be made must not keep the app from starting.
        XCTAssertTrue(SingleInstance.claim(URL(fileURLWithPath: "/dev/null/nowhere/app.lock")))
    }

    func testFramesSurviveNoiseAndArbitrarySplits() {
        let frames = [
            BridgeFrame.Frame(type: BridgeFrame.rData, channel: 2, payload: (0..<768).map { UInt8($0 & 0xFF) }),
            BridgeFrame.Frame(type: BridgeFrame.rClosed, channel: 2, payload: []),
            BridgeFrame.Frame(type: BridgeFrame.rHello, channel: 0, payload: [0xA5, 0x5A, 0xA5]),
        ]
        var stream = Array("ESP-ROM:esp32c3\r\n".utf8) + [0xA5] + Array("boot".utf8) + [0xA5, 0x5A, 0x01]
        for f in frames { stream += BridgeFrame.encode(f.type, channel: f.channel, payload: f.payload) }
        stream += Array("tail".utf8)

        for step in [1, 3, 7, 4096] {
            var parser = BridgeFrame.Parser()
            var got: [BridgeFrame.Frame] = []
            var at = 0
            while at < stream.count {
                got += parser.feed(Array(stream[at..<min(at + step, stream.count)]))
                at += step
            }
            XCTAssertEqual(got, frames, "split every \(step) bytes")
        }
    }

    func testFrameLayoutMatchesTheBoardProgram() {
        // A5 5A, type, channel, length low, length high, check = type ^ channel ^ low ^ high ^ FF
        XCTAssertEqual(BridgeFrame.encode(BridgeFrame.open, channel: 3, payload: [192, 168, 122, 1, 0x7C, 0x3D]),
                       [0xA5, 0x5A, 0x02, 0x03, 0x06, 0x00, 0x02 ^ 0x03 ^ 0x06 ^ 0xFF, 192, 168, 122, 1, 0x7C, 0x3D])
    }

    func testAFrameWithAWrongCheckByteIsSkipped() {
        var bad = BridgeFrame.encode(BridgeFrame.rData, channel: 1, payload: [1, 2, 3])
        bad[6] ^= 0x10
        var parser = BridgeFrame.Parser()
        let good = BridgeFrame.encode(BridgeFrame.rClosed, channel: 1)
        XCTAssertEqual(parser.feed(bad + good), [BridgeFrame.Frame(type: BridgeFrame.rClosed, channel: 1, payload: [])])
    }

    func testSettingsAreSavedReadableOnlyByTheUser() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zve10-bridge-\(UUID().uuidString)/bridge.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(BridgeSettings.load(from: url), BridgeSettings())
        let settings = BridgeSettings(enabled: true, network: "DIRECT-abCD:ZV-E10", password: "secret pass")
        settings.save(to: url)
        XCTAssertEqual(BridgeSettings.load(from: url), settings)
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(BridgeSettings(enabled: true, network: "  ", password: "x").usable)
    }

    func testJoinProblemsAreExplained() {
        XCTAssertTrue(BridgeController.explain(201).contains("Connection screen"))
        XCTAssertTrue(BridgeController.explain(15).contains("password"))
    }
}

final class PhoneCardParsingTests: XCTestCase {
    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { le16(UInt16(v & 0xFFFF)) + le16(UInt16(v >> 16)) }
    private func ptpString(_ s: String) -> [UInt8] {
        s.isEmpty ? [0] : [UInt8(s.utf16.count + 1)] + (s.utf16.flatMap { le16($0) }) + [0, 0]
    }

    /// An ObjectInfo data set the way the camera sends it.
    private func objectInfo(name: String, size: UInt32, parent: UInt32, format: UInt16 = 0xB982, date: String = "") -> [UInt8] {
        le32(0x0001_0001) + le16(format) + le16(0) + le32(size) + [UInt8](repeating: 0, count: 26)
            + le32(parent) + [UInt8](repeating: 0, count: 10) + ptpString(name) + ptpString(date) + ptpString(date) + ptpString("")
    }

    func testObjectInfoIsRead() {
        let entry = CardEntry(handle: 0x4000_0329, objectInfo: objectInfo(name: "C0188.MP4", size: 20_978_360,
                                                                          parent: 0x4000_0300, date: "20261118T163545"))
        XCTAssertEqual(entry.name, "C0188.MP4")
        XCTAssertEqual(entry.size, 20_978_360)
        XCTAssertEqual(entry.parent, 0x4000_0300)
        XCTAssertFalse(entry.isFolder)
        XCTAssertEqual(entry.date, "20261118T163545")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: Date(timeIntervalSince1970: TimeInterval(entry.unixTime)))
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2026, 11, 18, 16, 35, 45])
    }

    func testFoldersAndFilesOfFourGigabytesOrMore() {
        let folder = CardEntry(handle: 1, objectInfo: objectInfo(name: "2026-11-18", size: 0, parent: 0, format: 0x3001))
        XCTAssertTrue(folder.isFolder)
        let huge = CardEntry(handle: 2, objectInfo: objectInfo(name: "C0001.MP4", size: 0xFFFF_FFFF, parent: 1))
        XCTAssertNil(huge.size)
    }

    func testATruncatedDataSetDoesNotCrash() {
        let entry = CardEntry(handle: 9, objectInfo: Array(objectInfo(name: "C0002.MP4", size: 5, parent: 1).prefix(30)))
        XCTAssertEqual(entry.name, "")
        var reader = PtpReader([3, 0, 0, 0, 0x01, 0x10])       // says three values, holds one
        XCTAssertEqual(reader.u16Array(), [0x1001])
    }

    func testClipsAreChosenAndTheNewestFound() {
        func entry(_ handle: UInt32, _ name: String, _ date: String, folder: String = "2026-11-18") -> CardEntry {
            var e = CardEntry(handle: handle, objectInfo: objectInfo(name: name, size: 100, parent: 1, date: date))
            e.folder = folder
            return e
        }
        let clips = CameraService.clips(from: [
            entry(10, "C0187.MP4", "20261117T223748", folder: "2026-11-17"),
            entry(11, "C0187M01.XML", "20261117T223748", folder: "2026-11-17"),
            entry(12, "C0188.MP4", "20261118T163545"),
            entry(13, "DSC00042.JPG", "20261118T170000"),
            entry(14, "C0009.MP4", "20270101T000000"),          // camera clock was wrong for this one
        ])
        XCTAssertEqual(clips.map(\.name), ["C0009.MP4", "DSC00042.JPG", "C0188.MP4", "C0187.MP4"])
        let newest = CameraService.newestVideo(clips)
        XCTAssertEqual(newest?.name, "C0188.MP4", "by file number, not by clock")
        XCTAssertEqual(newest?.cameraHandle, 12)
        XCTAssertEqual(newest?.dayFolder, "2026-11-18")
        XCTAssertEqual(newest?.id, "2026-11-18/C0188.MP4#0", "the same id in every session, so 'downloaded' is remembered")
    }

    func testWaitingTakesAreTheNewestOnesAboveTheMark() {
        func clip(_ name: String, _ time: Int64 = 0) -> ClipFile {
            ClipFile(number: 0, folder: "2026-11-18", name: name, sizeBytes: 1, width: nil, height: nil,
                     mime: name.hasSuffix("JPG") ? "image/jpeg" : "video/mp4", unixTime: time)
        }
        let card = [clip("C0192.MP4"), clip("DSC00400.JPG"), clip("C0190.MP4"), clip("C0191.MP4"), clip("C0188.MP4"), clip("C0189.MP4")]
        func names(_ after: Int?, _ count: Int) -> [String] { CameraService.takes(after: after, count: count, from: card).map(\.name) }

        XCTAssertEqual(names(191, 1), ["C0192.MP4"])                             // the usual case: one take just recorded
        XCTAssertEqual(names(189, 3), ["C0190.MP4", "C0191.MP4", "C0192.MP4"])  // three waiting: oldest first
        XCTAssertEqual(names(190, 3), ["C0191.MP4", "C0192.MP4"], "never further back than the mark")
        XCTAssertEqual(names(188, 2), ["C0191.MP4", "C0192.MP4"], "never more than were recorded here")
        XCTAssertEqual(names(192, 1), [], "the take was not saved by the camera: nothing older is fetched instead")
        XCTAssertEqual(names(nil, 1), ["C0192.MP4"])                             // first use: only the newest
        XCTAssertEqual(names(900, 2), ["C0191.MP4", "C0192.MP4"], "the camera started numbering again")
        XCTAssertEqual(names(191, 0), [])
        XCTAssertEqual(CameraService.highestClipNumber(card), 192)
        XCTAssertEqual(CameraService.newestVideo(card)?.name, "C0192.MP4")
    }

    func testAWatchedSittingTakesEveryClipAboveTheMarkEvenWhenAStopWasMissed() {
        func clip(_ name: String) -> ClipFile {
            ClipFile(number: 0, folder: "2026-11-21", name: name, sizeBytes: 1, width: nil, height: nil,
                     mime: name.hasSuffix("JPG") ? "image/jpeg" : "video/mp4", unixTime: 0)
        }
        // 21 Nov 2026: one stop seen, two files made (C0207 and C0208); only C0208 was copied.
        let card = [clip("C0205.MP4"), clip("C0206.MP4"), clip("C0207.MP4"), clip("DSC00401.JPG"), clip("C0208.MP4")]
        func names(_ after: Int?, _ count: Int, _ every: Bool) -> [String] {
            CameraService.takes(after: after, count: count, everyAbove: every, from: card).map(\.name)
        }
        XCTAssertEqual(names(206, 1, false), ["C0208.MP4"], "not watched: no more than were counted")
        XCTAssertEqual(names(206, 1, true), ["C0207.MP4", "C0208.MP4"], "watched: every take above the mark, oldest first")
        XCTAssertEqual(names(208, 1, true), [], "nothing new: nothing older is fetched instead")
        XCTAssertEqual(names(nil, 1, true), ["C0208.MP4"], "no mark yet: only the newest")
        XCTAssertEqual(names(900, 1, true), ["C0208.MP4"], "numbering started again: back to the count")
        XCTAssertEqual(names(206, 0, true), [], "nothing waiting")
    }

    func testOnlyReadingOperationsExist() {
        // The complete list of what PhoneCard can send. Nothing that writes, deletes, formats or updates.
        let allowed: Set<UInt16> = [0x1001, 0x1003, 0x1004, 0x1007, 0x1008, 0x9201, 0x9202, 0x9210, 0x9211, 0x9212, 0x9803]
        for code in UInt16(0x1000)...UInt16(0x9FFF) where CardOp(rawValue: code) != nil {
            XCTAssertTrue(allowed.contains(code), String(format: "unexpected operation 0x%04X", code))
        }
        for forbidden: UInt16 in [0x100B, 0x100C, 0x100D, 0x100F, 0x1010, 0x9205, 0x9207, 0x9227, 0x9228, 0x9229, 0x9804] {
            XCTAssertNil(CardOp(rawValue: forbidden))
        }
    }

    func testTheClipListSurvivesARestartOfTheApp() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zve10-clips-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ClipListCache.load(from: url))
        let clip = ClipFile(number: 3, folder: "/store_00010001/2026-11-19", name: "C0203.MP4", sizeBytes: 5_000_000_000,
                            width: nil, height: nil, mime: "video/mp4", unixTime: 1_795_000_000, cameraHandle: 0x40000CB9)
        let cache = ClipListCache(readAt: Date(timeIntervalSince1970: 1_795_000_100), clips: [clip])
        cache.save(to: url)
        XCTAssertEqual(ClipListCache.load(from: url), cache)
        XCTAssertEqual(ClipListCache.load(from: url)?.clips.first?.id, clip.id)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(ClipListCache.load(from: url))        // a damaged file is no list, not a crash
    }
}

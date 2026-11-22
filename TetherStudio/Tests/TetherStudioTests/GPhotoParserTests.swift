import XCTest
@testable import TetherStudio

final class GPhotoParserTests: XCTestCase {

    // MARK: - auto-detect

    func testAutoDetectPCRemote() {
        let text = """
        Model                          Port
        ----------------------------------------------------------
        Sony ZV-E10 (Control)          usb:002,001
        """
        XCTAssertEqual(GPhotoParser.parseAutoDetect(text), .pcRemote)
    }

    func testAutoDetectMTP() {
        let text = """
        Model                          Port
        ----------------------------------------------------------
        USB PTP Class Camera           usb:002,001
        """
        XCTAssertEqual(GPhotoParser.parseAutoDetect(text), .mtp)
    }

    func testAutoDetectNothing() {
        let text = """
        Model                          Port
        ----------------------------------------------------------
        """
        XCTAssertEqual(GPhotoParser.parseAutoDetect(text), .disconnected)
    }

    // MARK: - get-config blocks

    func testParseRadioBlock() {
        let text = """
        Label: Shutter Speed
        Readonly: 0
        Type: RADIO
        Current: 1/50
        Choice: 0 1/25
        Choice: 1 1/30
        Choice: 2 1/40
        Choice: 3 1/50
        END
        """
        let cfgs = GPhotoParser.parseConfigBlocks(text, paths: ["/main/capturesettings/shutterspeed"])
        let cfg = cfgs["shutterspeed"]
        XCTAssertNotNil(cfg)
        XCTAssertEqual(cfg?.label, "Shutter Speed")
        XCTAssertEqual(cfg?.type, "RADIO")
        XCTAssertEqual(cfg?.readOnly, false)
        XCTAssertEqual(cfg?.current, "1/50")
        XCTAssertEqual(cfg?.options.count, 4)
        XCTAssertEqual(cfg?.options[3].index, 3)
        XCTAssertEqual(cfg?.options[3].value, "1/50")
        XCTAssertEqual(cfg?.currentIndex, 3)
    }

    func testParseToggleWithSpacesInCurrent() {
        let text = """
        Label: Exposure Program
        Readonly: 0
        Type: RADIO
        Current: Movie (Scene)
        Choice: 0 P
        Choice: 7 Movie (M)
        END
        """
        let cfgs = GPhotoParser.parseConfigBlocks(text, paths: ["/main/capturesettings/expprogram"])
        XCTAssertEqual(cfgs["expprogram"]?.current, "Movie (Scene)")
        XCTAssertEqual(cfgs["expprogram"]?.currentIndex, nil)
    }

    func testParseRangeBlock() {
        let text = """
        Label: Focal Position
        Readonly: 1
        Type: RANGE
        Current: 100
        Bottom: 0
        Top: 100
        Step: 1
        END
        """
        let cfgs = GPhotoParser.parseConfigBlocks(text, paths: ["/main/capturesettings/focalposition"])
        let cfg = cfgs["focalposition"]
        XCTAssertEqual(cfg?.isRange, true)
        XCTAssertEqual(cfg?.readOnly, true)
        XCTAssertEqual(cfg?.bottom, 0)
        XCTAssertEqual(cfg?.top, 100)
        XCTAssertEqual(cfg?.step, 1)
    }

    func testParseMultipleBlocksPositional() {
        let text = """
        Label: ISO Speed
        Readonly: 0
        Type: RADIO
        Current: 400
        Choice: 0 100
        Choice: 1 400
        END
        Label: F-Number
        Readonly: 0
        Type: RADIO
        Current: f/5.6
        Choice: 0 f/3.5
        Choice: 1 f/5.6
        END
        """
        let cfgs = GPhotoParser.parseConfigBlocks(
            text,
            paths: ["/main/imgsettings/iso", "/main/capturesettings/f-number"]
        )
        XCTAssertEqual(cfgs["iso"]?.label, "ISO Speed")
        XCTAssertEqual(cfgs["f-number"]?.label, "F-Number")
        XCTAssertEqual(cfgs["f-number"]?.current, "f/5.6")
    }

    // MARK: - list-files

    func testParseListFiles() {
        let text = """
        There is no file in folder '/'.
        There is no file in folder '/store_00010001'.
        There are 2 files in folder '/store_00010001/2023-09-23'.
        #5     C0171.MP4                  rd 397372 KB 3840x2160 video/mp4 1695455490
        #6     DSC00323.JPG               rd 8155 KB 6000x3376 image/jpeg 1695453530
        """
        let clips = GPhotoParser.parseListFiles(text)
        XCTAssertEqual(clips.count, 2)

        let mp4 = clips[0]
        XCTAssertEqual(mp4.number, 5)
        XCTAssertEqual(mp4.folder, "/store_00010001/2023-09-23")
        XCTAssertEqual(mp4.name, "C0171.MP4")
        XCTAssertEqual(mp4.sizeBytes, 397372 * 1024)
        XCTAssertEqual(mp4.isVideo, true)
        XCTAssertEqual(mp4.width, 3840)
        XCTAssertEqual(mp4.height, 2160)
        XCTAssertEqual(mp4.unixTime, 1695455490)
        XCTAssertEqual(mp4.dayFolder, "2023-09-23")

        let jpg = clips[1]
        XCTAssertEqual(jpg.number, 6)
        XCTAssertEqual(jpg.isVideo, false)
        XCTAssertEqual(jpg.mime, "image/jpeg")
    }

    func testParseListFilesSmallFileBytes() {
        let text = """
        There are 1 files in folder '/store_00010001/2023-09-23'.
        #7     A0000001.DAT               rd 4096 B application/octet-stream 1695455555
        """
        let clips = GPhotoParser.parseListFiles(text)
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].sizeBytes, 4096)
    }

    // MARK: - full camera fixture

    func testFullCameraFixture() throws {
        // Fixture dumped live from the ZV-E10 (141 configs, PC Remote mode).
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/pc-remote-full.txt")
        let text = try String(contentsOf: fixtureURL, encoding: .utf8)

        let paths = controlPathsMirror()
        let cfgs = GPhotoParser.parseConfigBlocks(text, paths: paths)

        // Fixture was dumped in --list-config order; our subset must at least
        // contain the configs the app depends on.
        XCTAssertNotNil(cfgs["expprogram"], "expprogram missing from fixture parse")
        XCTAssertNotNil(cfgs["shutterspeed"])
        XCTAssertNotNil(cfgs["batterylevel"])
    }

    private func controlPathsMirror() -> [String] {
        // Same order as the dump source (zve10-config-tree-pcremote.txt).
        ["/main/settings/capturetarget", "/main/status/serialnumber", "/main/status/manufacturer",
         "/main/status/cameramodel", "/main/status/deviceversion", "/main/status/vendorextension",
         "/main/status/batterylevel", "/main/status/focusindication", "/main/imgsettings/imagesize",
         "/main/imgsettings/iso", "/main/imgsettings/colortemperature", "/main/imgsettings/whitebalance",
         "/main/capturesettings/zoom", "/main/capturesettings/exposurecompensation",
         "/main/capturesettings/flashmode", "/main/capturesettings/f-number",
         "/main/capturesettings/imagequality", "/main/capturesettings/jpegquality",
         "/main/capturesettings/pcsaveimgsize", "/main/capturesettings/pcsaveimgformat",
         "/main/capturesettings/focalposition", "/main/capturesettings/focusmode",
         "/main/capturesettings/expprogram", "/main/capturesettings/aspectratio",
         "/main/capturesettings/capturemode", "/main/capturesettings/exposuremetermode",
         "/main/capturesettings/shutterspeed", "/main/capturesettings/liveviewsettingeffect",
         "/main/capturesettings/focusarea", "/main/capturesettings/dro"]
    }
}

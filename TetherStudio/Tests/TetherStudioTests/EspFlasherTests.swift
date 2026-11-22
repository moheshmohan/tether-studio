import XCTest
@testable import TetherStudio

final class EspFlasherTests: XCTestCase {
    func testSlipRoundTripEscapesFrameBytes() {
        let raw: [UInt8] = [0x01, 0xC0, 0x02, 0xDB, 0x03]
        let framed = Slip.encode(raw)
        XCTAssertEqual(framed, [0xC0, 0x01, 0xDB, 0xDC, 0x02, 0xDB, 0xDD, 0x03, 0xC0])
        var d = Slip.Decoder()
        XCTAssertEqual(d.feed(framed), [raw])
    }

    func testDecoderDropsTextOutsideFramesAndJoinsSplitFrames() {
        var d = Slip.Decoder()
        let boot = Array("ESP-ROM:esp32c3\r\nwaiting for download\r\n".utf8)
        XCTAssertEqual(d.feed(boot + [0xC0, 0x01, 0x08]), [])
        XCTAssertEqual(d.feed([0x00, 0xC0]), [[0x01, 0x08, 0x00]])
    }

    func testCommandPacketLayout() {
        let p = RomLoader.packet(.readReg, RomLoader.le32(UInt32(0x4000_1000)))
        XCTAssertEqual(p, [0x00, 0x0A, 0x04, 0x00, 0, 0, 0, 0, 0x00, 0x10, 0x00, 0x40])
    }

    func testDataChecksumIsXorFromEF() {
        XCTAssertEqual(RomLoader.checksum([]), 0xEF)
        XCTAssertEqual(RomLoader.checksum([0xEF]), 0x00)
        XCTAssertEqual(RomLoader.checksum([0x01, 0x02, 0x04]), 0xEF ^ 0x07)
    }

    func testOnlyC3MagicsCountAsC3() {
        for m: UInt32 in [0x6921_506F, 0x1B31_506F, 0x4881_606F, 0x4361_606F] {
            XCTAssertEqual(EspFlasher.chipName(m), "ESP32-C3")
        }
        XCTAssertEqual(EspFlasher.chipName(0x9), "ESP32-S3")
        XCTAssertTrue(EspFlasher.chipName(0x1234).hasPrefix("unknown"))
    }

    func testImageCheckWantsAnEsp32C3Image() {
        var image = [UInt8](repeating: 0xFF, count: 0x20000)
        XCTAssertThrowsError(try EspFlasher.check(image))
        image[0] = 0xE9
        image[12] = 9; image[13] = 0              // made for an ESP32-S3
        XCTAssertThrowsError(try EspFlasher.check(image))
        image[12] = 5
        XCTAssertNoThrow(try EspFlasher.check(image))
        XCTAssertThrowsError(try EspFlasher.check(Array(image.prefix(100))))
    }

    func testBundledImageIsUsable() throws {
        let image = try EspFlasher.bundledImage(searchingUpFrom: URL(fileURLWithPath: #filePath))
        XCTAssertGreaterThan(image.version, 0)
        XCTAssertEqual(image.md5.count, 32)
    }
}

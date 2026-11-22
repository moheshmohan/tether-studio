import Foundation
import IOKit
import IOKit.serial
import CryptoKit

/// Puts the bridge program on an ESP32-C3 board (Seeed XIAO ESP32-C3, or any ESP32-C3 on its built-in
/// USB port) from inside the app: no esptool, Python or ESP-IDF needed.
///
/// It speaks the chip's own ROM bootloader protocol (the one esptool uses, documented by Espressif in
/// "Serial Protocol"): the USB-Serial/JTAG port's DTR and RTS lines restart the chip into its
/// bootloader, the ROM is asked what chip it is and what its MAC address is, and only an ESP32-C3 is
/// written. The image (bootloader, partition table and bridge program merged into one, built from
/// `esp32_bridge/idf`) goes to address 0, and the flash's MD5 is compared with the image's before
/// the chip is restarted into the new program.
enum EspFlasher {
    static let espressifVendor = 0x303A
    static let usbSerialJtagProduct = 0x1001
    /// The image inside the app; see `esp32_bridge/build_firmware.sh`.
    static let imageName = "bridge-esp32c3"

    // MARK: - finding boards

    struct Port: Equatable, Identifiable, Hashable {
        let path: String
        let vendor: Int?
        let product: Int?
        /// The USB serial number; for Espressif's USB-Serial/JTAG port it is the chip's MAC address.
        let serial: String?
        let name: String?
        var id: String { path }
        var isEspressif: Bool { vendor == EspFlasher.espressifVendor }
        var label: String {
            let what = isEspressif ? "Espressif USB-Serial/JTAG" : (name ?? "USB serial device")
            return serial.map { "\(what) · \($0)" } ?? what
        }
    }

    /// USB serial ports (`/dev/cu.*`) with what USB says about the device behind each, read from the
    /// system's device list: nothing is sent to the devices.
    static func ports() -> [Port] {
        var found: [Port] = []
        guard let match = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, path.hasPrefix("/dev/cu.usb") else { continue }
            func up(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            found.append(Port(path: path, vendor: (up("idVendor") as? NSNumber)?.intValue,
                              product: (up("idProduct") as? NSNumber)?.intValue,
                              serial: up("USB Serial Number") as? String, name: up("USB Product Name") as? String))
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - the image

    struct Image {
        let bytes: [UInt8]
        let version: Int
        var md5: String { Insecure.MD5.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined() }
    }

    enum FlashError: LocalizedError, Equatable {
        case noImage
        case badImage(String)
        case port(String)
        case noBootloader
        case wrongChip(String)
        case wrongBoard(expected: String, found: String)
        case rom(String)
        case verify
        case stopped

        var errorDescription: String? {
            switch self {
            case .noImage: return "The bridge program is missing from this copy of the app."
            case .badImage(let why): return "The bridge program inside the app is not usable (\(why))."
            case .port(let why): return "The board's USB port could not be used: \(why)"
            case .noBootloader:
                return "The board did not answer in its bootloader. Hold its BOOT button (B on a XIAO), "
                    + "unplug and plug it back in while holding it, let go, and try again."
            case .wrongChip(let chip):
                return "This board is an \(chip), not an ESP32-C3. Nothing was written to it."
            case .wrongBoard(let expected, let found):
                return "The board that answered (\(found)) is not the one chosen (\(expected)). Nothing was written."
            case .rom(let why): return "The board's bootloader refused: \(why)"
            case .verify: return "The flash does not read back as written. Try again; the board still starts its bootloader."
            case .stopped: return "Stopped."
            }
        }
    }

    /// The image that travels in the app (Contents/Resources/firmware), or next to the sources when
    /// run from the package.
    static func bundledImage(searchingUpFrom start: URL? = nil) throws -> Image {
        var candidates = [Bundle.main.url(forResource: imageName, withExtension: "bin", subdirectory: "firmware")].compactMap { $0 }
        // A build run from the package (`.build/…/TetherStudio`): the image is in the package's Resources.
        let starts = [start, Bundle.main.executableURL?.resolvingSymlinksInPath()].compactMap { $0 }
        for first in starts {
            var dir = first.deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("Resources/firmware/\(imageName).bin"))
                dir = dir.deletingLastPathComponent()
            }
        }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url) else { throw FlashError.noImage }
        var version = 0
        let info = url.deletingPathExtension().appendingPathExtension("json")
        if let d = try? Data(contentsOf: info), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            version = (j["version"] as? Int) ?? 0
        }
        let image = Image(bytes: [UInt8](data), version: version)
        try check(image.bytes)
        return image
    }

    /// An ESP image for the ESP32-C3 that starts at address 0 (the second-stage bootloader).
    static func check(_ bytes: [UInt8]) throws {
        guard bytes.count > 0x10000, bytes.count < 0x400000 else { throw FlashError.badImage("size \(bytes.count)") }
        guard bytes[0] == 0xE9 else { throw FlashError.badImage("not an ESP image") }
        let chip = Int(bytes[12]) | Int(bytes[13]) << 8
        guard chip == 5 else { throw FlashError.badImage("made for chip id \(chip), not the ESP32-C3") }
    }

    // MARK: - flashing

    enum Step: Equatable {
        case restarting
        case talking
        case found(String)              // MAC address
        case erasing
        case writing(Double)
        case verifying
        case starting
    }

    struct Outcome: Equatable {
        let mac: String
        let bytes: Int
        let seconds: Double
    }

    /// Writes `image` to the ESP32-C3 on `port`. `expectMAC`, when given, must be the MAC the chip
    /// reports (the USB serial number of the port chosen), so that no other board is written.
    static func flash(port: String, image: Image, expectMAC: String?, progress: (Step) -> Void,
                      cancelled: () -> Bool = { false }) throws -> Outcome {
        let start = Date()
        let line = try SerialLine(path: port)
        defer { line.close() }
        let rom = RomLoader(line: line)

        progress(.restarting)
        var synced = false
        for attempt in 0..<4 where !synced {
            line.enterBootloader(longer: attempt >= 2)
            progress(.talking)
            synced = rom.sync()
            if cancelled() { throw FlashError.stopped }
        }
        guard synced else { throw FlashError.noBootloader }

        let magic = try rom.readReg(0x4000_1000)
        let chip = chipName(magic)
        guard chip == "ESP32-C3" else { throw FlashError.wrongChip(chip) }
        let mac = try rom.mac()
        if let expectMAC, expectMAC.uppercased() != mac {
            throw FlashError.wrongBoard(expected: expectMAC.uppercased(), found: mac)
        }
        progress(.found(mac))

        try rom.spiAttach()
        try rom.setFlashParams(size: 4 << 20)
        progress(.erasing)
        let block = RomLoader.blockSize
        let blocks = (image.bytes.count + block - 1) / block
        try rom.flashBegin(size: image.bytes.count, blocks: blocks, offset: 0)
        for n in 0..<blocks {
            if cancelled() { throw FlashError.stopped }
            var piece = Array(image.bytes[(n * block)..<min(image.bytes.count, (n + 1) * block)])
            if piece.count < block { piece += [UInt8](repeating: 0xFF, count: block - piece.count) }
            try rom.flashData(piece, sequence: n)
            progress(.writing(Double(n + 1) / Double(blocks)))
        }
        progress(.verifying)
        guard try rom.flashMD5(offset: 0, size: image.bytes.count) == image.md5 else { throw FlashError.verify }
        progress(.starting)
        line.hardReset()
        return Outcome(mac: mac, bytes: image.bytes.count, seconds: Date().timeIntervalSince(start))
    }

    /// Restarts the board into its bootloader, asks what chip it is and its MAC address, and
    /// restarts it into its own program again. Nothing is written.
    static func identify(port: String) throws -> (chip: String, mac: String?) {
        let line = try SerialLine(path: port)
        defer { line.close() }
        let rom = RomLoader(line: line)
        var synced = false
        for attempt in 0..<4 where !synced {
            line.enterBootloader(longer: attempt >= 2)
            synced = rom.sync()
        }
        guard synced else { throw FlashError.noBootloader }
        let chip = chipName(try rom.readReg(0x4000_1000))
        let mac = chip == "ESP32-C3" ? try rom.mac() : nil
        line.hardReset()
        return (chip, mac)
    }

    /// From the ROM's chip-detect register (values from esptool's chip tables).
    static func chipName(_ magic: UInt32) -> String {
        switch magic {
        case 0x6921_506F, 0x1B31_506F, 0x4881_606F, 0x4361_606F: return "ESP32-C3"
        case 0x0000_0009: return "ESP32-S3"
        case 0x0000_07C6: return "ESP32-S2"
        case 0x00F0_1D83: return "ESP32"
        case 0x2CE0_806F: return "ESP32-C6"
        case 0x6F51_306F, 0x7C41_A06F: return "ESP32-C2"
        case 0xD7B7_3E80: return "ESP32-H2"
        default: return String(format: "unknown chip (0x%08X)", magic)
        }
    }
}

// MARK: - SLIP framing

enum Slip {
    static func encode(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0xC0]
        for b in bytes {
            switch b {
            case 0xC0: out += [0xDB, 0xDC]
            case 0xDB: out += [0xDB, 0xDD]
            default: out.append(b)
            }
        }
        out.append(0xC0)
        return out
    }

    /// Takes bytes as they come and hands back whole packets; anything outside a frame (the ROM's
    /// boot text, the bridge program's own frames) is dropped.
    struct Decoder {
        private var inFrame = false
        private var escape = false
        private var current: [UInt8] = []

        mutating func feed(_ bytes: [UInt8]) -> [[UInt8]] {
            var packets: [[UInt8]] = []
            for b in bytes {
                if b == 0xC0 {
                    if inFrame, !current.isEmpty { packets.append(current) }
                    inFrame = true
                    current = []
                    escape = false
                    continue
                }
                guard inFrame else { continue }
                if escape {
                    escape = false
                    current.append(b == 0xDC ? 0xC0 : b == 0xDD ? 0xDB : b)
                } else if b == 0xDB {
                    escape = true
                } else {
                    current.append(b)
                }
                if current.count > 4096 { inFrame = false; current = [] }
            }
            return packets
        }
    }
}

// MARK: - the ROM loader's commands

struct RomLoader {
    static let blockSize = 0x400            // what the ROM takes per FLASH_DATA
    let line: SerialLine
    private let decoder = Box(Slip.Decoder())

    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    enum Op: UInt8 {
        case flashBegin = 0x02, flashData = 0x03, sync = 0x08, readReg = 0x0A
        case spiSetParams = 0x0B, spiAttach = 0x0D, flashMD5 = 0x13
    }

    static func packet(_ op: Op, _ data: [UInt8], checksum: UInt32 = 0) -> [UInt8] {
        [0x00, op.rawValue] + le16(data.count) + le32(checksum) + data
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    static func le32(_ v: Int) -> [UInt8] { le32(UInt32(truncatingIfNeeded: v)) }

    static func checksum(_ data: [UInt8]) -> UInt32 { UInt32(data.reduce(UInt8(0xEF)) { $0 ^ $1 }) }

    struct Reply { let value: UInt32; let data: [UInt8] }

    /// Sends one command and waits for its reply. The ROM ends each reply's data with four status
    /// bytes: status (0 = done) and an error code.
    @discardableResult
    func command(_ op: Op, _ data: [UInt8], checksum: UInt32 = 0, timeout: TimeInterval = 3) throws -> Reply {
        try line.write(Slip.encode(Self.packet(op, data, checksum: checksum)))
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            let bytes = line.read(timeout: min(0.2, max(0.01, until.timeIntervalSinceNow)))
            for p in decoder.value.feed(bytes) {
                guard p.count >= 8, p[0] == 0x01, p[1] == op.rawValue else { continue }
                let value = UInt32(p[4]) | UInt32(p[5]) << 8 | UInt32(p[6]) << 16 | UInt32(p[7]) << 24
                let body = Array(p[8...])
                if body.count >= 2 {
                    let statusAt = body.count >= 4 ? body.count - 4 : body.count - 2
                    if body[statusAt] != 0 {
                        throw EspFlasher.FlashError.rom(String(format: "command 0x%02X failed, error 0x%02X", op.rawValue, body[statusAt + 1]))
                    }
                    return Reply(value: value, data: Array(body[..<statusAt]))
                }
                return Reply(value: value, data: body)
            }
        }
        throw EspFlasher.FlashError.rom(String(format: "no answer to command 0x%02X", op.rawValue))
    }

    /// The ROM answers SYNC once it is listening; a few tries, as esptool does.
    func sync() -> Bool {
        let body: [UInt8] = [0x07, 0x07, 0x12, 0x20] + [UInt8](repeating: 0x55, count: 32)
        for _ in 0..<8 {
            if (try? command(.sync, body, timeout: 0.15)) != nil {
                _ = line.read(timeout: 0.15)          // the ROM answers a SYNC more than once
                decoder.value = Slip.Decoder()
                return true
            }
        }
        return false
    }

    func readReg(_ address: UInt32) throws -> UInt32 {
        try command(.readReg, Self.le32(address)).value
    }

    /// The factory MAC address from the ESP32-C3's eFuse (MAC_SYS words at 0x60008844 and 0x60008848).
    func mac() throws -> String {
        let low = try readReg(0x6000_8844)
        let high = try readReg(0x6000_8848)
        let bytes = [UInt8((high >> 8) & 0xFF), UInt8(high & 0xFF), UInt8(low >> 24),
                     UInt8((low >> 16) & 0xFF), UInt8((low >> 8) & 0xFF), UInt8(low & 0xFF)]
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    func spiAttach() throws {
        try command(.spiAttach, [UInt8](repeating: 0, count: 8))
    }

    func setFlashParams(size: Int) throws {
        let words = [0, size, 64 * 1024, 4 * 1024, 256, 0xFFFF]
        try command(.spiSetParams, words.flatMap { Self.le32($0) })
    }

    /// Erases what will be written; about 30 s per MB at the most.
    func flashBegin(size: Int, blocks: Int, offset: Int) throws {
        let args = [size, blocks, Self.blockSize, offset, 0].flatMap { Self.le32($0) }
        try command(.flashBegin, args, timeout: max(10, 30 * Double(size) / 1_048_576))
    }

    func flashData(_ block: [UInt8], sequence: Int) throws {
        let head = [block.count, sequence, 0, 0].flatMap { Self.le32($0) }
        try command(.flashData, head + block, checksum: Self.checksum(block), timeout: 5)
    }

    func flashMD5(offset: Int, size: Int) throws -> String {
        let reply = try command(.flashMD5, [offset, size, 0, 0].flatMap { Self.le32($0) },
                                timeout: max(8, 8 * Double(size) / 1_048_576))
        if reply.data.count >= 32, let text = String(bytes: reply.data.prefix(32), encoding: .ascii) {
            return text.lowercased()
        }
        return reply.data.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - the USB serial port

/// A raw serial port with control of its DTR and RTS lines, which on the ESP32-C3's USB-Serial/JTAG
/// port drive the chip's boot pin (GPIO9) and reset.
final class SerialLine {
    private var fd: Int32

    init(path: String) throws {
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let why = errno == EBUSY ? "it is in use by another program" : String(cString: strerror(errno))
            throw EspFlasher.FlashError.port(why)
        }
        var tio = termios()
        tcgetattr(fd, &tio)
        cfmakeraw(&tio)
        cfsetspeed(&tio, speed_t(B115200))
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &tio)
        _ = ioctl(fd, TIOCEXCL)
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    deinit { close() }

    func write(_ bytes: [UInt8]) throws {
        var sent = 0
        let until = Date().addingTimeInterval(3)
        while sent < bytes.count {
            let n = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n > 0 { sent += n; continue }
            if n < 0, errno != EAGAIN { throw EspFlasher.FlashError.port(String(cString: strerror(errno))) }
            if Date() > until { throw EspFlasher.FlashError.port("writing timed out") }
            usleep(1000)
        }
    }

    /// What arrives within `timeout` (returns as soon as something is there).
    func read(timeout: TimeInterval) -> [UInt8] {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        return n > 0 ? Array(buf[0..<n]) : []
    }

    private func set(_ line: Int32, _ on: Bool) {
        var bits = line
        _ = ioctl(fd, on ? TIOCMBIS : TIOCMBIC, &bits)
    }
    private func dtr(_ on: Bool) { set(TIOCM_DTR, on) }
    private func rts(_ on: Bool) { set(TIOCM_RTS, on) }

    /// esptool's sequence for the USB-Serial/JTAG port: boot pin low (DTR), then through reset (RTS)
    /// via (1,1) rather than (0,0), then out of reset with the boot pin still held.
    func enterBootloader(longer: Bool) {
        let pause = useconds_t(longer ? 250_000 : 100_000)
        rts(false); dtr(false); usleep(pause)
        dtr(true); rts(false); usleep(pause)
        rts(true); dtr(false); rts(true); usleep(pause)
        dtr(false); rts(false)
        usleep(longer ? 400_000 : 150_000)
        _ = read(timeout: 0.05)
    }

    /// Restarts the chip into the program on its flash (boot pin released).
    func hardReset() {
        dtr(false)
        rts(true); usleep(200_000)
        rts(false); usleep(200_000)
    }
}

import Foundation

/// The camera's phone service ("Ctrl w/ Smartphone") exists only on the
/// camera's own DIRECT-… Wi-Fi network. An ESP32 board on this Mac's USB joins
/// that network and carries TCP connections to the camera, so the Mac's own
/// Wi-Fi can stay on the router. Board program: esp32_bridge/esp32_bridge.ino.
///
/// USB frame, both directions: A5 5A, type, channel, length (2, little
/// endian), check, payload; check = type ^ channel ^ length low ^ length high ^ FF.
enum BridgeFrame {
    static let maxPayload = 4096

    // Mac → board
    static let wifi: UInt8 = 0x01       // name, 0, password
    static let open: UInt8 = 0x02       // IPv4 (4), port (2, little endian)
    static let data: UInt8 = 0x03
    static let close: UInt8 = 0x04
    static let status: UInt8 = 0x05
    // board → Mac
    static let rWifi: UInt8 = 0x81      // state, reason, address (4), gateway (4), signal (int8)
    static let rOpened: UInt8 = 0x82    // 1 connected, 0 failed
    static let rData: UInt8 = 0x83
    static let rClosed: UInt8 = 0x84
    static let rHello: UInt8 = 0x88     // version, boot id (4)

    struct Frame: Equatable {
        let type: UInt8
        let channel: UInt8
        let payload: [UInt8]
    }

    static func encode(_ type: UInt8, channel: UInt8 = 0, payload: [UInt8] = []) -> [UInt8] {
        precondition(payload.count <= maxPayload, "payload too long for one frame")
        let low = UInt8(payload.count & 0xFF), high = UInt8(payload.count >> 8)
        return [0xA5, 0x5A, type, channel, low, high, type ^ channel ^ low ^ high ^ 0xFF] + payload
    }

    /// Finds frames in the byte stream from the board, skipping anything else
    /// (the board prints boot messages on the same port).
    struct Parser {
        private var buffer: [UInt8] = []

        mutating func feed(_ bytes: [UInt8]) -> [Frame] {
            buffer += bytes
            var frames: [Frame] = []
            var at = 0
            while true {
                while at < buffer.count && buffer[at] != 0xA5 { at += 1 }
                guard buffer.count - at >= 7 else { break }
                let type = buffer[at + 2], channel = buffer[at + 3], low = buffer[at + 4], high = buffer[at + 5]
                let length = Int(low) | Int(high) << 8
                guard buffer[at + 1] == 0x5A, (type ^ channel ^ low ^ high ^ 0xFF) == buffer[at + 6],
                      length <= BridgeFrame.maxPayload else {
                    at += 1
                    continue
                }
                guard buffer.count - at >= 7 + length else { break }
                frames.append(Frame(type: type, channel: channel, payload: Array(buffer[(at + 7)..<(at + 7 + length)])))
                at += 7 + length
            }
            buffer.removeFirst(at)
            return frames
        }
    }
}

/// One open USB link to the board, with local TCP ports that lead to the camera.
final class EspBridge: @unchecked Sendable {
    struct Wifi: Equatable {
        var state = 0               // 0 not started, 1 trying to join, 2 joined
        var reason = 0              // the board's last disconnect reason (Espressif numbering), 0 = none
        var address = "0.0.0.0"
        var camera = "0.0.0.0"      // the network's gateway, which is the camera
        var signal = 0              // dBm

        var joined: Bool { state == 2 && address != "0.0.0.0" }
    }

    enum Failure: LocalizedError {
        case portInUse(Int)
        case serial(String)

        var errorDescription: String? {
            switch self {
            case .portInUse(let port): return "port \(port) on this Mac is already in use (is relay.py running?)"
            case .serial(let why): return "cannot open the board's USB port: \(why)"
            }
        }
    }

    static let channels = 6
    static let cameraFallback = "192.168.122.1"

    /// The first USB serial device; the board shows up as /dev/cu.usbmodem….
    static func findPort() -> String? {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.usbmodem") }.sorted().first.map { "/dev/" + $0 }
    }

    private final class Conn {
        let fd: Int32
        private let lock = NSLock()
        private var closed = false

        init(fd: Int32) { self.fd = fd }

        func send(_ bytes: [UInt8]) {
            lock.lock(); defer { lock.unlock() }
            guard !closed else { return }
            bytes.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    sent += n
                }
            }
        }

        func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }

        func close() {
            shutdown()                  // wakes a send that is waiting for the other end
            lock.lock()
            closed = true
            _ = Darwin.close(fd)
            lock.unlock()
        }
    }

    private enum Slot {
        case free
        case open(Conn)
        case closing(since: Date, askedAgain: Bool)     // freed when the board confirms
    }

    /// How long a channel waits for the board to confirm that it is closed: after `closeAgainAfter`
    /// the close is sent once more, after `closeGiveUpAfter` the channel is taken back regardless
    /// (the board closes whatever is left on a channel when it is opened again).
    static let closeAgainAfter: TimeInterval = 3
    static let closeGiveUpAfter: TimeInterval = 6

    /// What a closing channel needs now.
    enum ClosingStep: Equatable { case wait, askAgain, giveUp }

    static func closingStep(since: Date, askedAgain: Bool, now: Date = Date()) -> ClosingStep {
        let age = now.timeIntervalSince(since)
        if age > closeGiveUpAfter { return .giveUp }
        return age > closeAgainAfter && !askedAgain ? .askAgain : .wait
    }

    private let fd: Int32
    private let path: String
    private let writeLock = NSLock()
    private let state = NSCondition()   // guards everything below
    private var slots = [Slot](repeating: .free, count: EspBridge.channels)
    private var openWait = [DispatchSemaphore?](repeating: nil, count: EspBridge.channels)
    private var openOK = [Bool](repeating: false, count: EspBridge.channels)
    private var listeners: [Int32] = []
    private var bootId: UInt32?
    private var restarted = false
    private var currentWifi: Wifi?
    private var lastFrame = Date()
    private var closed = false
    private let readerDone = DispatchSemaphore(value: 0)

    private(set) var version = 0

    init(path: String) throws {
        self.path = path
        fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.serial(String(cString: strerror(errno))) }
        var tio = termios()
        tcgetattr(fd, &tio)
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tio.c_cflag &= ~tcflag_t(HUPCL)             // closing the port must not reset the board
        tcsetattr(fd, TCSANOW, &tio)
        Thread.detachNewThread { [self] in readLoop() }
        Thread.detachNewThread { [self] in keepAlive() }
    }

    var alive: Bool { locked { !closed } }
    var wifi: Wifi? { locked { currentWifi } }

    /// True once after the board restarted (it then has forgotten the Wi-Fi details).
    func takeRestarted() -> Bool {
        locked {
            defer { restarted = false }
            return restarted
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        state.lock(); defer { state.unlock() }
        return body()
    }

    // MARK: - USB side

    private func send(_ type: UInt8, channel: UInt8 = 0, payload: [UInt8] = []) -> Bool {
        let bytes = BridgeFrame.encode(type, channel: channel, payload: payload)
        writeLock.lock(); defer { writeLock.unlock() }
        let deadline = Date().addingTimeInterval(6)
        var sent = 0
        while sent < bytes.count {
            if locked({ closed }) { return false }
            if !samePort() { markDead(); return false }     // gone: do not wait out the deadline on a dead port
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, bytes.count - sent) }
            if n > 0 {
                sent += n
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                if Date() > deadline { markDead(); return false }       // the board is not taking data
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 500)
            } else {
                markDead()
                return false
            }
        }
        return true
    }

    private func readLoop() {
        var parser = BridgeFrame.Parser()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var empty = 0
        while !locked({ closed }) {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 500) > 0 else { continue }
            // The board restarting or being unplugged takes its USB device away: the port hangs up.
            if p.revents & Int16(POLLIN) == 0, p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            if n <= 0 {
                empty += 1
                if n < 0 || empty > 20 { break }     // unplugged
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            empty = 0
            for frame in parser.feed(Array(buffer[0..<n])) { dispatch(frame) }
        }
        markDead()
        _ = Darwin.close(fd)
        readerDone.signal()
    }

    private func keepAlive() {
        var tick = 0
        while !locked({ closed }) {
            Thread.sleep(forTimeInterval: 0.5)
            tick += 1
            if !samePort() { markDead(); return }       // unplugged, or it came back as a new device
            guard tick % 4 == 0 else { continue }
            _ = send(BridgeFrame.status)
            tidyClosingChannels()
            if locked({ Date().timeIntervalSince(lastFrame) > 8 }) { markDead() }
        }
    }

    /// A channel stays taken until the board confirms that it is closed. If that confirmation never
    /// arrives, the channel must not stay taken for good. Seen on 19 Nov 2026: a second copy of the
    /// app read from the same port for two minutes and took the confirmations; all six channels were
    /// left waiting, and the app showed the board as joined while nothing reached the camera until
    /// it was restarted.
    private func tidyClosingChannels() {
        var askAgain: [Int] = []
        state.lock()
        for (i, slot) in slots.enumerated() {
            guard case .closing(let since, let asked) = slot else { continue }
            switch Self.closingStep(since: since, askedAgain: asked) {
            case .wait: break
            case .askAgain:
                slots[i] = .closing(since: since, askedAgain: true)
                askAgain.append(i)
            case .giveUp:
                slots[i] = .free
            }
        }
        state.unlock()
        for channel in askAgain { _ = send(BridgeFrame.close, channel: UInt8(channel)) }
    }

    /// False once the device behind the open port is gone or has been replaced by a new one of the same name.
    private func samePort() -> Bool {
        var mine = stat(), now = stat()
        guard fstat(fd, &mine) == 0, stat(path, &now) == 0 else { return false }
        return mine.st_rdev == now.st_rdev && mine.st_ino == now.st_ino
    }

    private func dispatch(_ frame: BridgeFrame.Frame) {
        let ch = Int(frame.channel)
        state.lock()
        lastFrame = Date()
        switch frame.type {
        case BridgeFrame.rData where ch < slots.count:
            if case .open(let conn) = slots[ch] {
                state.unlock()
                conn.send(frame.payload)
                return
            }
        case BridgeFrame.rOpened where ch < slots.count:
            openOK[ch] = frame.payload.first == 1
            openWait[ch]?.signal()
        case BridgeFrame.rClosed where ch < slots.count:
            if case .open(let conn) = slots[ch] { conn.shutdown() }
            slots[ch] = .free
        case BridgeFrame.rHello where frame.payload.count >= 5:
            version = Int(frame.payload[0])
            let id = frame.payload[1...4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if let known = bootId, known != id {
                restarted = true
                currentWifi = nil
                dropAllLocked()
            }
            bootId = id
        case BridgeFrame.rWifi where frame.payload.count >= 11:
            let p = frame.payload
            currentWifi = Wifi(state: Int(p[0]), reason: Int(p[1]),
                               address: p[2...5].map(String.init).joined(separator: "."),
                               camera: p[6...9].map(String.init).joined(separator: "."),
                               signal: Int(Int8(bitPattern: p[10])))
        default:
            break
        }
        state.broadcast()
        state.unlock()
    }

    private func dropAllLocked() {
        for (i, slot) in slots.enumerated() {
            if case .open(let conn) = slot { conn.shutdown() }
            slots[i] = .free
        }
    }

    private func markDead() {
        state.lock()
        let first = !closed
        closed = true
        if first {
            dropAllLocked()
            for listener in listeners {
                _ = Darwin.shutdown(listener, SHUT_RDWR)
                _ = Darwin.close(listener)
            }
            listeners = []
        }
        state.broadcast()
        state.unlock()
    }

    /// Stops everything and frees the USB port and the local ports.
    func close() {
        markDead()
        _ = readerDone.wait(timeout: .now() + 2)
    }

    // MARK: - handshake and Wi-Fi

    /// Asks until the board answers; false when it does not (no bridge program on it).
    func waitForBoard(timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard send(BridgeFrame.status) else { return false }
            state.lock()
            if bootId == nil { _ = state.wait(until: Date().addingTimeInterval(0.5)) }
            let seen = bootId != nil
            state.unlock()
            if seen { return true }
        }
        return false
    }

    /// Hands the network name and password to the board (kept there in memory
    /// only) and waits until it has joined or the time is up.
    @discardableResult
    func join(name: String, password: String, timeout: TimeInterval = 25) -> Wifi? {
        locked { currentWifi = nil }
        guard send(BridgeFrame.wifi, payload: Array(name.utf8) + [0] + Array(password.utf8)) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, alive {
            state.lock()
            _ = state.wait(until: Date().addingTimeInterval(1))
            let now = currentWifi
            state.unlock()
            if now?.joined == true { return now }
            _ = send(BridgeFrame.status)
        }
        return wifi
    }

    /// Has the board close every connection to the camera it still holds, and waits a moment for
    /// that to happen. The board keeps the connections of a program that went away (the app was
    /// closed, a check was stopped); closing them while the board is on the camera's network lets
    /// the camera hear of it. Left open they are cut silently the next time the board joins, and a
    /// connection cut that way in the middle of its first exchange has left the camera's phone
    /// service answering nobody until the camera was switched off and on (19 Nov 2026).
    func closeAllChannels(wait: TimeInterval = 0.4) {
        for channel in 0..<EspBridge.channels { _ = send(BridgeFrame.close, channel: UInt8(channel)) }
        Thread.sleep(forTimeInterval: wait)
    }

    /// The board's Wi-Fi state, asked for and waited for briefly; nil when it does not say.
    func askWifi(timeout: TimeInterval = 1) -> Wifi? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, alive {
            if let now = wifi { return now }
            _ = send(BridgeFrame.status)
            state.lock()
            _ = state.wait(until: Date().addingTimeInterval(0.25))
            state.unlock()
        }
        return wifi
    }

    /// Hands over the details without waiting; `wifi` shows how the board gets on.
    func requestJoin(name: String, password: String) {
        locked { currentWifi = nil }
        _ = send(BridgeFrame.wifi, payload: Array(name.utf8) + [0] + Array(password.utf8))
    }

    // MARK: - TCP side

    /// Opens 127.0.0.1:localPort; every connection to it is carried to the
    /// camera's `cameraPort`.
    func listen(localPort: Int, cameraPort: Int) throws {
        let server = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(localPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(server, 8) == 0 else {
            _ = Darwin.close(server)
            throw Failure.portInUse(localPort)
        }
        locked { listeners.append(server) }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(server, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                let conn = Conn(fd: client)
                Thread.detachNewThread { [self] in serve(conn, cameraPort: cameraPort) }
            }
        }
    }

    private func serve(_ conn: Conn, cameraPort: Int) {
        state.lock()
        let free = closed ? nil : slots.firstIndex { if case .free = $0 { return true } else { return false } }
        let wait = DispatchSemaphore(value: 0)
        if let free {
            slots[free] = .open(conn)
            openWait[free] = wait
            openOK[free] = false
        }
        let target = currentWifi?.joined == true ? currentWifi!.camera : EspBridge.cameraFallback
        state.unlock()
        guard let channel = free else {
            conn.close()
            return
        }

        let ip = target.split(separator: ".").compactMap { UInt8($0) }
        if ip.count == 4, send(BridgeFrame.open, channel: UInt8(channel),
                               payload: ip + [UInt8(cameraPort & 0xFF), UInt8(cameraPort >> 8)]),
           wait.wait(timeout: .now() + 9) == .success, locked({ openOK[channel] }) {
            var buffer = [UInt8](repeating: 0, count: BridgeFrame.maxPayload)
            while true {
                let n = recv(conn.fd, &buffer, buffer.count, 0)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                guard send(BridgeFrame.data, channel: UInt8(channel), payload: Array(buffer[0..<n])) else { break }
            }
        }

        state.lock()
        var mine = false
        if case .open(let current) = slots[channel], current === conn {
            mine = true
            slots[channel] = .closing(since: Date(), askedAgain: false)
        }
        let stillUp = !closed
        state.unlock()
        if mine && stillUp { _ = send(BridgeFrame.close, channel: UInt8(channel)) }
        conn.close()
    }
}

/// What the user entered for the bridge. Kept in one file that only this user
/// can read, so the app in its bundle and the command-line checks share it.
struct BridgeSettings: Codable, Equatable {
    var enabled = false
    var network = ""
    var password = ""

    var usable: Bool { enabled && !network.trimmingCharacters(in: .whitespaces).isEmpty }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether Studio", isDirectory: true).appendingPathComponent("bridge.json")
    }

    static func load(from url: URL = BridgeSettings.url) -> BridgeSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(BridgeSettings.self, from: data) else { return BridgeSettings() }
        return settings
    }

    func save(to url: URL = BridgeSettings.url) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum BridgeState: Equatable {
    case off
    case noBoard                    // nothing on USB that looks like the board
    case notAnswering(String)       // a USB serial device is there, but it does not speak the bridge protocol
    case unavailable(String)        // the USB port or the local ports could not be opened
    case joining(String)
    case cannotJoin(String, String) // network name, why
    case joined(String, Int)        // network name, signal in dBm

    var isJoined: Bool { if case .joined = self { return true } else { return false } }
}

/// Keeps the bridge running while it is switched on. `step` does one round; it
/// can block for some seconds while a board is first contacted, so call it off
/// the main thread, about once a second.
final class BridgeController: @unchecked Sendable {
    static let shared = BridgeController()
    /// Where the rest of the app finds the camera while the bridge is up.
    static let localHost = "127.0.0.1"

    private let lock = NSLock()
    private var bridge: EspBridge?
    private var applied: BridgeSettings?
    private var lastJoin = Date.distantPast

    func step(_ settings: BridgeSettings) -> BridgeState {
        lock.lock(); defer { lock.unlock() }
        guard settings.usable else {
            stopLocked()
            return .off
        }
        if let current = bridge, !current.alive { stopLocked() }
        let name = settings.network.trimmingCharacters(in: .whitespaces)

        if bridge == nil {
            guard let path = EspBridge.findPort() else { return .noBoard }
            let fresh: EspBridge
            do {
                fresh = try EspBridge(path: path)
                try fresh.listen(localPort: WifiDiscovery.controlPort, cameraPort: WifiDiscovery.controlPort)
                try fresh.listen(localPort: WifiDiscovery.descriptionPort, cameraPort: WifiDiscovery.descriptionPort)
            } catch {
                return .unavailable(error.localizedDescription)
            }
            guard fresh.waitForBoard() else {
                fresh.close()
                return .notAnswering(path)
            }
            // A board that is still on the camera's network from the last run is taken as it is:
            // what that run left open is closed (the camera hears of it), and the network is not
            // joined again, which would cut everything off silently for a second.
            fresh.closeAllChannels()
            bridge = fresh
            applied = fresh.askWifi()?.joined == true ? settings : nil
        }
        guard let bridge else { return .noBoard }

        // Hand over the details when they are new, when the board has forgotten them,
        // and again every so often while it has not joined (the camera's network only
        // exists while its Connection screen is open).
        let restarted = bridge.takeRestarted()
        let stale = bridge.wifi?.joined != true && Date().timeIntervalSince(lastJoin) > 20
        if applied != settings || restarted || bridge.wifi?.state == 0 || stale {
            applied = settings
            lastJoin = Date()
            if bridge.wifi?.joined == true { bridge.closeAllChannels() }     // before the network goes: see there
            // Not waited for: the caller sees "joining" at once and "joined" a few rounds later,
            // and can act on both changes (drop the old session, connect through the new one).
            bridge.requestJoin(name: name, password: settings.password)
            return .joining(name)
        }
        guard let wifi = bridge.wifi else { return .joining(name) }
        if wifi.joined { return .joined(name, wifi.signal) }
        return wifi.reason == 0 ? .joining(name) : .cannotJoin(name, Self.explain(wifi.reason))
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        bridge?.close()
        bridge = nil
        applied = nil
    }

    /// Espressif's disconnect reasons, in words, for the ones that happen in practice.
    static func explain(_ reason: Int) -> String {
        switch reason {
        case 201: return "the network is not in range. Is the camera on its Connection screen?"
        case 15, 202, 204: return "the camera refused the password"
        case 2, 200, 205: return "the camera stopped answering"
        default: return "the board reports problem \(reason)"
        }
    }
}

import Foundation

/// Reads the memory card over the camera's phone service ("Ctrl w/
/// Smartphone"), which hands the card over when a session is opened for
/// contents transfer. Checked on a ZV-E10, firmware 2.03 (FINDINGS.md §12d).
///
/// libgphoto2 cannot open that kind of session, so this file talks PTP/IP to
/// the camera itself, while libgphoto2's own session is closed. It is kept
/// read-only by construction:
///   - `CardOp` below is the complete list of operations it can send;
///   - `PtpIpLink.transact` cannot send a data phase, so nothing can be
///     written, deleted, formatted or uploaded through it.

/// Every operation this file can send to the camera.
enum CardOp: UInt16 {
    case getDeviceInfo = 0x1001
    case closeSession = 0x1003
    case getStorageIDs = 0x1004
    case getObjectHandles = 0x1007
    case getObjectInfo = 0x1008
    case sdioConnect = 0x9201                   // Sony's session handshake
    case sdioGetExtDeviceInfo = 0x9202
    case sdioOpenSession = 0x9210               // (1, 1) = a session for contents transfer
    case sdioGetPartialLargeObject = 0x9211     // read a piece of a file
    case sdioSetContentsTransferMode = 0x9212   // (2, 1, 0) show the card, (2, 0, 0) give it back
    case getObjectPropValue = 0x9803            // read one property of a file (used for the size of files of 4 GB or more)
}

enum CardError: LocalizedError {
    case link(String)           // the connection failed: nothing more can be done in this session
    case camera(String)         // the camera refused something
    case changed                // the card no longer holds what the list said
    case stopped                // the user stopped the copy

    var errorDescription: String? {
        switch self {
        case .link(let why): return why
        case .camera(let why): return why
        case .changed: return "The card's contents changed; refresh the clip list"
        case .stopped: return "Copy stopped; the part already copied is kept and is continued next time"
        }
    }
}

/// Set from the main thread to stop a copy after the piece in flight.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

// MARK: - PTP data sets

struct PtpReader {
    let bytes: [UInt8]
    private(set) var at = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { max(0, bytes.count - at) }

    mutating func skip(_ count: Int) { at += count }

    mutating func u8() -> UInt8 {
        defer { at += 1 }
        return at < bytes.count ? bytes[at] : 0
    }

    mutating func u16() -> UInt16 { UInt16(u8()) | UInt16(u8()) << 8 }

    mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }

    /// PTP string: a character count (including the closing zero), then UTF-16.
    mutating func string() -> String {
        let count = Int(u8())
        var units: [UInt16] = []
        for _ in 0..<count { units.append(u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    mutating func u16Array() -> [UInt16] {
        let count = min(Int(u32()), remaining / 2)
        return (0..<count).map { _ in u16() }
    }

    mutating func u32Array() -> [UInt32] {
        let count = min(Int(u32()), remaining / 4)
        return (0..<count).map { _ in u32() }
    }
}

/// One file or folder on the card.
struct CardEntry: Equatable {
    static let folderFormat: UInt16 = 0x3001

    let handle: UInt32
    var name: String
    var size: UInt64?           // nil when the camera only says "4 GB or more"
    var date: String            // "20261118T163545" as the camera gives it
    var parent: UInt32
    var isFolder: Bool
    var folder = ""             // names of the folders above, joined with "/"

    /// Parses the answer to GetObjectInfo.
    init(handle: UInt32, objectInfo data: [UInt8]) {
        var r = PtpReader(data)
        _ = r.u32()                             // storage
        let format = r.u16()
        _ = r.u16()                             // protection
        let size = r.u32()
        r.skip(26)                              // thumbnail and picture details
        parent = r.u32()
        r.skip(10)                              // association and sequence number
        name = r.string()
        date = r.remaining > 0 ? r.string() : ""
        self.handle = handle
        self.size = size == 0xFFFF_FFFF ? nil : UInt64(size)
        isFolder = format == CardEntry.folderFormat
    }

    var unixTime: Int64 {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: String(date.prefix(15))).map { Int64($0.timeIntervalSince1970) } ?? 0
    }
}

// MARK: - PTP/IP

/// PTP over TCP/IP: the two connections, and one operation at a time on them.
final class PtpIpLink {
    struct Reply {
        let code: UInt16
        let params: [UInt32]
        let data: [UInt8]

        var ok: Bool { code == 0x2001 }
    }

    private enum Packet: UInt32 {
        case initCommandRequest = 1, initCommandAck, initEventRequest, initEventAck, initFail
        case request, response, event, startData, data, cancel, endData, ping, pong
    }

    private var command: Int32 = -1
    private var events: Int32 = -1
    private var transaction: UInt32 = 0

    /// Receives one line per operation (code, parameters, answer, amount of data): for finding out
    /// afterwards what the camera said. Set before use; called from whichever thread uses the link.
    static var trace: ((String) -> Void)?

    /// `host` is an IPv4 address, optionally with ":port".
    init(host: String, guid: [UInt8], name: String) throws {
        let parts = host.split(separator: ":")
        let address = String(parts.first ?? "")
        let port = parts.count > 1 ? Int(parts[1]) ?? WifiDiscovery.controlPort : WifiDiscovery.controlPort
        do {
            command = try Self.connect(address, port)
            var body = guid
            for unit in (name + "\0").utf16 { body += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            body += [0, 0, 1, 0]                                    // protocol version 1.0
            try send(command, .initCommandRequest, body)
            let (type, answer) = try receive(command, timeout: 30)
            if type == Packet.initFail.rawValue { throw CardError.link("the camera refused the connection") }
            guard type == Packet.initCommandAck.rawValue, answer.count >= 4 else {
                throw CardError.link("unexpected answer from the camera (packet type \(type))")
            }
            events = try Self.connect(address, port)
            try send(events, .initEventRequest, Array(answer[0..<4]))
            guard try receive(events, timeout: 10).type == Packet.initEventAck.rawValue else {
                throw CardError.link("the camera refused the event connection")
            }
        } catch {
            close()
            throw error
        }
        let fd = events
        Thread.detachNewThread { [weak self] in self?.drainEvents(fd) }
    }

    deinit { close() }

    func close() {
        for fd in [events, command] where fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }
        events = -1
        command = -1
    }

    /// Runs one operation. There is deliberately no way to send data to the
    /// camera here. `onData` gets the incoming data piece by piece instead of
    /// it being collected in the reply.
    func transact(_ op: CardOp, _ params: [UInt32] = [], timeout: TimeInterval = 30,
                  onData: (([UInt8]) throws -> Void)? = nil) throws -> Reply {
        guard command >= 0 else { throw CardError.link("not connected") }
        let id = transaction
        transaction += 1
        var body = le(UInt32(1)) + le(op.rawValue) + le(id)         // 1 = no data phase from this side
        for p in params { body += le(p) }
        try send(command, .request, body)

        var data: [UInt8] = []
        while true {
            let (type, length) = try header(command, timeout: timeout)
            switch Packet(rawValue: type) {
            case .data, .endData:
                guard length >= 4 else { throw CardError.link("bad data packet from the camera") }
                _ = try exactly(command, 4, timeout: timeout)       // transaction id
                var left = length - 4
                while left > 0 {
                    let piece = try exactly(command, min(left, 1 << 16), timeout: timeout)
                    left -= piece.count
                    if let onData { try onData(piece) } else { data += piece }
                }
            case .response:
                let answer = try exactly(command, length, timeout: timeout)
                guard answer.count >= 6 else { throw CardError.link("bad response packet from the camera") }
                var r = PtpReader(answer)
                let code = r.u16()
                _ = r.u32()                                         // transaction id
                var out: [UInt32] = []
                while r.remaining >= 4 { out.append(r.u32()) }
                if let trace = PtpIpLink.trace {
                    trace(String(format: "0x%04X ", op.rawValue) + params.map { String(format: "%X", $0) }.joined(separator: ",")
                          + String(format: " -> 0x%04X ", code) + out.map { String(format: "%X", $0) }.joined(separator: ",")
                          + " data \(onData == nil ? data.count : -1)")
                }
                return Reply(code: code, params: out, data: data)
            case .ping:
                _ = try exactly(command, length, timeout: timeout)
                try send(command, .pong, [])
            default:
                _ = try exactly(command, length, timeout: timeout)  // start-of-data and anything unknown
            }
        }
    }

    // MARK: sockets

    private func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func connect(_ address: String, _ port: Int) throws -> Int32 {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else {
            throw CardError.link("'\(address)' is not a camera address")
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var wait = timeval(tv_sec: 8, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let started = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var failure: Int32 = started == 0 ? 0 : errno
        if failure == EINPROGRESS {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&p, 1, 8000) <= 0 {
                failure = ETIMEDOUT
            } else {
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
            }
        }
        guard failure == 0 else {
            _ = Darwin.close(fd)
            throw CardError.link("no connection to the camera at \(address): \(String(cString: strerror(failure)))")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        return fd
    }

    private func send(_ fd: Int32, _ type: Packet, _ body: [UInt8]) throws {
        let bytes = le(UInt32(8 + body.count)) + le(type.rawValue) + body
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw CardError.link("the connection to the camera was lost") }
            sent += n
        }
    }

    private func exactly(_ fd: Int32, _ count: Int, timeout: TimeInterval) throws -> [UInt8] {
        var wait = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, count - got, 0) }
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                throw CardError.link("the camera did not answer in time")
            }
            guard n > 0 else { throw CardError.link("the connection to the camera was lost") }
            got += n
        }
        return buffer
    }

    private func header(_ fd: Int32, timeout: TimeInterval) throws -> (type: UInt32, length: Int) {
        var r = PtpReader(try exactly(fd, 8, timeout: timeout))
        let length = Int(r.u32()), type = r.u32()
        guard length >= 8, length <= 64 << 20 else { throw CardError.link("bad packet length \(length) from the camera") }
        return (type, length - 8)
    }

    private func receive(_ fd: Int32, timeout: TimeInterval) throws -> (type: UInt32, body: [UInt8]) {
        let (type, length) = try header(fd, timeout: timeout)
        return (type, try exactly(fd, length, timeout: timeout))
    }

    /// The camera reports events on the second connection; they are read and
    /// dropped so it never has to wait, and its pings are answered.
    private func drainEvents(_ fd: Int32) {
        while let (type, _) = try? receive(fd, timeout: 3600) {
            if type == Packet.ping.rawValue { try? send(fd, .pong, []) }
        }
    }
}

// MARK: - the card

/// An open contents-transfer session with the card showing.
final class PhoneCard {
    static let cardStorage: UInt32 = 0x0001_0001
    static let chunk = 3 * 1024 * 1024

    private let link: PtpIpLink
    /// Least time from the start of one file read to the start of the next.
    ///
    /// Measured on the ZV-E10 (FINDINGS §12h): within one file, a read that starts soon after the
    /// previous read started is sometimes served from the previous read's position, with the new
    /// length and no error: 23 % of 32 KB reads at 0.4 s apart, none of 90 at 0.8 s or more, and none
    /// after a read that itself took a second (which is why 3 MB pieces over a slow link were never
    /// hit). Reads of another file are not affected. (Changeable only for measurements and so that a
    /// test can show the second line of defence in `download`.)
    static var readSpacing: TimeInterval = 1.0

    private var lastReadStarted = Date.distantPast
    private var storage: UInt32 = 0
    private var cardRequested = false
    private var advertised: Set<UInt16> = []

    /// Connects, opens the session and asks for the card. The other session to
    /// the camera (remote control) must be closed first.
    init(host: String, guid: [UInt8], name: String) throws {
        link = try PtpIpLink(host: host, guid: guid, name: name)
        do {
            let ops = Set(try operations())
            for needed in [CardOp.sdioOpenSession, .sdioSetContentsTransferMode, .sdioGetPartialLargeObject]
            where !ops.contains(needed.rawValue) {
                throw CardError.camera("The camera does not offer its card on this connection")
            }
            try must(.sdioOpenSession, [1, 1], "open a session for the card")
            try must(.sdioConnect, [1, 0, 0], "start the session")
            try must(.sdioConnect, [2, 0, 0], "start the session")
            if !(try link.transact(.sdioGetExtDeviceInfo, [300])).ok {
                try must(.sdioGetExtDeviceInfo, [200], "start the session")
            }
            try must(.sdioConnect, [3, 0, 0], "start the session")
            advertised = ops.union(try operations())    // the camera expects to be asked again once the session is up
            PhoneCard.lastAdvertised = advertised.sorted()

            try must(.sdioSetContentsTransferMode, [2, 1, 0], "hand over the card")
            cardRequested = true
            // The card shows up about a second later (measured); PC Remote never shows it.
            let deadline = Date().addingTimeInterval(12)
            while storage == 0 {
                let reply = try link.transact(.getStorageIDs)
                if reply.ok {
                    var r = PtpReader(reply.data)
                    let cards = r.u32Array().filter { $0 & 0xFFFF != 0 && $0 >> 16 != 0x00F1 }
                    storage = cards.contains(PhoneCard.cardStorage) ? PhoneCard.cardStorage : cards.first ?? 0
                }
                if storage == 0 {
                    guard Date() < deadline else {
                        throw CardError.camera("The camera did not show its card. Is a card in, and is the camera on Ctrl w/ Smartphone rather than PC Remote?")
                    }
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
        } catch {
            close()
            throw error
        }
    }

    /// Gives the card back to the camera and closes the session.
    func close() {
        if cardRequested { _ = try? link.transact(.sdioSetContentsTransferMode, [2, 0, 0], timeout: 5) }
        cardRequested = false
        _ = try? link.transact(.closeSession, timeout: 5)
        link.close()
    }

    private func operations() throws -> [UInt16] {
        let reply = try link.transact(.getDeviceInfo)
        guard reply.ok else { throw CardError.camera("The camera did not describe itself") }
        var r = PtpReader(reply.data)
        r.skip(8)                   // standard version, vendor extension id and version
        _ = r.string()              // vendor extension description
        r.skip(2)                   // functional mode
        return r.u16Array()
    }

    @discardableResult
    private func must(_ op: CardOp, _ params: [UInt32], _ what: String, timeout: TimeInterval = 30) throws -> PtpIpLink.Reply {
        let reply = try link.transact(op, params, timeout: timeout)
        guard reply.ok else {
            throw CardError.camera(String(format: "The camera refused to \(what) (0x%04X)", reply.code))
        }
        return reply
    }

    func info(_ handle: UInt32) throws -> CardEntry {
        let data = try must(.getObjectInfo, [handle], "describe a file").data
        guard data.count >= 53 else {           // shorter than a description with an empty name: not a description
            throw CardError.camera(String(format: "The camera did not describe file 0x%08X", handle))
        }
        var entry = CardEntry(handle: handle, objectInfo: data)
        // Measured: asked about a file before the card's list has been requested in this session, the
        // camera answers "OK" with an all-zero description. That is not a file.
        guard CopyTarget.safeName(entry.name) != nil else {
            throw CardError.camera(String(format: "The camera gave no usable description of file 0x%08X", handle))
        }
        if entry.size == nil, !entry.isFolder, has(.getObjectPropValue) {
            // 4 GB or more does not fit the description's size field; the object-size property holds the real one.
            let reply = try link.transact(.getObjectPropValue, [handle, 0xDC04])
            if reply.ok, reply.data.count >= 8 {
                entry.size = reply.data[0..<8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
        }
        return entry
    }

    private func has(_ op: CardOp) -> Bool { advertised.contains(op.rawValue) }

    /// The operations the camera offered in the last card session (for the command-line checks).
    nonisolated(unsafe) static var lastAdvertised: [UInt16] = []

    /// For checks from the command line: the size field of the file's description exactly as the camera
    /// sends it (32 bits), and the answer to the object-size property (64 bits), if the camera gives one.
    func sizesAsReported(_ handle: UInt32) throws -> (description: UInt32, property: UInt64?, code: UInt16) {
        let data = try must(.getObjectInfo, [handle], "describe a file").data
        var r = PtpReader(data)
        r.skip(8)
        let small = r.u32()
        guard has(.getObjectPropValue) else { return (small, nil, 0) }
        let reply = try link.transact(.getObjectPropValue, [handle, 0xDC04])
        let big = reply.ok && reply.data.count >= 8 ? reply.data[0..<8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } : nil
        return (small, big, reply.code)
    }

    /// For checks from the command line: one piece of a file, wherever it lies.
    func read(_ handle: UInt32, offset: UInt64, length: Int) throws -> [UInt8] {
        let reply = try readPiece(handle, offset: offset, length: length, onData: nil)
        guard reply.ok else { throw CardError.camera(String(format: "read at %llu refused (0x%04X)", offset, reply.code)) }
        return reply.data
    }

    /// Every read of file contents goes through here, so that the spacing rule cannot be missed.
    private func readPiece(_ handle: UInt32, offset: UInt64, length: Int, onData: (([UInt8]) throws -> Void)?) throws -> PtpIpLink.Reply {
        let wait = PhoneCard.readSpacing - Date().timeIntervalSince(lastReadStarted)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        lastReadStarted = Date()
        return try link.transact(.sdioGetPartialLargeObject,
                                 [handle, UInt32(offset & 0xFFFF_FFFF), UInt32(offset >> 32), UInt32(length)],
                                 timeout: 20, onData: onData)
    }

    private func handles(in parent: UInt32) throws -> [UInt32] {
        let reply = try link.transact(.getObjectHandles, [storage, 0, parent], timeout: 60)
        guard reply.ok else { return [] }
        var r = PtpReader(reply.data)
        return r.u32Array()
    }

    /// Every file on the card. `known` holds what earlier listings found, so
    /// only new files cost a question each (about a quarter second through
    /// the bridge); it is updated in place.
    func list(known: inout [UInt32: CardEntry], progress: (Int, Int) -> Void, cancel: CancelFlag) throws -> [CardEntry] {
        var all = try handles(in: 0)                    // 0 = everything, whatever the folder
        if all.isEmpty {                                // some cameras only answer folder by folder
            var pending: [UInt32] = [0xFFFF_FFFF]
            var seen = Set<UInt32>()
            while let parent = pending.popLast() {
                for handle in try handles(in: parent) where seen.insert(handle).inserted {
                    all.append(handle)
                    if known[handle] == nil { known[handle] = try info(handle) }
                    if known[handle]?.isFolder == true { pending.append(handle) }
                    if cancel.isSet { throw CardError.stopped }
                }
            }
        }
        let present = Set(all)
        if known.keys.contains(where: { !present.contains($0) }) { known.removeAll() }     // something was deleted
        let missing = all.filter { known[$0] == nil }
        for (index, handle) in missing.enumerated() {
            if cancel.isSet { throw CardError.stopped }
            progress(index, missing.count)
            known[handle] = try info(handle)
        }
        return all.compactMap { handle -> CardEntry? in
            guard var entry = known[handle], !entry.isFolder else { return nil }
            var names: [String] = [], parent = entry.parent, visited = Set<UInt32>()
            while let above = known[parent], visited.insert(parent).inserted {
                names.insert(above.name, at: 0)
                parent = above.parent
            }
            entry.folder = names.joined(separator: "/")
            return entry
        }
    }

    /// Copies one file into `directory`. A copy of the right size that is
    /// already there is kept; an interrupted copy is continued. Nothing on
    /// this Mac is ever deleted or overwritten (see `CopyTarget`).
    func download(_ entry: CardEntry, to directory: URL, progress: (Int64, Int64?) -> Void, cancel: CancelFlag) throws -> URL {
        let now = try info(entry.handle)                // the list may be older than the card
        guard now.name == entry.name, now.size == entry.size, now.isFolder == entry.isFolder else { throw CardError.changed }
        guard !entry.isFolder else { throw CardError.camera("\(entry.name) is a folder, not a file") }
        guard entry.size != 0 else { throw CardError.camera("\(entry.name) is empty on the card") }

        let dest: URL, partial: URL
        switch try CopyTarget.plan(name: entry.name, size: entry.size, in: directory) {
        case .alreadyHere(let url): return url
        case .copy(let to, let part): (dest, partial) = (to, part)
        }
        let fm = FileManager.default
        var offset: UInt64 = ((try? fm.attributesOfItem(atPath: partial.path))?[.size] as? NSNumber)?.uint64Value ?? 0
        if let size = entry.size, offset > size { offset = 0 }
        if let size = entry.size { try CopyTarget.ensureRoom(for: size - offset, name: entry.name, in: directory) }
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        try file.truncate(atOffset: offset)
        try file.seek(toOffset: offset)

        let total = entry.size.map { Int64($0) }
        progress(Int64(offset), total)
        var previousStart: [UInt8] = []         // how the piece before this one began
        var repeats = 0
        while entry.size == nil || offset < entry.size! {
            if cancel.isSet { throw CardError.stopped }
            let want = UInt64(entry.size.map { min(UInt64(PhoneCard.chunk), $0 - offset) } ?? UInt64(PhoneCard.chunk))
            var got: UInt64 = 0
            var thisStart: [UInt8] = []
            let start = offset
            let reply = try withoutActuallyEscaping(progress) { progress in
                try readPiece(entry.handle, offset: start, length: Int(want)) { piece in
                    try file.write(contentsOf: piece)
                    if thisStart.count < 4096 { thisStart += piece.prefix(4096 - thisStart.count) }
                    got += UInt64(piece.count)
                    progress(Int64(start + got), total)
                }
            }
            guard reply.ok else {
                throw CardError.camera(String(format: "The camera stopped handing over \(entry.name) (0x%04X)", reply.code))
            }
            guard got <= want else {
                throw CardError.camera("\(entry.name): the camera sent more than was asked for; the copy was not kept")
            }
            // A second line of defence against the fault that `readSpacing` avoids: a piece that begins
            // exactly like the piece before it has most likely been served from that piece's position.
            // Read it again after a pause; what comes then is taken, since after a pause the camera is right.
            if !thisStart.isEmpty, thisStart.count <= previousStart.count,
               thisStart == Array(previousStart.prefix(thisStart.count)), repeats < 2 {
                repeats += 1
                try file.truncate(atOffset: start)
                try file.seek(toOffset: start)
                Thread.sleep(forTimeInterval: 1.0)
                continue
            }
            repeats = 0
            previousStart = thisStart
            offset += got
            if got < want { break }
        }
        try file.close()
        if let size = entry.size, offset != size {
            throw CardError.camera("\(entry.name): got \(offset) of \(size) bytes; copy it again to continue")
        }
        try CopyTarget.finish(partial: partial, dest: dest)
        return dest
    }
}

/// Where a copied file goes on this Mac. The rule here is that copying never
/// deletes or overwrites anything: a name from the camera is used only if it
/// is a plain file name, a file that is already there is left alone, and the
/// finished copy is moved into place only where nothing exists.
enum CopyTarget {
    enum Plan: Equatable {
        case alreadyHere(URL)               // a file of this name and size is there: nothing to do
        case copy(to: URL, partial: URL)    // write to `partial`, then `finish` moves it to `to`
    }

    /// The name as one path component, or nil when it cannot be one (empty,
    /// ".", "..", or containing a path separator).
    static func safeName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."),
              !name.contains("/"), !name.contains(":"), !name.contains("\0"),
              !name.trimmingCharacters(in: .whitespaces).isEmpty,
              (name as NSString).lastPathComponent == name else { return nil }
        return name
    }

    /// `size` nil = the camera could not say how big the file is.
    static func plan(name: String, size: UInt64?, in directory: URL) throws -> Plan {
        guard let name = safeName(name) else {
            throw CardError.camera("The camera gave a file name that cannot be used here (\"\(name)\"); nothing was copied")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for attempt in 1...99 {
            let candidate = attempt == 1 ? name : "\(base) (\(attempt))" + (ext.isEmpty ? "" : "." + ext)
            let url = directory.appendingPathComponent(candidate, isDirectory: false)
            var isDirectory: ObjCBool = false
            if !fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                return .copy(to: url, partial: directory.appendingPathComponent("." + candidate + ".part", isDirectory: false))
            }
            if isDirectory.boolValue { continue }       // a folder of that name: use the next name, touch nothing
            let existing = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value
            if size == nil || existing == size { return .alreadyHere(url) }
            // A different file of the same name (cameras reuse numbers): keep it, use the next name.
        }
        throw CardError.camera("Too many different files called \(name) in \(directory.path)")
    }

    /// Room that is always left free on the disk a copy goes to.
    static let spare: Int64 = 500_000_000

    static func hasRoom(free: Int64, needed: UInt64) -> Bool {
        needed <= UInt64(max(0, free - spare))
    }

    /// Throws when `directory`'s disk cannot take `needed` more bytes and still keep `spare` free.
    /// Asked before a copy starts, so that a full disk is a clear message and not a half-written file.
    static func ensureRoom(for needed: UInt64, name: String, in directory: URL) throws {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? directory.resourceValues(forKeys: keys) else { return }     // cannot tell: let the copy try
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? Int.max)
        guard hasRoom(free: free, needed: needed) else {
            let f = ByteCountFormatter()
            f.countStyle = .file
            throw CardError.camera("not enough room for \(name) on the disk of \(directory.path): it needs "
                                   + "\(f.string(fromByteCount: Int64(needed))) on top of the \(f.string(fromByteCount: spare)) "
                                   + "this app always leaves free, and \(f.string(fromByteCount: free)) is free")
        }
    }

    /// Moves the finished copy into place. Refuses if anything is there by now.
    static func finish(partial: URL, dest: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dest.path) else {
            throw CardError.camera("\(dest.lastPathComponent) appeared in \(dest.deletingLastPathComponent().path) during the copy; the new copy is kept as \(partial.lastPathComponent)")
        }
        try fm.moveItem(at: partial, to: dest)
    }
}

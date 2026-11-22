import Foundation
import GPhotoC

enum CameraError: LocalizedError {
    case failed(String)
    case busy
    case wrongMode(String)

    var errorDescription: String? {
        switch self {
        case .failed(let m): return m
        case .busy: return "Camera busy — retrying usually fixes it"
        case .wrongMode(let need): return "Needs \(need) USB mode on the camera"
        }
    }
}

/// How the open session reaches the camera.
enum CameraLink: Equatable {
    case usb
    case wifi(String)       // camera address

    var isWifi: Bool { if case .wifi = self { return true } else { return false } }
}

struct ConnectionStatus: Equatable {
    var mode: CameraMode = .disconnected
    var link: CameraLink?
    /// The Wi-Fi link is the camera's phone service ("Ctrl w/ Smartphone"),
    /// which also hands over the card.
    var phone = false
}

/// What to do with the card over the phone service.
enum CardRequest {
    case list(fresh: Bool)          // fresh = forget what earlier listings found
    case download([ClipFile])
    /// Copy the takes that are waiting: the `count` newest clips, as far as they are numbered
    /// above `after`, oldest first (see `CameraService.takes`). `everyAbove`: the app has watched
    /// the camera since `after` was noted, so every clip above it is a take of this sitting.
    case catchUp(after: Int?, count: Int, everyAbove: Bool = false)
}

enum CardEvent {
    case status(String)
    case listed([ClipFile])
    case started(ClipFile)
    case progress(ClipFile, Int64, Int64?)
    case finished(ClipFile, URL)
    case failed(ClipFile, String)
}

/// Outcome of the PTP/IP opening handshake (see zv_wifi_handshake).
enum PairingResult: Equatable {
    case paired                 // the camera knows this Mac
    case refused                // unknown Mac, camera not on its Pairing screen
    case timedOut               // on the Pairing screen, nobody confirmed
    case unreachable(Int32)     // errno
    case failed
}

/// The ONLY configs this app is ever allowed to write (by libgphoto2 widget name).
/// Anything else is refused. Never add firmware/update/delete operations here.
enum WritableConfig {
    static let allowed: Set<String> = [
        "movie", "autofocus", "manualfocus",
        "imagesize",        // Large / Medium / Small photos on the card
        "pcsaveimgsize",    // size of the copy the Mac collects after a photo: Original or 2M
        "expprogram", "shutterspeed", "f-number", "exposuremetermode",
        "exposurecompensation", "focusmode", "focalposition",
        "iso", "whitebalance", "colortemperature",
        "focusarea",
        "dro",      // D-Range Optimizer
        "d23f",     // Picture Profile (0 = off, 1…10 = PP1…PP10)
        "d240",     // Creative Style (see SettingNames.creativeStyles)
        "d21b",     // Picture Effect (32768 = off, see SettingNames.pictureEffects)
        "d25f",     // Zoom Setting (1 = optical only, 3 = Clear Image Zoom, 4 = digital zoom)
        "d210",     // White balance shift green–magenta (192 = none, a quarter step per unit)
        "d21c",     // White balance shift amber–blue (192 = none)
        "d26a",     // Live View Image Quality (1 = low, 2 = high)
        "d283",     // Function of Touch Operation (3 = touch focus, 4 = touch tracking)
        "d241",     // File Format Movie (8 = XAVC S 4K, 9 = XAVC S HD)
        "d242",     // Recording Setting Movie (frame rate and bit rate, see MovieSettings)
        "d223",     // Date/Time Setting: the camera's clock, written only by `setClock` (see CameraClock)
    ]
}

/// Native libgphoto2 backend via the GPhotoC C shim.
///
/// One persistent camera session stays open for the app's lifetime, so a
/// preview frame is a single PTP transaction instead of the CLI's
/// process-spawn + device-scan + session-setup per call.
///
/// Threading: all C calls go through one serial queue that owns the handle.
final class CameraService: @unchecked Sendable {
    static let shared = CameraService()

    /// Configs the poller reads in PC Remote mode (leaf names are what we send).
    static let controlPaths: [String] = [
        "/main/status/batterylevel",
        "/main/capturesettings/expprogram",
        "/main/capturesettings/shutterspeed",
        "/main/capturesettings/f-number",
        "/main/capturesettings/exposurecompensation",
        "/main/capturesettings/exposuremetermode",
        "/main/imgsettings/iso",
        "/main/imgsettings/whitebalance",
        "/main/imgsettings/colortemperature",
        "/main/capturesettings/focalposition",
        "/main/capturesettings/focusmode",
        "/main/capturesettings/focusarea",
        "/main/status/focusindication",
        "/main/other/d21d",     // Movie Recording State: 0 idle, 1 recording, 2 failed
        "/main/other/d24a",     // seconds of recording that still fit on the card (0 in a photo mode)
        "/main/other/d249",     // photos that still fit on the card (0 in a movie mode)
        "/main/other/d251",     // Device Overheat Status: 0 normal
        "/main/other/d25b",     // Zoom Enable Status
        "/main/other/d25c",     // Zoom Scale: 1000 = 1.0x … 2000 = 2.0x (Clear Image Zoom part)
        "/main/other/d25d",     // Zoom Bar Info: segment and position
        "/main/other/d26a",     // Live View Image Quality: 1 low (640x360), 2 high (1024x576)
        "/main/other/d241",     // File Format Movie: 8 XAVC S 4K, 9 XAVC S HD
        "/main/other/d242",     // Recording Setting Movie: frame rate and bit rate
        "/main/capturesettings/dro",
        "/main/other/d23f",     // Picture Profile
        "/main/other/d240",     // Creative Style
        "/main/other/d21b",     // Picture Effect
        "/main/other/d25f",     // Zoom Setting
        "/main/other/d210",     // White balance shift green–magenta
        "/main/other/d21c",     // White balance shift amber–blue
        "/main/other/d283",     // Function of Touch Operation: 3 touch focus, 4 touch tracking
        "/main/other/d284",     // Remote Touch Operation Enable Status
        "/main/other/d285",     // Cancel Remote Touch Operation Enable Status
    ]

    static func leaf(of path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(""))
    }

    /// The full path of a control named by its last part.
    static func path(forLeaf leaf: String) -> String {
        controlPaths.first { Self.leaf(of: $0) == leaf } ?? "/main/capturesettings/\(leaf)"
    }

    // Serial queue owning the handle below.
    private let q = DispatchQueue(label: "tether.gphoto")
    private var handle: UnsafeMutableRawPointer?
    private var capability: CameraMode = .disconnected
    private var link: CameraLink?
    /// Camera address to try when nothing answers on USB. Set once a camera
    /// was found on the network; nil = USB only.
    private var wifiTarget: String?
    /// The camera at `wifiTarget` runs its phone service rather than PC Remote.
    private var wifiPhone = false

    // While the card is being read the remote-control session is closed, and
    // nothing may reopen it. The card work has its own queue so that this
    // one keeps answering.
    private let cardQ = DispatchQueue(label: "tether.card")
    private var cardBusy = false
    private var statusBeforeCard = ConnectionStatus()
    /// Files found by earlier card listings, by the camera's handle (card queue only).
    private var knownFiles: [UInt32: CardEntry] = [:]

    // The pairing handshake waits up to a minute for a person at the camera;
    // it has its own queue so USB detection keeps running meanwhile.
    private let pairQ = DispatchQueue(label: "tether.pairing")
    private var identity: (guid: [UInt8], name: String)?

    private let ZV_OK = 0
    private let ZV_SESSION_DEAD = -9000

    // MARK: - queue bridge

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            q.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: - session lifecycle (queue thread only)

    private func ensureSession() throws -> UnsafeMutableRawPointer {
        if let h = handle { return h }
        if cardBusy { throw CameraError.busy }

        // USB first: it is the faster link, and a camera on a data cable is
        // not on Wi-Fi anyway.
        var failure: String
        do {
            let h = try open { zv_init($0) }
            adopt(h, link: .usb)
            return h
        } catch {
            failure = error.localizedDescription
        }
        if let host = wifiTarget {
            do {
                let h = try open { zv_init_wifi($0, host) }
                adopt(h, link: .wifi(host))
                if capability == .pcRemote { return h }
                // Over Wi-Fi there is nothing but PC Remote; a session without
                // its settings is unusable, and keeping it would only loop.
                teardownSession()
                failure = "Wi-Fi \(host): connected, but the camera's settings could not be read"
            } catch {
                failure = "Wi-Fi \(host): \(error.localizedDescription)"
            }
        }
        throw CameraError.failed(failure)
    }

    private func open(_ initialise: (UnsafeMutableRawPointer) -> Int32) throws -> UnsafeMutableRawPointer {
        guard let h = zv_open() else {
            throw CameraError.failed("could not allocate gphoto2 camera")
        }
        let r = initialise(h)
        if r < 0 {
            zv_close(h)
            throw CameraError.failed(Int(r) == ZV_SESSION_DEAD ? "no answer from the camera"
                                                               : String(cString: zv_err_string(r)))
        }
        return h
    }

    private func adopt(_ h: UnsafeMutableRawPointer, link: CameraLink) {
        handle = h
        self.link = link
        // Capability probe: Sony exposes "expprogram" only in PC Remote mode.
        capability = zv_has_widget(h, "expprogram") == 1 ? .pcRemote : .mtp
    }

    private func teardownSession() {
        if let h = handle { zv_close(h) }
        handle = nil
        link = nil
        capability = .disconnected
    }

    /// ZV_SESSION_DEAD means the USB link dropped — kill the session so the
    /// next call reopens cleanly (handles unplug and mode flips).
    private func check(_ r: Int) throws {
        if r >= ZV_OK { return }
        if r == ZV_SESSION_DEAD { teardownSession() }
        throw CameraError.failed(String(cString: zv_err_string(Int32(min(r, -1)))))
    }

    // MARK: - detection

    func detect() async -> ConnectionStatus {
        let status = try? await onQueue { () -> ConnectionStatus in
            if self.cardBusy { return self.statusBeforeCard }
            if let h = self.handle {
                // Cheap validation of the open session.
                if zv_has_widget(h, "expprogram") == 1 {
                    self.capability = .pcRemote
                    return self.status()
                }
                var buf = [CChar](repeating: 0, count: 4)
                let alive = zv_list_files(h, &buf, buf.count) >= 0
                if alive && self.link == .usb {     // over Wi-Fi only PC Remote exists
                    self.capability = .mtp
                    return self.status()
                }
                self.teardownSession()
            }
            do {
                _ = try self.ensureSession()
                return self.status()
            } catch {
                self.teardownSession()
                return ConnectionStatus()
            }
        }
        return status ?? ConnectionStatus()
    }

    private func status() -> ConnectionStatus {
        ConnectionStatus(mode: capability, link: link, phone: link?.isWifi == true && wifiPhone)
    }

    // MARK: - Wi-Fi

    /// Address to try whenever USB has no camera; nil switches Wi-Fi off and
    /// drops a Wi-Fi session that is open. `phone` says the camera there runs
    /// its phone service (which also hands over the card).
    func setWifiTarget(_ host: String?, phone: Bool = false) async {
        _ = try? await onQueue {
            self.wifiTarget = host
            self.wifiPhone = host != nil && phone
            if case .wifi(let current) = self.link, current != host { self.teardownSession() }
        }
    }

    /// Forgets the Wi-Fi address after a search that found nothing, unless a Wi-Fi session has
    /// opened in the meantime. (Measured after a board restart: the regular check reopened the
    /// session through the bridge while a search that had started earlier was still running; the
    /// search then ended empty, cleared the address and so closed the fresh session again.)
    func forgetWifiTargetUnlessConnected() async {
        _ = try? await onQueue {
            if self.handle != nil, self.link?.isWifi == true { return }
            self.wifiTarget = nil
            self.wifiPhone = false
        }
    }

    /// The name the camera shows on its pairing screen for this Mac.
    func wifiClientName() async -> String {
        (try? await onQueue { try self.wifiIdentity().name }) ?? ProcessInfo.processInfo.hostName
    }

    /// Queue thread only: gp_setting is not thread-safe, so the identity is
    /// read once here and reused by the pairing queue.
    private func wifiIdentity() throws -> (guid: [UInt8], name: String) {
        if let identity { return identity }
        var guid = [UInt8](repeating: 0, count: 16)
        var name = [CChar](repeating: 0, count: 256)
        guard zv_wifi_identity(&guid, &name, name.count) >= 0 else {
            throw CameraError.failed("could not read this computer's name")
        }
        let value = (guid, String(cString: name))
        identity = value
        return value
    }

    /// Asks the camera whether it knows this Mac. If the camera is on its
    /// Pairing screen this is what makes it ask for confirmation, and the call
    /// then waits (up to `wait` seconds) for someone to press OK on the camera.
    func pairingHandshake(host: String, wait: Int = 60) async -> PairingResult {
        guard let me = try? await onQueue({ try self.wifiIdentity() }) else { return .failed }
        return await withCheckedContinuation { cont in
            pairQ.async {
                var sysErrno: Int32 = 0
                let r = zv_wifi_handshake(host, me.guid, me.name, Int32(wait), &sysErrno)
                switch Int(r) {
                case ZV_PAIR_OK: cont.resume(returning: .paired)
                case ZV_PAIR_REFUSED: cont.resume(returning: .refused)
                case ZV_PAIR_TIMEOUT: cont.resume(returning: .timedOut)
                case ZV_PAIR_UNREACHABLE: cont.resume(returning: .unreachable(sysErrno))
                default: cont.resume(returning: .failed)
                }
            }
        }
    }

    // MARK: - config reads

    func readConfigs(_ paths: [String]) async throws -> [String: CameraConfig] {
        try await onQueue {
            let h = try self.ensureSession()
            var result: [String: CameraConfig] = [:]
            for path in paths {
                let name = Self.leaf(of: path)
                if let cfg = self.readConfig(h, name: name, path: path) {
                    result[path] = cfg
                    result[name] = cfg
                }
            }
            return result
        }
    }

    private func readConfig(_ h: UnsafeMutableRawPointer, name: String, path: String) -> CameraConfig? {
        var wtype: CInt = 0, ro: CInt = 0
        guard zv_widget_info(h, name, &wtype, &ro) >= 0 else { return nil }

        var current: String?
        var options: [ConfigOption] = []
        var bottom: Double?, top: Double?, step: Double?

        switch Int(wtype) {
        case ZV_WTYPE_MENU, ZV_WTYPE_RADIO, ZV_WTYPE_TEXT:
            var buf = [CChar](repeating: 0, count: 256)
            if zv_current_string(h, name, &buf, buf.count) >= 0 {
                current = String(cString: buf)
            }
            var choices = [CChar](repeating: 0, count: 1 << 16)
            if zv_choices(h, name, &choices, choices.count) >= 0 {
                let joined = String(cString: choices)
                if !joined.isEmpty {
                    for (i, line) in joined.split(separator: "\n").enumerated() {
                        options.append(ConfigOption(index: i, value: String(line)))
                    }
                }
            }
        case ZV_WTYPE_TOGGLE:
            var v: CInt = 0
            if zv_current_toggle(h, name, &v) >= 0 { current = String(v) }
        case ZV_WTYPE_RANGE:
            var mn: CFloat = 0, mx: CFloat = 0, st: CFloat = 1
            if zv_range(h, name, &mn, &mx, &st) >= 0 {
                bottom = Double(mn); top = Double(mx); step = Double(st)
            }
            var f: CFloat = 0
            if zv_current_float(h, name, &f) >= 0 { current = String(Double(f)) }
        default:
            var buf = [CChar](repeating: 0, count: 256)
            if zv_current_string(h, name, &buf, buf.count) >= 0 {
                current = String(cString: buf)
            }
        }

        let typeString: String
        switch Int(wtype) {
        case ZV_WTYPE_MENU, ZV_WTYPE_RADIO: typeString = "RADIO"
        case ZV_WTYPE_TOGGLE: typeString = "TOGGLE"
        case ZV_WTYPE_RANGE: typeString = "RANGE"
        case ZV_WTYPE_TEXT: typeString = "TEXT"
        default: typeString = "TEXT"
        }

        return CameraConfig(path: path, label: name, type: typeString, readOnly: ro != 0,
                            current: current, options: options,
                            bottom: bottom, top: top, step: step)
    }

    // MARK: - config writes

    func setConfig(_ path: String, optionIndex: Int) async throws {
        let name = Self.leaf(of: path)
        guard WritableConfig.allowed.contains(name) else {
            throw CameraError.failed("Refused to write non-whitelisted config: \(name)")
        }
        try await onQueue {
            let h = try self.ensureSession()
            try self.check(Int(zv_set_choice(h, name, Int32(optionIndex))))
        }
    }

    func setConfig(_ path: String, rangeValue: Int) async throws {
        let name = Self.leaf(of: path)
        guard WritableConfig.allowed.contains(name) else {
            throw CameraError.failed("Refused to write non-whitelisted config: \(name)")
        }
        try await onQueue {
            let h = try self.ensureSession()
            try self.check(Int(zv_set_float(h, name, CFloat(rangeValue))))
        }
    }

    /// Sets the camera's clock and time zone to `date` as this Mac counts it.
    func setClock(_ date: Date = Date(), zone: TimeZone = .current) async throws {
        guard WritableConfig.allowed.contains(CameraClock.setting) else {
            throw CameraError.failed("Refused to write non-whitelisted config: \(CameraClock.setting)")
        }
        let text = CameraClock.text(date, zone: zone)
        try await onQueue {
            let h = try self.ensureSession()
            try self.check(Int(zv_set_text(h, CameraClock.setting, text)))
        }
    }

    // MARK: - zoom (Wi-Fi only)

    /// +1 zooms in, -1 out, 0 stops; the lens keeps moving until the stop.
    /// Runs on the camera queue, i.e. between libgphoto2's own commands.
    func zoom(_ direction: Int) async throws {
        try await onQueue {
            guard self.handle != nil, case .wifi = self.link else {
                throw CameraError.failed("Zoom needs the Wi-Fi connection")
            }
            let r = zv_wifi_zoom(Int32(direction))
            if r < 0 { throw CameraError.failed("Zoom: no answer from the camera") }
            if r > 0 { throw CameraError.failed(String(format: "Zoom refused by the camera (0x%04X)", r)) }
        }
    }

    // MARK: - touch focus (Wi-Fi only)

    /// Touch focus or tracking at a point of the picture, as fractions of its
    /// width and height (0,0 = top left). The camera wants 640 × 480 units.
    func touch(x: Double, y: Double) async throws {
        try await wifiCommand("Touch focus") {
            zv_wifi_touch(Int32((min(max(x, 0), 1) * 639).rounded()), Int32((min(max(y, 0), 1) * 479).rounded()))
        }
    }

    func cancelTouch() async throws {
        try await wifiCommand("Touch focus") { zv_wifi_touch_cancel() }
    }

    private func wifiCommand(_ what: String, _ send: @escaping () -> Int32) async throws {
        try await onQueue {
            guard self.handle != nil, case .wifi = self.link else {
                throw CameraError.failed("\(what) needs the Wi-Fi connection")
            }
            var r = send()
            for _ in 0..<3 where r == 0x2019 {      // "busy": the camera is still acting on the last command
                Thread.sleep(forTimeInterval: 0.4)
                r = send()
            }
            if r < 0 { throw CameraError.failed("\(what): no answer from the camera") }
            if r == 0x2019 { throw CameraError.failed("\(what): the camera is busy; try again in a moment") }
            if r > 0 { throw CameraError.failed(String(format: "\(what) refused by the camera (0x%04X)", r)) }
        }
    }

    // MARK: - recording

    func startRecording(preferredMovieMode: String) async throws {
        try await onQueue {
            let h = try self.ensureSession()

            // Recording is blocked in Scene modes — make sure a Movie mode is active.
            var buf = [CChar](repeating: 0, count: 256)
            var cur: String?
            if zv_current_string(h, "expprogram", &buf, buf.count) >= 0 {
                cur = String(cString: buf)
            }
            if !(cur?.hasPrefix("Movie") == true && cur?.contains("S&Q") != true) {
                var choices = [CChar](repeating: 0, count: 1 << 16)
                if zv_choices(h, "expprogram", &choices, choices.count) >= 0 {
                    let opts = String(cString: choices).split(separator: "\n").map(String.init)
                    let target = opts.first { $0 == preferredMovieMode }
                        ?? opts.first { $0.hasPrefix("Movie (P)") }
                        ?? opts.first { $0.hasPrefix("Movie") }
                        ?? opts.first { $0.contains("Movie") && !$0.contains("S&Q") }
                    if let target {
                        if let idx = opts.firstIndex(of: target) {
                            try self.check(Int(zv_set_choice(h, "expprogram", Int32(idx))))
                            Thread.sleep(forTimeInterval: 0.5) // let the camera settle into the new mode
                        }
                    }
                }
            }

            // movie = TOGGLE; 1 starts, 0 stops (verified on-camera).
            try self.check(Int(zv_set_toggle(h, "movie", 1)))
        }
    }

    func stopRecording() async throws {
        try await onQueue {
            let h = try self.ensureSession()
            try self.check(Int(zv_set_toggle(h, "movie", 0)))
        }
    }

    // MARK: - photos

    /// The photo modes Take Photo can switch to.
    static let photoModes = ["P", "A", "S", "M", "Intelligent Auto"]

    /// A photo mode (P, A, S, M, the scene and auto modes), not a movie or S&Q mode.
    static func isPhotoMode(_ mode: String?) -> Bool {
        guard let mode, !mode.isEmpty else { return false }
        return !mode.hasPrefix("Movie")
    }

    /// Takes one photo and brings it to `folder` on this Mac over the control connection; the camera
    /// keeps its own copy on the card. libgphoto2 does the presses (half, full, let go; it waits up to
    /// a second for focus unless the camera is on manual focus) and fetches the photo the camera then
    /// holds for collection. A movie mode is first changed to `preferredPhotoMode`.
    /// Returns the files saved, the new photo last (any before it were left over from earlier shots).
    func takePhoto(preferredPhotoMode: String, to folder: URL) async throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await onQueue {
            let h = try self.ensureSession()
            try self.switchToPhotoMode(h, preferred: preferredPhotoMode)
            var out = [CChar](repeating: 0, count: 1 << 16)
            let r = Int(zv_capture_photo(h, folder.path, &out, out.count))
            try self.check(r)
            return String(cString: out).split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }
    }

    /// A movie mode is changed to a photo mode; a photo mode is left as it is.
    private func switchToPhotoMode(_ h: UnsafeMutableRawPointer, preferred: String) throws {
        var buf = [CChar](repeating: 0, count: 256)
        guard zv_current_string(h, "expprogram", &buf, buf.count) >= 0 else { return }
        let current = String(cString: buf)
        guard current.hasPrefix("Movie") else { return }
        var choices = [CChar](repeating: 0, count: 1 << 16)
        guard zv_choices(h, "expprogram", &choices, choices.count) >= 0 else { return }
        let opts = String(cString: choices).split(separator: "\n").map(String.init)
        guard let idx = opts.firstIndex(of: preferred) ?? opts.firstIndex(of: "P") else { return }
        try check(Int(zv_set_choice(h, "expprogram", Int32(idx))))
        Thread.sleep(forTimeInterval: 0.8)      // the camera settles into the photo mode
    }

    // MARK: - preview (persistent session: one PTP transaction per frame)

    func previewFrame() async throws -> Data {
        try await onQueue {
            let h = try self.ensureSession()
            var data: UnsafeMutablePointer<UInt8>? = nil
            var size: Int = 0
            let r = Int(zv_preview(h, &data, &size))
            if let d = data, r >= 0, size > 0 {
                defer { zv_free(d) }
                return Data(bytes: d, count: size)
            }
            try self.check(r)
            throw CameraError.failed("preview: no data")
        }
    }

    // MARK: - the card over the phone service

    /// Closes the remote-control session, opens one for the card, does what
    /// was asked and gives the camera back. The remote-control session reopens
    /// with the next `detect()` after the stream has ended.
    func card(_ request: CardRequest, root: URL, cancel: CancelFlag) -> AsyncThrowingStream<CardEvent, Error> {
        AsyncThrowingStream { continuation in
            q.async {
                guard self.handle != nil, case .wifi(let host) = self.link, self.wifiPhone, !self.cardBusy,
                      let me = try? self.wifiIdentity() else {
                    continuation.finish(throwing: CameraError.failed(
                        "The card can be read while the camera is connected by Ctrl w/ Smartphone"))
                    return
                }
                self.statusBeforeCard = self.status()
                self.teardownSession()
                self.cardBusy = true
                self.cardQ.async {
                    var failure: Error?
                    do {
                        try self.runCard(request, host: host, guid: me.guid, name: me.name, root: root, cancel: cancel) {
                            continuation.yield($0)
                        }
                    } catch {
                        failure = error
                    }
                    self.q.async {
                        self.cardBusy = false
                        continuation.finish(throwing: failure)
                    }
                }
            }
        }
    }

    /// Card queue only.
    private func runCard(_ request: CardRequest, host: String, guid: [UInt8], name: String, root: URL,
                         cancel: CancelFlag, events: (CardEvent) -> Void) throws {
        events(.status("Switching the camera to its card…"))
        var opened: PhoneCard?
        var lastError: Error = CardError.link("no connection to the camera")
        for attempt in 0..<4 where opened == nil {
            // The camera needs a moment after the other session closed; usually the first try is enough.
            Thread.sleep(forTimeInterval: attempt == 0 ? 0.4 : 0.8)
            if cancel.isSet { throw CardError.stopped }
            do { opened = try PhoneCard(host: host, guid: guid, name: name) } catch { lastError = error }
        }
        guard let card = opened else { throw lastError }
        defer {
            card.close()
            Thread.sleep(forTimeInterval: 0.4)
        }
        try Self.perform(request, on: card, known: &knownFiles, root: root, cancel: cancel, events: events)
    }

    /// Does one request on an open card session. `known` is what earlier listings found.
    ///
    /// The card's list is always asked for first. The camera needs that: until it has been asked for
    /// the list in a session it answers "describe this file" with an empty description (measured,
    /// FINDINGS §12g). It also means every file is matched against the card as it is now.
    static func perform(_ request: CardRequest, on card: PhoneCard, known: inout [UInt32: CardEntry], root: URL,
                        cancel: CancelFlag, events: (CardEvent) -> Void) throws {
        if case .list(true) = request { known.removeAll() }
        events(.status("Reading the card…"))
        let entries = try card.list(known: &known, progress: { done, total in
            events(.status("Reading the card… \(done) of \(total) new files"))
        }, cancel: cancel)
        let onCard = clips(from: entries)
        events(.listed(onCard))

        var wanted: [ClipFile] = []
        switch request {
        case .list:
            return
        case .download(let asked):
            for want in asked {
                if let now = onCard.first(where: { $0.folder == want.folder && $0.name == want.name && $0.sizeBytes == want.sizeBytes }) {
                    wanted.append(now)
                } else {
                    events(.failed(want, "it is no longer on the card as listed; the list has been refreshed"))
                }
            }
        case .catchUp(let after, let count, let everyAbove):
            wanted = takes(after: after, count: count, everyAbove: everyAbove, from: onCard)
        }

        for clip in wanted {
            if cancel.isSet { throw CardError.stopped }
            events(.started(clip))
            do {
                guard let handle = clip.cameraHandle, let entry = known[handle] else { throw CardError.changed }
                // The link reports every packet, hundreds a second; the window needs a few. Passing all
                // of them on made the window fall behind the copy (measured: half an hour on a long job).
                var lastSent = Date.distantPast
                let url = try card.download(entry, to: root.appendingPathComponent(clip.dayFolder, isDirectory: true),
                                            progress: { done, total in
                    let now = Date()
                    guard done == total || now.timeIntervalSince(lastSent) >= Self.progressInterval else { return }
                    lastSent = now
                    events(.progress(clip, done, total))
                }, cancel: cancel)
                events(.finished(clip, url))
            } catch CardError.camera(let why) {
                events(.failed(clip, why))          // this file only; the session is still good
            } catch CardError.changed {
                known.removeAll()
                events(.failed(clip, CardError.changed.localizedDescription))
            }
        }
    }

    /// The shortest time between two progress reports of one copy.
    static let progressInterval: TimeInterval = 0.3

    /// The number in a clip's name: C0192.MP4 → 192.
    static func clipNumber(_ name: String) -> Int? {
        Int((name as NSString).deletingPathExtension.filter(\.isNumber))
    }

    /// The highest clip number among the videos, for remembering how far the card had got.
    static func highestClipNumber(_ clips: [ClipFile]) -> Int? {
        clips.filter(\.isVideo).compactMap { clipNumber($0.name) }.max()
    }

    /// The takes to copy now, oldest first: the `count` newest videos, and of those only the ones
    /// numbered above `after` (the highest number the card held before these takes). With no
    /// `after`, or when the camera has started its numbering again, the newest `count` are taken.
    /// With `everyAbove`, every video numbered above `after` is taken however many that is: the
    /// camera can stop and start again between two readings of its state (seen 21 Nov 2026: one
    /// stop seen, two files made), and the count then falls short.
    static func takes(after: Int?, count: Int, everyAbove: Bool = false, from clips: [ClipFile]) -> [ClipFile] {
        let videos = clips.filter(\.isVideo)
            .compactMap { clip in clipNumber(clip.name).map { (number: $0, clip: clip) } }
            .sorted { ($0.number, $0.clip.unixTime) < ($1.number, $1.clip.unixTime) }
        guard count > 0, let last = videos.last else { return [] }
        if everyAbove, let after, last.number >= after { return videos.filter { $0.number > after }.map(\.clip) }
        var newest = Array(videos.suffix(count))
        if let after, last.number >= after { newest = newest.filter { $0.number > after } }
        return newest.map(\.clip)
    }

    /// Clips and stills among the card's files, newest first.
    static func clips(from entries: [CardEntry]) -> [ClipFile] {
        let kinds: [String: String] = ["mp4": "video/mp4", "mov": "video/mp4", "mxf": "video/mp4", "mts": "video/mp4",
                                       "jpg": "image/jpeg", "jpeg": "image/jpeg", "hif": "image/heif",
                                       "arw": "image/x-sony-arw"]
        return entries.compactMap { entry -> ClipFile? in
            guard let mime = kinds[(entry.name as NSString).pathExtension.lowercased()] else { return nil }
            return ClipFile(number: 0, folder: entry.folder, name: entry.name, sizeBytes: entry.size ?? 0,
                            width: nil, height: nil, mime: mime, unixTime: entry.unixTime, cameraHandle: entry.handle)
        }
        .sorted { ($0.unixTime, $0.name) > ($1.unixTime, $1.name) }
    }

    /// The clip with the highest file number; the camera's clock may be unset,
    /// so the time only breaks ties.
    static func newestVideo(_ clips: [ClipFile]) -> ClipFile? {
        takes(after: nil, count: 1, from: clips).first
    }

    // MARK: - files (MTP mode)

    func listFiles() async throws -> [ClipFile] {
        try await onQueue {
            let h = try self.ensureSession()
            var buf = [CChar](repeating: 0, count: 1 << 22) // 4 MiB listing buffer
            try self.check(Int(zv_list_files(h, &buf, buf.count)))

            var clips: [ClipFile] = []
            let text = String(cString: buf)
            for (i, line) in text.split(separator: "\n").enumerated() {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4 else { continue }
                let folder = parts[0], name = parts[1]
                let size = UInt64(parts[2]) ?? 0
                let mtime = Int64(parts[3]) ?? 0
                clips.append(ClipFile(number: i + 1, folder: folder, name: name,
                                      sizeBytes: size, width: nil, height: nil,
                                      mime: self.mime(forExtension: name), unixTime: mtime))
            }
            clips.sort { $0.unixTime > $1.unixTime }
            return clips
        }
    }

    private func mime(forExtension name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi": return "video/mp4"
        case "jpg", "jpeg": return "image/jpeg"
        case "arw": return "image/x-sony-arw"
        default: return "application/octet-stream"
        }
    }

    /// Streamed download straight to disk (fd-based inside the shim).
    func download(_ clip: ClipFile, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(clip.name)

        try await onQueue {
            let h = try self.ensureSession()
            try self.check(Int(zv_download(h, clip.folder, clip.name, dest.path)))
        }

        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw CameraError.failed("download finished but file missing: \(dest.path)")
        }
        return dest
    }
}

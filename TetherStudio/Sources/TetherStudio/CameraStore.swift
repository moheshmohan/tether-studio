import SwiftUI
import Combine

/// Single source of truth for the UI. Owns polling, preview loop, and download state.
@MainActor
final class CameraStore: ObservableObject {
    // connection & camera state
    @Published var mode: CameraMode = .disconnected
    @Published var link: CameraLink?
    /// The Wi-Fi link is the camera's phone service: it controls the camera and hands over the card.
    @Published var phoneControl = false

    // The ESP32 board that joins the camera's own Wi-Fi for this Mac
    @Published var bridge: BridgeState = .off {
        didSet {
            // The signal strength changes all the time; log only real changes.
            if case .joined = bridge, case .joined = oldValue { return }
            if bridge != oldValue { debugLog("bridge \(bridge)") }
        }
    }
    @Published var bridgeSettings = BridgeSettings.load() {
        didSet {
            guard bridgeSettings != oldValue else { return }
            bridgeSettings.save()
            retryWifi()
        }
    }
    private var bridgeTask: Task<Void, Never>?

    // The card over the phone service
    @Published var cardActivity: CardActivity?
    /// The card's file list has been read since connecting.
    @Published var cameraClipsLoaded = false
    @Published var autoCopy = UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCopy, forKey: "autoCopy") }
    }
    private var cardCancel: CancelFlag?
    /// Takes recorded over this connection that have not been copied yet. Kept across
    /// restarts, so a copy that was stopped, failed or skipped is made up for later.
    @Published var pendingTakes = UserDefaults.standard.integer(forKey: "pendingTakes") {
        didSet { UserDefaults.standard.set(pendingTakes, forKey: "pendingTakes") }
    }
    /// The highest clip number the card held when no take was waiting: takes to copy are numbered above it.
    private var copyFrom: Int? = UserDefaults.standard.object(forKey: "copyFromNumber") as? Int {
        didSet { UserDefaults.standard.set(copyFrom, forKey: "copyFromNumber") }
    }
    private var catchUpRunning = false
    /// The app has stayed connected since `copyFrom` was noted: every clip numbered above it was
    /// recorded while the app watched, including takes whose stop fell between two readings.
    private var watchedSinceMark = false
    private var catchUpFailures = 0
    private var highestListed: Int?
    private var rateMark: (time: Date, bytes: Int64)?
    /// Bytes of the file being copied; kept out of `cardActivity` so that a tick redraws one row only.
    let copyProgress = CopyProgress()

    // Wi-Fi
    @Published var wifi: WifiState = .searching {
        didSet { if wifi != oldValue { debugLog("wifi \(wifi)") } }
    }
    @Published var wifiClientName = ""
    @Published var wifiEnabled = UserDefaults.standard.object(forKey: "wifiEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(wifiEnabled, forKey: "wifiEnabled")
            wifiSettingsChanged()
        }
    }
    /// Optional fixed camera address; empty = find the camera automatically.
    @Published var wifiManualHost = UserDefaults.standard.string(forKey: "wifiManualHost") ?? "" {
        didSet { UserDefaults.standard.set(wifiManualHost, forKey: "wifiManualHost") }
    }
    @Published var snapshot = CameraSnapshot()
    @Published var configs: [String: CameraConfig] = [:]
    @Published var lastError: String? {
        didSet {
            // A message stays until it is closed, replaced, or 20 s old.
            errorToken += 1
            guard lastError != nil else { return }
            let token = errorToken
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                if let self, self.errorToken == token { self.lastError = nil }
            }
        }
    }
    private var errorToken = 0
    @Published var busyMessage: String?

    // the camera's clock
    /// Set the camera's date, time and time zone from this Mac each time the camera connects.
    @Published var clockSync = UserDefaults.standard.object(forKey: "clockSync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(clockSync, forKey: "clockSync")
            if clockSync && mode == .pcRemote { clockPending = true }
        }
    }
    /// When the camera last took the clock in this run of the app.
    @Published private(set) var clockSetAt: Date?
    /// A connection has been made and the clock has not been sent over it yet.
    private var clockPending = false

    // ready check
    /// Free room on the disk of the download folder, to the nearest 100 MB (a finer value would
    /// redraw the window with every file the Mac writes anywhere).
    @Published private(set) var macFreeBytes: Int64?

    /// What would spoil or cut short the next take; worst first.
    var readyIssues: [ReadyIssue] {
        guard mode == .pcRemote else { return [] }
        return ReadyCheck.issues(snapshot: snapshot, configs: configs, preferredMovieMode: preferredMovieMode,
                                 autoCopy: phoneControl && autoCopy, macFree: macFreeBytes)
    }

    // presets
    /// The preset sent to the camera by itself when the camera connects; nil = none.
    @Published var startupPresetID: String? = UserDefaults.standard.string(forKey: "startupPreset") {
        didSet { UserDefaults.standard.set(startupPresetID, forKey: "startupPreset") }
    }
    /// A connection has been made after a long gap and the startup preset has not been sent yet.
    private var startupPending = false
    /// Since when the camera has been gone; the start of the app counts as "gone for long".
    private var disconnectedSince: Date? = .distantPast
    /// A connection that returns sooner than this is the same sitting (the link dropped for a
    /// moment): what was set by hand since the startup preset is kept.
    static let startupGap: TimeInterval = 60

    /// The user's own presets (the ready-made ones are `Preset.builtIns`).
    @Published private(set) var presetLibrary = PresetLibrary.load()
    /// The preset being sent to the camera right now.
    @Published private(set) var applyingPreset: String?
    /// What the last preset did; stays for a minute or until the next one.
    @Published var presetOutcome: PresetOutcome? {
        didSet {
            outcomeToken += 1
            guard presetOutcome != nil else { return }
            let token = outcomeToken
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if let self, self.outcomeToken == token { self.presetOutcome = nil }
            }
        }
    }
    private var outcomeToken = 0
    /// Values just sent to the camera, shown at once. The camera reports a change one to two seconds
    /// late (measured), and a read in between still carries the old value; without this a control
    /// jumped back to the old value and then forward again.
    private var pendingValues: [String: (value: String, until: Date)] = [:]
    /// Record was pressed during a copy: the copy is being stopped, recording starts when the camera is back.
    private var recordAfterCard = false

    // recording
    @Published var isRecording = false
    @Published var recordingStarted: Date?
    @Published var preferredMovieMode = UserDefaults.standard.string(forKey: "preferredMovieMode") ?? "Movie (M)" {
        didSet { UserDefaults.standard.set(preferredMovieMode, forKey: "preferredMovieMode") }
    }

    /// When the app last pressed record or stop: the camera's own state
    /// follows a few seconds later and is not compared before that.
    private var recordCommandAt: Date?
    private var awaitingStart = false

    // stop alert
    /// A recording that ended without Stop being pressed here; shown until closed or the next take.
    @Published var stopAlert: StopAlert? {
        didSet {
            alertToken += 1
            guard let alert = stopAlert, alert.kind == .kept else { return }
            let token = alertToken
            Task { [weak self] in        // good news needs no closing by hand
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if let self, self.alertToken == token { self.stopAlert = nil }
            }
        }
    }
    private var alertToken = 0
    /// Sound, Dock icon and notification with the banner. The banner itself is always shown.
    @Published var stopAlertSound = UserDefaults.standard.object(forKey: "stopAlertSound") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(stopAlertSound, forKey: "stopAlertSound")
            if stopAlertSound { StopAlerter.shared.prepare(log: { [weak self] in self?.debugLog($0) }) }
        }
    }
    // photos and timelapse
    /// The photo mode Take Photo and a timelapse switch to when a movie mode is on.
    @Published var preferredPhotoMode = UserDefaults.standard.string(forKey: "preferredPhotoMode") ?? "P" {
        didSet { UserDefaults.standard.set(preferredPhotoMode, forKey: "preferredPhotoMode") }
    }
    /// The last photo brought to this Mac.
    @Published private(set) var lastPhoto: URL?
    @Published var timelapsePlan = TimelapsePlan.load() {
        didSet { timelapsePlan.save() }
    }
    /// The timelapse running, or the last one, until its banner is closed.
    @Published var timelapse: TimelapseStatus?
    private var timelapseTask: Task<Void, Never>?
    /// A photo is being taken: no live view frame may be queued in front of it.
    private var photoInFlight = false {
        didSet { updatePreviewGate() }
    }
    private var timelapseRunning: Bool { timelapse?.running == true }

    // erasing the card
    /// An erase shown for confirmation; the sheet asks for `CardWipe.confirmWord`.
    @Published var wipePlan: CardWipe.Plan?
    /// The board set-up sheet, while open.
    @Published var boardSetup: BoardSetup?
    /// The board's port is being written: the bridge keeps off it.
    private var boardFlashing = false
    @Published private(set) var wiping = false
    /// How the last erase went, shown once.
    @Published var wipeOutcome: String?

    /// The connection went while recording: when that take started. The first reading after the
    /// connection is back says whether it is still going (the timer then goes on from here).
    private var lostRecordingStart: Date?
    /// When Stop was pressed in the app: a stop, or a lost connection, right after that is expected.
    private var stopAskedAt: Date?

    // zoom (Wi-Fi only)
    @Published var zoomPosition: ZoomPosition?
    @Published var zoomDirection = 0

    // preview
    /// The picture and its frame rate; not published here, so that a frame redraws the picture only.
    let preview = PreviewFeed()
    @Published var lastPreviewError: String?
    @Published var previewEnabled = true {
        didSet { UserDefaults.standard.set(previewEnabled, forKey: "previewEnabled") }
    }

    // files
    @Published var clipSource: ClipSource?
    private var clipsLoadedFor: ClipSource?
    @Published var clips: [ClipFile] = [] {
        didSet { refreshOnMac() }
    }
    @Published var downloadStates: [String: DownloadPhase] = [:]
    @Published var downloadRoot: URL {
        didSet { refreshOnMac() }
    }
    /// Clips of the list that are in the download folder with the size the card gives, and where.
    /// Looked up on the disk, so a copy made earlier, by another tool, or deleted since is seen as it is.
    @Published private(set) var onMac: [String: URL] = [:]
    /// The card's list as last read over the phone service, kept so that it is back at once after a
    /// reconnect (reading it again interrupts live view). Every copy still checks the card first.
    private var lastCameraClips: [ClipFile] = []
    @Published private(set) var cameraClipsReadAt: Date?

    private let service = CameraService.shared
    /// Keeps macOS from slowing the app down ("App Nap") while its window is behind others:
    /// the live monitor and a running copy must keep their pace there too.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "Camera live view and clip copies")
    private var pollTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var wasConnectedPCRemote = false
    private var wifiTask: Task<Void, Never>?
    private var wifiGeneration = 0
    /// Address that refused this Mac last time: go straight to the pairing
    /// handshake there instead of knocking twice per round.
    private var pairingPending: WifiCamera?
    /// The address-by-address scan is the noisy fallback: at most this often.
    private var lastScan = Date.distantPast
    private let scanInterval: TimeInterval = 20
    private var previewFrameCount = 0

    init() {
        let defaultRoot = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZV-E10", isDirectory: true)
        if let saved = UserDefaults.standard.string(forKey: "downloadRoot") {
            downloadRoot = URL(fileURLWithPath: saved)
        } else {
            downloadRoot = defaultRoot
            UserDefaults.standard.set(defaultRoot.path, forKey: "downloadRoot")
        }
        previewEnabled = UserDefaults.standard.object(forKey: "previewEnabled") as? Bool ?? true
        if !wifiEnabled { wifi = .off }
        if let cache = ClipListCache.load() {
            lastCameraClips = cache.clips
            cameraClipsReadAt = cache.readAt
        }
        Task { [weak self] in
            let name = await CameraService.shared.wifiClientName()
            self?.wifiClientName = name
        }
        startPolling()
        startBridgeLoop()
        if stopAlertSound { StopAlerter.shared.prepare(log: { [weak self] in self?.debugLog($0) }) }
        if mcpEnabled { startMcp() }
    }

    // MARK: - MCP

    /// The MCP server that gives a language model the window's options (see McpServer, McpTools).
    @Published var mcpEnabled = UserDefaults.standard.object(forKey: "mcpEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(mcpEnabled, forKey: "mcpEnabled")
            if mcpEnabled { startMcp() } else { McpServer.shared.stop(); debugLog("MCP server stopped") }
        }
    }

    private func startMcp() {
        let server = McpServer.shared
        server.log = { [weak self] line in Task { @MainActor in self?.debugLog(line) } }
        let listing = McpTools.listing()
        server.tools = { listing }
        server.handler = { [weak self] name, args in
            guard let self else { return .failure("The app is closing") }
            return await McpTools.call(name, args, store: self)
        }
        let port = UInt16(UserDefaults.standard.integer(forKey: "mcpPort"))
        server.start(port: port > 1023 ? port : McpServer.defaultPort)
    }

    /// The command that adds this server to Claude Code, with its token.
    var mcpSetupCommand: String {
        "claude mcp add --transport http tether-studio \(McpServer.shared.url) --header \"Authorization: Bearer \(McpServer.token())\""
    }

    func copyMcpSetupCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mcpSetupCommand, forType: .string)
    }

    deinit {
        pollTask?.cancel()
        previewTask?.cancel()
        wifiTask?.cancel()
        bridgeTask?.cancel()
    }

    // MARK: - the ESP32 bridge to the camera's own Wi-Fi

    private func startBridgeLoop() {
        bridgeTask?.cancel()
        bridgeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.boardFlashing {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                let settings = self.bridgeSettings
                if settings.usable, self.bridge == .off { self.bridge = .joining(settings.network) }
                let state = await Task.detached { BridgeController.shared.step(settings) }.value
                let wasJoined = self.bridge.isJoined
                if state != self.bridge { self.bridge = state }
                if state.isJoined && !wasJoined {
                    // The camera is reachable through the board from this moment: connect now,
                    // not when a search that started earlier has run out.
                    self.restartWifiAttempt()
                } else if !state.isJoined && wasJoined, self.link == .wifi(BridgeController.localHost), self.cardActivity == nil {
                    // The board lost the camera (restarted, unplugged, camera off): the session is
                    // gone, so say so now instead of after the camera library's timeouts.
                    await self.service.setWifiTarget(nil)
                    await self.pollOnce()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - polling

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        startPreviewLoop()
    }

    private func pollOnce() async {
        if cardActivity != nil { return }       // the camera is busy with its card; nothing else may talk to it
        let status = await service.detect()
        await apply(status)
        let m = status.mode
        if m == .disconnected { startWifiAttempt() }

        if m == .pcRemote {
            wasConnectedPCRemote = true
            if applyingPreset == nil {      // a preset reads the controls itself, one by one
                do {
                    let cfgs = try await service.readConfigs(CameraService.controlPaths)
                    if !cfgs.isEmpty {
                        let shown = withPending(cfgs)
                        if shown != configs { configs = shown }
                        readStatus(from: cfgs)
                    }
                } catch {
                    debugLog("configs error: \(error.localizedDescription)")
                }
            }
        }

        if m == .pcRemote, clockPending, clockSync, !isRecording, busyMessage == nil, applyingPreset == nil, !timelapseRunning,
           configs["d21d"]?.current == "0" {
            clockPending = false
            await sendClock(asked: false)
        }

        if m == .pcRemote, startupPending, let recording = configs["d21d"]?.current {
            if recording != "0" {
                startupPending = false      // someone is recording with it: leave the camera as it is
            } else if presetsAvailable {
                startupPending = false
                if let preset = allPresets.first(where: { $0.id == startupPresetID }) {
                    if preset.matches(configs) {
                        debugLog("startup preset \(preset.name): the camera is set like this already")
                    } else {
                        debugLog("startup preset \(preset.name): applying")
                        applyPreset(preset, onConnect: true)
                    }
                }
            }
        }
        refreshMacFree()

        // Where clips can be read from right now: MTP, or the card mounted as a disk.
        let disk = await Task.detached { CardVolume.find() }.value
        guard cardActivity == nil else { return }
        let source: ClipSource? = m == .mtp ? .mtp
            : disk.map { .disk($0) } ?? (m == .pcRemote && status.phone ? .camera : nil)
        if source != clipSource {
            debugLog("clip source \(String(describing: source))")
            clipSource = source
        }
        if source != clipsLoadedFor {
            clipsLoadedFor = source
            if source == .camera {
                // Reading the card interrupts remote control, so it waits to be asked for;
                // until then the list read earlier in this run of the app is shown.
                clips = lastCameraClips
                cameraClipsLoaded = !lastCameraClips.isEmpty
            } else {
                await refreshClips()
            }
        }
    }

    /// Battery, card, heat, zoom position and the camera's own recording state.
    private func readStatus(from cfgs: [String: CameraConfig]) {
        var now = snapshot
        now.batteryPercent = parseBattery(cfgs["batterylevel"]?.current)
        now.remainingSeconds = cfgs["d24a"]?.currentValueDouble.map { Int($0) }
        now.photosLeft = cfgs["d249"]?.currentValueDouble.map { Int($0) }
        now.photoMode = CameraService.isPhotoMode(cfgs["expprogram"]?.current)
        now.overheating = (cfgs["d251"]?.current ?? "0") != "0"
        if now != snapshot { snapshot = now }
        if zoomDirection == 0 || zoomPosition == nil {
            let zoom = ZoomPosition(bar: cfgs["d25d"]?.current, scale: cfgs["d25c"]?.current)
            if zoom != zoomPosition { zoomPosition = zoom }
        }
        syncRecording(with: cfgs["d21d"]?.current)
    }

    /// The camera's recording state (0 idle, 1 recording, 2 failed) is the
    /// truth: it also changes when the button on the camera is pressed, when
    /// the card fills up, or when a start was refused.
    private func syncRecording(with state: String?) {
        guard let state, busyMessage == nil else { return }
        if let at = recordCommandAt, Date().timeIntervalSince(at) < 6 { return }
        let onCamera = state == "1"
        if awaitingStart {
            awaitingStart = false
            if !onCamera {
                isRecording = false
                recordingStarted = nil
                lastError = state == "2"
                    ? "The camera reports that recording failed"
                    : "The camera did not start recording. Check the card and that the camera is not in a menu or playback."
                return
            }
        }
        if let start = lostRecordingStart {
            // The first reading since the connection came back after dropping mid-take.
            lostRecordingStart = nil
            if onCamera {
                isRecording = true
                recordingStarted = start
                debugLog("the camera kept recording while the connection was gone")
                raise(.kept, length: Date().timeIntervalSince(start))
            } else {
                debugLog("the recording ended while the connection was gone")
                raise(.endedWhileAway, length: nil)
                takeFinished()
            }
            return
        }
        if onCamera && !isRecording {
            isRecording = true
            recordingStarted = Date()       // started with the camera's own button
            if stopAlert?.kind != .kept { stopAlert = nil }
            debugLog("the camera is recording (started on the camera itself)")
        } else if !onCamera && isRecording {
            let length = recordingStarted.map { Date().timeIntervalSince($0) }
            isRecording = false
            recordingStarted = nil          // stopped on the camera, or the card is full
            let cause = StopAlert.cause(state: state, snapshot: snapshot)
            debugLog("the camera stopped recording by itself (state \(state), cause \(cause))")
            raise(cause, length: length)
            takeFinished()
        }
    }

    /// Shows a stop alert in the window and, unless turned off, makes it heard.
    private func raise(_ kind: StopAlert.Kind, length: TimeInterval?, lastBattery: Int? = nil) {
        let alert = StopAlert(kind: kind, at: Date(), length: length, lastBattery: lastBattery ?? snapshot.batteryPercent)
        stopAlert = alert
        if stopAlertSound { StopAlerter.shared.announce(alert, log: { [weak self] in self?.debugLog($0) }) }
    }

    /// Plays the alert with a made-up stop, to hear it and to let macOS ask about notifications.
    func tryStopAlert() {
        let alert = StopAlert(kind: .cardFull, at: Date(), length: 754, lastBattery: snapshot.batteryPercent)
        stopAlert = alert
        StopAlerter.shared.announce(alert, log: { [weak self] in self?.debugLog($0) })
    }

    /// Takes over a connection status from the service: mode changes, which
    /// link carries the session, and the one-off reads after connecting.
    private func apply(_ status: ConnectionStatus) async {
        let m = status.mode
        // Assigning an unchanged value would still redraw the window, every two seconds.
        if link != status.link { link = status.link }
        if phoneControl != status.phone { phoneControl = status.phone }
        switch status.link {
        case .wifi(let host):
            if wifi != .connected(host) { wifi = .connected(host) }
            pairingPending = nil
            if host != BridgeController.localHost { UserDefaults.standard.set(host, forKey: "wifiLastHost") }
        case .usb:
            let now: WifiState = wifiEnabled ? .idle : .off
            if wifi != now { wifi = now }
        case nil:
            if case .connected = wifi { wifi = .searching }
            if wifi == .idle { wifi = .searching }
        }
        guard m != mode else { return }

        debugLog("mode \(mode) → \(m) link \(String(describing: status.link))")
        let wasPCRemote = (mode == .pcRemote)
        withAnimation { mode = m }
        if m == .disconnected {
            if disconnectedSince == nil { disconnectedSince = Date() }
            watchedSinceMark = false        // clips may be made on the camera meanwhile
            preview.image = nil
            preview.fps = 0
            zoomPosition = nil
            zoomDirection = 0
            configs = [:]
            let lastBattery = snapshot.batteryPercent
            snapshot = CameraSnapshot()
            if isRecording {
                let start = recordingStarted
                isRecording = false
                recordingStarted = nil
                if let asked = stopAskedAt, Date().timeIntervalSince(asked) < 20 {
                    debugLog("the connection went right after Stop was pressed")
                } else {
                    lostRecordingStart = start ?? Date()
                    debugLog("the connection went while recording (battery last \(lastBattery.map(String.init) ?? "?") %)")
                    raise(.linkLost, length: start.map { Date().timeIntervalSince($0) }, lastBattery: lastBattery)
                }
            }
        }
        if m == .pcRemote && !wasPCRemote {
            clockPending = true         // sent by the regular check, once the camera is idle
            if let since = disconnectedSince, Date().timeIntervalSince(since) >= Self.startupGap { startupPending = true }
            disconnectedSince = nil
            // one-shot identity read (static values, not worth polling)
            if let ids = try? await service.readConfigs(["/main/status/cameramodel", "/main/status/deviceversion"]) {
                snapshot.model = ids["cameramodel"]?.current ?? "ZV-E10"
                snapshot.firmware = ids["deviceversion"]?.current ?? snapshot.firmware
            }
        }
    }

    // MARK: - Wi-Fi: find the camera, pair if needed, connect

    private func startWifiAttempt() {
        guard wifiEnabled, wifiTask == nil else { return }
        wifiGeneration += 1
        let generation = wifiGeneration
        wifiTask = Task { [weak self] in
            await self?.wifiAttempt()
            if self?.wifiGeneration == generation { self?.wifiTask = nil }
        }
    }

    /// Drops a search that is under way and starts a fresh one.
    private func restartWifiAttempt() {
        wifiTask?.cancel()
        wifiTask = nil
        pairingPending = nil
        lastScan = .distantPast
        guard mode == .disconnected, wifiEnabled else { return }
        wifi = .searching
        startWifiAttempt()
    }

    private func wifiSettingsChanged() {
        wifiTask?.cancel()
        pairingPending = nil
        if wifiEnabled {
            if mode == .disconnected { wifi = .searching }
        } else {
            wifi = .off
            Task { await service.setWifiTarget(nil) }
        }
    }

    /// Called from the address field: forget what was learnt and look again.
    func retryWifi() {
        pairingPending = nil
        lastScan = .distantPast
        if mode == .disconnected, wifiEnabled { wifi = .searching }
    }

    private func wifiAttempt() async {
        // 1. Where is the camera? (Skipped while one is waiting to be paired:
        //    then the only question is whether its Pairing screen is open yet.)
        var camera = pairingPending
        if camera == nil {
            let typed = wifiManualHost.trimmingCharacters(in: .whitespaces)
            let remembered = UserDefaults.standard.string(forKey: "wifiLastHost")
            let allowScan = Date().timeIntervalSince(lastScan) >= scanInterval
            if allowScan && typed.isEmpty { lastScan = Date() }
            let bridgeUp = bridge.isJoined
            let found = await Task.detached { () -> (camera: WifiCamera?, blocked: Bool) in
                if !typed.isEmpty {
                    let p = WifiDiscovery.probe(host: typed)
                    return (p.camera, p.sysErrno == EHOSTUNREACH)
                }
                // The board on USB has joined the camera's own network: the camera is behind it.
                if bridgeUp, let camera = WifiDiscovery.probe(host: BridgeController.localHost).camera,
                   !camera.model.isEmpty || camera.service != .unknown {
                    return (camera, false)
                }
                let result = WifiDiscovery.find(remembered: remembered, allowScan: allowScan)
                let camera = result.cameras.first(where: { $0.service != .smartphone }) ?? result.cameras.first
                return (camera, camera == nil && result.looksBlocked)
            }.value
            guard !Task.isCancelled, wifiEnabled, mode == .disconnected else { return }

            guard let hit = found.camera else {
                await service.forgetWifiTargetUnlessConnected()
                let status = await service.detect()
                if status.mode != .disconnected {       // connected meanwhile, by the regular check
                    await apply(status)
                    return
                }
                wifi = found.blocked ? .blocked
                    : typed.isEmpty ? .notFound : .failed("Nothing answers at \(typed)")
                return
            }
            if hit.host != BridgeController.localHost { UserDefaults.standard.set(hit.host, forKey: "wifiLastHost") }
            camera = hit

            // 2. If the camera already knows this Mac the session just opens. (Its
            //    phone service, "Ctrl w/ Smartphone", asks for no pairing at all.)
            wifi = .connecting(hit)
            if await openWifiSession(hit, attempts: hit.service == .smartphone ? 2 : 1) { return }
            if hit.service == .smartphone {
                // The phone service has no pairing. A session that does not open means the camera is
                // not ready yet (it has just lost its last session); the next round tries again.
                // (Before, this fell through to the pairing handshake and stayed on "Confirm on the
                // camera" for good: seen on 19 Nov 2026 after the board link had been disturbed.)
                debugLog("phone service: the session did not open, trying again on the next round")
                wifi = .failed("The camera is there but has not opened the connection yet. Trying again…")
                return
            }
        }
        guard let camera else { return }

        // 3. It does not: run the pairing handshake. While that waits, nothing
        //    else may knock on the camera, so the service gets no Wi-Fi target.
        await service.setWifiTarget(nil)
        let hint = Task { [weak self] in
            // An answer held this long means the camera is showing its
            // confirmation prompt (a refusal comes back at once).
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { self?.wifi = .confirmOnCamera(camera) }
        }
        let result = await service.pairingHandshake(host: camera.host)
        hint.cancel()
        debugLog("pairing handshake \(camera.host): \(result)")
        guard wifiEnabled, mode == .disconnected else { return }

        switch result {
        case .paired:
            pairingPending = nil
            wifi = .connecting(camera)
            if await openWifiSession(camera, attempts: 4) { return }
            wifi = .failed("The camera accepted this Mac, but the session did not open. Trying again…")
        case .refused, .timedOut:
            pairingPending = camera
            wifi = .needsPairing(camera)
        case .unreachable(let code):
            pairingPending = nil            // gone (switched off, cable plugged in): look for it again
            wifi = code == EHOSTUNREACH ? .blocked : .searching
        case .failed:
            pairingPending = nil
            wifi = .failed("The camera at \(camera.host) gave an unexpected answer. Trying again…")
        }
    }

    private func openWifiSession(_ camera: WifiCamera, attempts: Int) async -> Bool {
        await service.setWifiTarget(camera.host, phone: camera.service == .smartphone)
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            let status = await service.detect()
            if status.mode != .disconnected {
                await apply(status)
                return true
            }
        }
        await service.setWifiTarget(nil)
        return false
    }

    private func parseBattery(_ s: String?) -> Int? {
        guard let s else { return nil }
        let digits = s.prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - preview loop (native backend: each frame is one PTP transaction)

    /// What the live view loop may do right now. It runs off the main thread,
    /// so it reads this instead of the published state.
    private final class PreviewGate: @unchecked Sendable {
        enum State { case paused, holding, running }
        private let lock = NSLock()
        private var state = State.paused
        private var undelivered = 0

        var current: State {
            lock.lock(); defer { lock.unlock() }
            return state
        }

        func set(_ new: State) {
            lock.lock()
            state = new
            lock.unlock()
        }

        /// False while the window still has an earlier frame to show: that frame is then skipped.
        func claimDelivery() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if undelivered > 0 { return false }
            undelivered += 1
            return true
        }

        func delivered() {
            lock.lock()
            undelivered = 0
            lock.unlock()
        }
    }

    private let previewGate = PreviewGate()
    /// The zoom button was released, but the stop command has not reached the camera yet.
    private var zoomStopPending = false
    private var gateWatch: AnyCancellable?

    private func updatePreviewGate() {
        if !previewEnabled || mode != .pcRemote || isRecordingBusy || photoInFlight || cardActivity != nil {
            previewGate.set(.paused)
        } else if zoomDirection != 0 || zoomStopPending {
            // While a zoom button is held no frame is requested: the camera takes
            // up to 3 s to deliver one during a zoom (measured), and the stop
            // command would have to wait behind it and overshoot.
            previewGate.set(.holding)
        } else {
            previewGate.set(.running)
        }
    }

    /// Frames are fetched and decoded off the main thread, back to back; the
    /// window is handed each one without the loop waiting for it to be drawn
    /// (that wait cost a third of the frame rate). Other commands still get
    /// their turn, because every frame is a separate job on the camera queue.
    private func startPreviewLoop() {
        previewTask?.cancel()
        gateWatch = objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.updatePreviewGate() }
        updatePreviewGate()
        let gate = previewGate
        let service = self.service
        previewTask = Task.detached(priority: .userInitiated) { [weak self] in
            var failures = 0        // in a row
            while !Task.isCancelled {
                switch gate.current {
                case .paused:
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                case .holding:
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                case .running:
                    break
                }
                do {
                    let data = try await service.previewFrame()
                    guard let image = Self.decode(data) else {
                        await self?.previewFailed("Decoded no image from \(data.count) bytes")
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        continue
                    }
                    failures = 0
                    if gate.claimDelivery() {
                        Task { @MainActor [weak self] in
                            gate.delivered()
                            self?.show(image)
                        }
                    }
                } catch {
                    // The first frame asked for after a copy or a reconnect regularly fails (seen every
                    // time, 19 Nov 2026); the next one works. So one failure is retried at once and
                    // quietly, and only a second in a row is reported and waited on.
                    failures += 1
                    if failures == 1 {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                    } else {
                        if gate.current == .running { await self?.previewFailed(error.localizedDescription) }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            }
        }
    }

    /// Decodes the JPEG here and now, so that drawing it later costs the main thread nothing.
    nonisolated private static func decode(_ data: Data) -> NSImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func show(_ image: NSImage) {
        guard previewGate.current != .paused else { return }       // a frame that was still on its way when the link changed
        preview.image = image
        if lastPreviewError != nil { lastPreviewError = nil }
        previewFrameCount += 1
        countFrame()
        if previewFrameCount % 100 == 1 { debugLog("preview frames so far: \(previewFrameCount)") }
    }

    private func previewFailed(_ why: String) {
        lastPreviewError = why
        debugLog("preview error: \(why)")
    }

    private var fpsWindowStart = Date()
    private var fpsWindowFrames = 0

    private func countFrame() {
        fpsWindowFrames += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 2 {
            preview.fps = Double(fpsWindowFrames) / elapsed
            fpsWindowStart = Date()
            fpsWindowFrames = 0
        }
    }

    /// The camera's live view comes in two sizes: 1024×576 ("sharp") and
    /// 640×360 ("smooth", about a third of the data per frame).
    var liveViewSmooth: Bool { configs["d26a"]?.current == "1" }

    func setLiveViewSmooth(_ smooth: Bool) {
        guard let cfg = configs["d26a"],
              let option = cfg.options.first(where: { $0.value == (smooth ? "1" : "2") }) else { return }
        setOption("/main/other/d26a", index: option.index)
    }

    // MARK: - touch focus

    /// Where the last click on the picture landed (fractions of width and
    /// height), shown as a marker for a moment.
    @Published var touchMarker: CGPoint?

    /// Touch works through the Wi-Fi session only, and only while the camera allows it.
    var touchAvailable: Bool {
        mode == .pcRemote && link?.isWifi == true && cardActivity == nil && configs["d284"]?.current == "1"
    }

    /// The camera says a touch focus or tracking is active and can be ended.
    var touchCancelAvailable: Bool {
        mode == .pcRemote && link?.isWifi == true && configs["d285"]?.current == "1"
    }

    /// true = the camera follows the touched subject, false = it focuses on the touched spot.
    var touchTracks: Bool { configs["d283"]?.current == "4" }

    func setTouchTracks(_ tracks: Bool) {
        guard let option = configs["d283"]?.options.first(where: { $0.value == (tracks ? "4" : "3") }) else { return }
        setOption("/main/other/d283", index: option.index)
    }

    func touchFocus(at point: CGPoint) {
        guard touchAvailable else { return }
        touchMarker = point
        Task {
            do {
                try await service.touch(x: point.x, y: point.y)
            } catch {
                lastError = describe(error)
            }
            await refreshTouchState()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if touchMarker == point { touchMarker = nil }
        }
    }

    func cancelTouchFocus() {
        Task {
            do { try await service.cancelTouch() } catch { lastError = describe(error) }
            touchMarker = nil
            await refreshTouchState()
        }
    }

    private func refreshTouchState() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let cfgs = try? await service.readConfigs(["/main/other/d284", "/main/other/d285", "/main/status/focusindication"]) {
            configs.merge(cfgs) { _, new in new }
        }
    }

    // MARK: - zoom

    /// Zoom works through the Wi-Fi session only, and only when the camera says zoom is possible.
    var zoomAvailable: Bool {
        mode == .pcRemote && link?.isWifi == true && cardActivity == nil && (configs["d25b"]?.current ?? "1") != "0"
    }

    /// +1 / -1 while a zoom button is held, 0 on release.
    func zoom(_ direction: Int) {
        guard zoomAvailable, direction != zoomDirection else { return }
        zoomDirection = direction
        if direction == 0 { zoomStopPending = true }     // no live view frame may get in front of the stop
        updatePreviewGate()
        Task {
            do {
                try await service.zoom(direction)
            } catch {
                lastError = describe(error)
                if direction != 0 { try? await service.zoom(0) }
                zoomDirection = 0
            }
            if direction == 0 { zoomStopPending = false }
            updatePreviewGate()
            if direction == 0 {
                // The camera's settings are re-read at most every 2 s; look again once they are fresh.
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                if zoomDirection == 0, let cfgs = try? await service.readConfigs(["/main/other/d25d", "/main/other/d25c"]) {
                    zoomPosition = ZoomPosition(bar: cfgs["d25d"]?.current, scale: cfgs["d25c"]?.current)
                }
            }
        }
    }

    /// Temporary diagnosis log so CLI can see what the running app observes.
    private func debugLog(_ line: String) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-studio-debug.log")
        let stamped = "\(Date().formatted(.dateTime.hour().minute().second())) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(stamped.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? stamped.data(using: .utf8)?.write(to: url)
        }
    }

    /// A record command is on its way: no live view frame may be queued in front of it.
    private var recordCommandInFlight = false {
        didSet { updatePreviewGate() }
    }
    private var isRecordingBusy: Bool { recordCommandInFlight }

    /// Waits until the camera itself reports the wanted recording state. Its report follows a command
    /// by one to three seconds (measured), so this is asked repeatedly.
    private func cameraRecording(becomes wanted: Bool, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let state = (try? await service.readConfigs(["/main/other/d21d"]))?["d21d"]?.current, (state == "1") == wanted {
                return true
            }
        }
        return false
    }

    /// Sends one record command with live view held back for that moment.
    private func send(start: Bool) async throws {
        recordCommandInFlight = true
        defer { recordCommandInFlight = false }
        if start { try await service.startRecording(preferredMovieMode: preferredMovieMode) }
        else { try await service.stopRecording() }
    }

    // MARK: - actions

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard !timelapseRunning else {
            lastError = "A timelapse is running. Stop it first to record a movie."
            return
        }
        guard mode == .pcRemote else {
            lastError = CameraError.wrongMode("PC Remote").localizedDescription
            return
        }
        guard cardActivity == nil else {
            // Recording comes first: stop the copy (what is here is kept and continued later) and
            // start as soon as the camera is back on remote control.
            guard !recordAfterCard else { return }
            recordAfterCard = true
            busyMessage = "Stopping the copy to record…"
            stopCardCopy()
            return
        }
        // The window says "recording" only once the camera says so. A command the camera accepted
        // but did not act on was seen right after a copy (19 Nov 2026): the window then showed REC for
        // six seconds over a camera that was not recording, and the next press started instead of stopped.
        busyMessage = "Starting recording…"
        Task {
            defer { busyMessage = nil }
            do {
                var sent = Date()
                try await send(start: true)
                var started = await cameraRecording(becomes: true, within: 3.5)
                if !started {
                    debugLog("the camera is not recording 3.5 s after the start command; sending it once more")
                    sent = Date()
                    try await send(start: true)
                    started = await cameraRecording(becomes: true, within: 4.5)
                }
                recordCommandAt = Date()
                awaitingStart = false
                guard started else {
                    debugLog("recording did not start")
                    lastError = "The camera did not start recording. Check the card and that the camera is not in a menu or playback."
                    return
                }
                isRecording = true
                recordingStarted = sent
                lostRecordingStart = nil
                stopAlert = nil
                lastError = nil
                debugLog(String(format: "recording started (the camera confirmed %.1f s after the command)", Date().timeIntervalSince(sent)))
            } catch {
                debugLog("recording start failed: \(error.localizedDescription)")
                lastError = describe(error)
            }
        }
    }

    func stopRecording() {
        stopAskedAt = Date()
        busyMessage = "Stopping…"
        Task {
            var stopped = false
            do {
                let sent = Date()
                try await send(start: false)
                stopped = await cameraRecording(becomes: false, within: 6)      // a 4K clip took 4.5 s to be reported closed
                if !stopped {
                    debugLog("the camera is still recording 6 s after the stop command; sending it once more")
                    try await send(start: false)
                    stopped = await cameraRecording(becomes: false, within: 5)
                }
                recordCommandAt = Date()
                awaitingStart = false
                if stopped {
                    isRecording = false
                    recordingStarted = nil
                    debugLog(String(format: "recording stopped (the camera confirmed %.1f s after the command)", Date().timeIntervalSince(sent)))
                } else {
                    debugLog("recording did not stop")
                    lastError = "The camera is still recording. Press Force Stop, or the movie button on the camera."
                }
            } catch {
                lastError = describe(error)
            }
            busyMessage = nil
            if stopped { takeFinished() }
        }
    }

    func forceStopRecording() {
        stopAskedAt = Date()
        busyMessage = "Force stop…"
        Task {
            defer { busyMessage = nil }
            try? await service.stopRecording()
            isRecording = false
            recordingStarted = nil
            recordCommandAt = Date()
            awaitingStart = false
        }
    }

    // MARK: - photos and timelapse

    var photoAvailable: Bool {
        mode == .pcRemote && !isRecording && cardActivity == nil && busyMessage == nil && applyingPreset == nil && !timelapseRunning
    }

    /// Takes one photo; it lands on the camera's card and, in HD, in the day's Photos folder here.
    func takePhoto() {
        guard photoAvailable else { return }
        busyMessage = "Taking a photo…"
        Task {
            defer { busyMessage = nil }
            do {
                let files = try await shoot(to: PhotoFolders.photos(root: downloadRoot))
                lastPhoto = files.last
                lastError = nil
            } catch {
                debugLog("photo failed: \(error.localizedDescription)")
                lastError = "The photo was not taken (\(describe(error)))."
            }
            await refreshControls()     // the mode may have changed to a photo mode
        }
    }

    private func shoot(to folder: URL) async throws -> [URL] {
        photoInFlight = true
        defer { photoInFlight = false }
        let start = Date()
        let files = try await service.takePhoto(preferredPhotoMode: preferredPhotoMode, to: folder)
        debugLog(String(format: "photo %@ in %.1f s%@", files.last?.lastPathComponent ?? "?", Date().timeIntervalSince(start),
                        files.count > 1 ? " (\(files.count - 1) taken earlier came with it)" : ""))
        return files
    }

    func startTimelapse() {
        guard photoAvailable else { return }
        let plan = timelapsePlan.usable
        if let free = macFreeBytes, free - CopyTarget.spare < Int64(plan.frames) * 1_200_000 {
            lastError = "Not enough room on this Mac for \(plan.frames) photos (about 0.8 MB each, and the movie)."
            return
        }
        if snapshot.photoMode, let left = snapshot.photosLeft, left < plan.frames {
            lastError = "The card has room for \(left) photos; the timelapse needs \(plan.frames)."
            return
        }
        let folder = PhotoFolders.timelapse(root: downloadRoot)
        stopAlert = nil
        timelapse = TimelapseStatus(phase: .shooting, plan: plan, folder: folder)
        timelapseTask = Task { [weak self] in await self?.runTimelapse(plan, folder: folder) }
    }

    /// Ends the shooting after the photo in hand; the movie is made from what there is.
    func stopTimelapse() {
        if timelapse?.phase == .shooting { timelapse?.phase = .stopping }
    }

    func closeTimelapse() {
        guard timelapse?.running != true else { return }
        timelapse = nil
    }

    private var timelapseStopping: Bool { timelapse?.phase == .stopping }

    private func runTimelapse(_ plan: TimelapsePlan, folder: URL) async {
        debugLog("timelapse starts: \(plan.summary) into \(folder.path)")
        // A timelapse runs for hours: the Mac must not go to sleep under it (the screen may).
        let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "Taking a timelapse")
        defer { ProcessInfo.processInfo.endActivity(awake) }
        var frames: [URL] = []
        var focusToRestore: String?
        var failuresInRow = 0
        let start = Date()
        var n = 0
        while n < plan.frames && !timelapseStopping {
            let due = plan.due(n, from: start)
            timelapse?.nextAt = due
            while Date() < due && !timelapseStopping { try? await Task.sleep(nanoseconds: 150_000_000) }
            if timelapseStopping { break }
            if mode == .pcRemote, cardActivity == nil {
                do {
                    let files = try await shoot(to: folder)
                    if let frame = files.last {
                        frames.append(frame)
                        timelapse?.taken = frames.count
                        timelapse?.lastFrame = frame
                    }
                    failuresInRow = 0
                    if frames.count == 1 && plan.lockFocus { focusToRestore = await holdFocus() }
                } catch {
                    failuresInRow += 1
                    timelapse?.missed += 1
                    debugLog("timelapse frame \(n + 1) not taken: \(error.localizedDescription)")
                }
            } else {
                failuresInRow += 1
                timelapse?.missed += 1
                debugLog("timelapse frame \(n + 1) missed: the camera is not connected")
            }
            if failuresInRow >= 10 {
                debugLog("timelapse: ten frames in a row missed; ending it")
                break
            }
            n += 1
            // A frame that took longer than the interval: the slots it ran over are skipped, so the
            // movie keeps an even pace instead of catching up with photos taken back to back.
            while n < plan.frames, Date() > plan.due(n, from: start).addingTimeInterval(plan.interval * 0.5) {
                n += 1
                timelapse?.missed += 1
            }
        }
        timelapse?.nextAt = nil
        if let focus = focusToRestore, !(await setRightAfterPhoto("focusmode", focus)) {
            lastError = "The camera stayed on manual focus after the timelapse; set it back to \(focus) under Focus."
        }
        debugLog("timelapse shot: \(frames.count) photos, \(timelapse?.missed ?? 0) missed, \(Int(Date().timeIntervalSince(start))) s")

        guard frames.count >= 2 else {
            timelapse?.phase = .failed(frames.isEmpty ? "No photo was taken." : "Only one photo was taken, so no movie was made. It is in the folder.")
            timelapseTask = nil
            return
        }
        timelapse?.phase = .making(0)
        let movie = PhotoFolders.unique(folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".mp4"))
        let fps = plan.fps
        let made = Date()
        do {
            try await Task.detached(priority: .userInitiated) {
                try TimelapseMovie.make(frames: frames, fps: fps, to: movie) { part in
                    Task { @MainActor [weak self] in
                        if case .making = self?.timelapse?.phase { self?.timelapse?.phase = .making(part) }
                    }
                }
            }.value
            timelapse?.phase = .finished(movie)
            debugLog(String(format: "timelapse movie %@ made in %.1f s", movie.lastPathComponent, Date().timeIntervalSince(made)))
        } catch {
            timelapse?.phase = .failed(error.localizedDescription + ". The photos are in the folder.")
            debugLog("timelapse movie failed: \(error.localizedDescription)")
        }
        timelapseTask = nil
    }

    /// Puts the camera on manual focus where it focuses by itself; returns the focus mode to set back.
    /// Right after a photo the camera refuses the change for a moment ("Bad parameters" at once after
    /// the first frame, 21 Nov 2026; the same change a little later was taken), so it is tried again.
    private func holdFocus() async -> String? {
        await refreshControls()
        guard let current = configs["focusmode"]?.current, current != "Manual" else { return nil }
        if await setRightAfterPhoto("focusmode", "Manual") {
            debugLog("timelapse: focus held (was \(current))")
            return current
        }
        debugLog("timelapse: focus could not be held; the camera focuses for each photo")
        return nil
    }

    /// A setting changed straight after a photo: the camera refuses it for a moment ("Bad parameters",
    /// seen both after the first frame and after the last, 21–22 Nov 2026), so it waits and tries again.
    private func setRightAfterPhoto(_ leaf: String, _ value: String) async -> Bool {
        for attempt in 1...4 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if await setByValue(leaf, value) {
                if attempt > 1 { debugLog("\(leaf) = \(value) taken at attempt \(attempt)") }
                return true
            }
        }
        return false
    }

    /// Sets a whitelisted choice by its text, as the camera lists it now.
    @discardableResult
    private func setByValue(_ leaf: String, _ value: String) async -> Bool {
        if configs[leaf]?.options.first(where: { $0.value == value }) == nil { await refreshControls() }
        guard let option = configs[leaf]?.options.first(where: { $0.value == value }) else { return false }
        do {
            try await service.setConfig(CameraService.path(forLeaf: leaf), optionIndex: option.index)
            return true
        } catch {
            debugLog("\(leaf) = \(value) not taken: \(error.localizedDescription)")
            return false
        }
    }

    func setOption(_ path: String, index: Int) {
        let leaf = CameraService.leaf(of: path)
        if let value = configs[leaf]?.options.first(where: { $0.index == index })?.value { showPending(leaf, value) }
        Task {
            do {
                try await service.setConfig(path, optionIndex: index)
                await settle()
            } catch {
                pendingValues[leaf] = nil
                lastError = "The camera did not take that setting (\(describe(error)))."
                await refreshControls()
            }
        }
    }

    func setRange(_ path: String, value: Double) {
        let leaf = CameraService.leaf(of: path)
        if configs[leaf]?.isRange == true { showPending(leaf, String(Int(value))) }
        Task {
            do {
                try await service.setConfig(path, rangeValue: Int(value))
                await settle()
            } catch {
                pendingValues[leaf] = nil
                lastError = "The camera did not take that setting (\(describe(error)))."
                await refreshControls()
            }
        }
    }

    /// Shows a value at once, before the camera reports it.
    private func showPending(_ leaf: String, _ value: String) {
        guard let cfg = configs[leaf] else { return }
        pendingValues[leaf] = (value, Date().addingTimeInterval(4))
        configs[leaf] = cfg.with(current: value)
    }

    /// What the camera reports, with values still on their way to it kept as sent.
    private func withPending(_ cfgs: [String: CameraConfig]) -> [String: CameraConfig] {
        guard !pendingValues.isEmpty else { return cfgs }
        var out = cfgs
        let now = Date()
        for (leaf, pending) in pendingValues {
            guard let cfg = out[leaf], now < pending.until, !cfg.shows(pending.value) else {
                pendingValues[leaf] = nil       // reported, timed out, or no longer offered
                continue
            }
            out[leaf] = cfg.with(current: pending.value)
        }
        return out
    }

    private func refreshControls() async {
        guard cardActivity == nil, mode == .pcRemote,
              let cfgs = try? await service.readConfigs(CameraService.controlPaths), !cfgs.isEmpty else { return }
        let shown = withPending(cfgs)
        if shown != configs { configs = shown }
        readStatus(from: cfgs)
    }

    /// One setting changes what others offer (the mode decides whether shutter and ISO can be set),
    /// and the camera needs a moment: read everything again, twice.
    private func settle() async {
        for delay: UInt64 in [900_000_000, 1_300_000_000] {
            try? await Task.sleep(nanoseconds: delay)
            await refreshControls()
        }
    }

    func triggerAutofocus() {
        Task { try? await service.setConfig("/main/actions/autofocus", optionIndex: 1) }
    }

    // MARK: - the camera's clock

    /// The camera cannot be asked what time it has, only told. Not while it records: the clip
    /// being written would get a clock that jumps.
    var clockAvailable: Bool {
        mode == .pcRemote && !isRecording && cardActivity == nil && busyMessage == nil && applyingPreset == nil && !timelapseRunning
    }

    func setCameraClockNow() {
        guard clockAvailable else { return }
        Task { await sendClock(asked: true) }
    }

    private func sendClock(asked: Bool) async {
        let now = Date()
        do {
            try await service.setClock(now)
            clockSetAt = now
            debugLog("camera clock set to \(CameraClock.text(now))")
        } catch {
            debugLog("camera clock not set: \(describe(error))")
            if asked { lastError = "The camera did not take the date and time (\(describe(error)))." }
        }
    }

    // MARK: - presets

    /// The user's own first, then the ready-made ones.
    var allPresets: [Preset] { presetLibrary.presets + Preset.builtIns }

    /// A preset changes the mode and the movie format, which the camera refuses while it records,
    /// and it needs the remote connection, which a copy has taken.
    var presetsAvailable: Bool {
        mode == .pcRemote && !isRecording && cardActivity == nil && busyMessage == nil && applyingPreset == nil && !timelapseRunning
    }

    func applyPreset(_ preset: Preset, onConnect: Bool = false) {
        guard presetsAvailable else { return }
        applyingPreset = preset.id
        busyMessage = "Applying \(preset.name)…"
        presetOutcome = nil
        Task {
            var outcome = await send(preset)
            if onConnect { outcome.name += " (on connect)" }
            applyingPreset = nil
            busyMessage = nil
            presetOutcome = outcome
            debugLog("preset " + outcome.text)
            await refreshControls()
        }
    }

    /// Sends a preset's settings one after the other, each through the whitelisted setter, and waits
    /// for the camera to report each value before the next (the mode decides what the next may be).
    private func send(_ preset: Preset) async -> PresetOutcome {
        var outcome = PresetOutcome(name: preset.name)
        let started = Date()
        var lastChange: Date?
        let settings = preset.ordered
        for (n, setting) in settings.enumerated() {
            guard let field = PresetCatalogue.field(setting.leaf), let wanted = setting.values.first else { continue }
            guard mode == .pcRemote, cardActivity == nil, !isRecording else {
                outcome.stopped = isRecording ? "the camera started recording" : "the camera is not reachable"
                break
            }
            busyMessage = "\(preset.name): \(field.title) (\(n + 1) of \(settings.count))…"
            let path = CameraService.path(forLeaf: setting.leaf)
            do {
                // A mode or format just changed shows in what the camera offers a moment later.
                var step = PresetPlan.step(for: setting, in: try await service.readConfigs([path])[setting.leaf])
                while step.canWait, let at = lastChange, Date().timeIntervalSince(at) < 3 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    step = PresetPlan.step(for: setting, in: try await service.readConfigs([path])[setting.leaf])
                }
                let wantedLabel = SettingNames.label(leaf: setting.leaf, value: wanted)
                let value: String
                switch step {
                case .already:
                    outcome.kept += 1
                    if setting.leaf == "expprogram" { rememberMovieMode(wanted) }
                    continue
                case .notOffered:
                    outcome.skipped.append("\(field.title) (the camera does not offer it)")
                    continue
                case .locked:
                    outcome.skipped.append("\(field.title) (the camera sets it itself in this mode)")
                    continue
                case .noSuchValue:
                    outcome.skipped.append("\(field.title) \(wantedLabel) (not on offer right now)")
                    continue
                case .choose(let index, let chosen, _):
                    value = chosen
                    showPending(setting.leaf, chosen)
                    try await service.setConfig(path, optionIndex: index)
                case .slide(let number):
                    value = String(number)
                    showPending(setting.leaf, value)
                    try await service.setConfig(path, rangeValue: number)
                }
                // The camera reports a change 0.8 to 3.7 s after taking it (measured).
                var confirmed = false
                let deadline = Date().addingTimeInterval(5)
                while !confirmed && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    confirmed = try await service.readConfigs([path])[setting.leaf]?.shows(value) ?? false
                }
                lastChange = Date()
                let label = SettingNames.label(leaf: setting.leaf, value: value)
                if !confirmed {
                    pendingValues[setting.leaf] = nil
                    outcome.failed.append("\(field.title) \(label)")
                } else if case .choose(_, _, true) = step {
                    outcome.adjusted.append("\(field.title) \(label) for \(wantedLabel)")
                } else {
                    outcome.set.append(field.title)
                }
                if confirmed, setting.leaf == "expprogram" { rememberMovieMode(value) }
            } catch {
                pendingValues[setting.leaf] = nil
                outcome.failed.append("\(field.title) (\(describe(error)))")
            }
        }
        outcome.seconds = Date().timeIntervalSince(started)
        return outcome
    }

    /// The mode a preset chose is also the one Record switches to when the camera is in a photo mode.
    private func rememberMovieMode(_ value: String) {
        if value.hasPrefix("Movie ("), !value.contains("S&Q"), preferredMovieMode != value { preferredMovieMode = value }
    }

    /// Saves the camera's settings as they are now under a name; a preset of that name is replaced.
    /// False when the camera offers nothing that could be saved (not connected, or all of it locked).
    @discardableResult
    func savePreset(name: String, groups: Set<PresetGroup>) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let preset = Preset.capture(name: name, from: configs, groups: groups)
        guard !name.isEmpty, !preset.settings.isEmpty else { return false }
        presetLibrary.put(preset)
        presetLibrary.save()
        return true
    }

    private func refreshMacFree() {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        // The download folder may not exist yet: ask the nearest folder above it that does.
        var folder = downloadRoot
        while !FileManager.default.fileExists(atPath: folder.path), folder.path != "/" { folder.deleteLastPathComponent() }
        guard let values = try? folder.resourceValues(forKeys: keys) else { return }
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let rounded = free / 100_000_000 * 100_000_000
        if rounded != macFreeBytes { macFreeBytes = rounded }
    }

    func deletePreset(_ id: String) {
        if startupPresetID == id { startupPresetID = nil }
        presetLibrary.remove(id: id)
        presetLibrary.save()
    }

    // MARK: - clips & downloads

    func refreshClips() async {
        switch clipSource {
        case .mtp:
            do { clips = try await service.listFiles() } catch { lastError = describe(error) }
        case .disk(let root):
            clips = await Task.detached { CardVolume.list(root) }.value
        case .camera:
            await runCard(.list(fresh: true))
        case nil:
            clips = []
        }
    }

    // MARK: - the card over the phone service

    /// Hands the camera over to its card for one job and takes it back.
    /// Live view and the controls pause meanwhile.
    private func runCard(_ request: CardRequest) async {
        guard cardActivity == nil, mode == .pcRemote, phoneControl, !isRecording else { return }
        let cancel = CancelFlag()
        cardCancel = cancel
        cardActivity = CardActivity(title: "Switching the camera to its card…")
        if case .catchUp = request { catchUpRunning = true } else { catchUpRunning = false }
        catchUpFailures = 0
        // A copy can run for an hour or more: keep the Mac from going to sleep under it.
        let awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                          reason: "Copying clips from the camera")
        defer { ProcessInfo.processInfo.endActivity(awake) }
        debugLog("card job starts: \(Self.describe(request))")
        do {
            for try await event in service.card(request, root: downloadRoot, cancel: cancel) { show(event) }
            if catchUpRunning && catchUpFailures == 0 {
                pendingTakes = 0                // every waiting take is here now
                copyFrom = highestListed ?? copyFrom
                watchedSinceMark = highestListed != nil
            }
        } catch CardError.stopped {
            debugLog("card job stopped by the user")
        } catch {
            debugLog("card job failed: \(error.localizedDescription)")
            let copying = downloadStates.contains { $0.value == .running }
            lastError = copying
                ? "The copy was interrupted (\(describe(error))). The part already copied is kept and is continued next time."
                : describe(error)
        }
        catchUpRunning = false
        for id in downloadStates.filter({ $0.value == .running }).keys { downloadStates[id] = nil }

        cardActivity = CardActivity(title: "Back to remote control…")
        copyProgress.reset()
        var status = ConnectionStatus()
        for attempt in 0..<6 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            status = await service.detect()
            if status.mode != .disconnected { break }
        }
        debugLog("card job ends, \(status.mode)")
        cardCancel = nil
        cardActivity = nil
        await apply(status)
        if recordAfterCard {
            recordAfterCard = false
            // Straight after the card session the camera takes a record command and does nothing
            // (measured twice, 19 Nov 2026); give it a moment first. The start is checked and
            // repeated in any case.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            busyMessage = nil
            if status.mode == .pcRemote { startRecording() }
            else { lastError = "The camera did not come back to remote control after the copy was stopped; recording was not started." }
        }
    }

    private func show(_ event: CardEvent) {
        switch event {
        case .status(let text):
            cardActivity = CardActivity(title: text)
            copyProgress.reset()
        case .listed(let found):
            clips = found
            lastCameraClips = found
            cameraClipsReadAt = Date()
            ClipListCache(readAt: Date(), clips: found).save()
            cameraClipsLoaded = true
            highestListed = CameraService.highestClipNumber(found)
            if pendingTakes == 0 {
                // No clips at all (a card just formatted): every clip that comes is new, whatever
                // number the camera starts again from.
                copyFrom = highestListed ?? 0
                watchedSinceMark = true
            }
        case .started(let clip):
            downloadStates[clip.id] = .running
            let total = clip.sizeBytes > 0 ? Int64(clip.sizeBytes) : nil
            cardActivity = CardActivity(title: "Copying \(clip.name)", total: total)
            copyProgress.reset(total: total)
            rateMark = nil
        case .progress(_, let done, let total):
            let now = Date()
            if let mark = rateMark {
                let elapsed = now.timeIntervalSince(mark.time)
                if elapsed >= 2 {
                    copyProgress.bytesPerSecond = Double(done - mark.bytes) / elapsed
                    rateMark = (now, done)
                }
            } else {
                rateMark = (now, done)
            }
            // The copy sends these a few times a second at most (see `CameraService.perform`).
            copyProgress.done = done
            if copyProgress.total != total { copyProgress.total = total }
        case .finished(let clip, let url):
            downloadStates[clip.id] = .done(url)
            onMac[clip.id] = url
            if catchUpRunning { pendingTakes = max(0, pendingTakes - 1) }
            debugLog("copied \(clip.name)")
        case .failed(let clip, let why):
            downloadStates[clip.id] = .failed(why)
            catchUpFailures += 1
            debugLog("not copied: \(clip.name): \(why)")
            lastError = "Not copied: \(clip.name): \(why)"
        }
    }

    /// Stops a copy after the piece in flight; what is already here is kept.
    func stopCardCopy() {
        cardCancel?.set()
        cardActivity?.title = "Stopping…"
    }

    private static func describe(_ request: CardRequest) -> String {
        switch request {
        case .list(let fresh): return fresh ? "list (from scratch)" : "list"
        case .download(let clips): return "download \(clips.count) files"
        case .catchUp(let after, let count, let everyAbove):
            return "copy \(everyAbove ? "every take" : "\(count) waiting takes"), numbered above \(after.map(String.init) ?? "?")"
        }
    }

    /// A recording has ended (stopped here, on the camera, or by a full card): one more take waits to be copied.
    private func takeFinished() {
        guard phoneControl else { return }      // only this connection hands over the card
        pendingTakes += 1
        if autoCopy { Task { await copyWaitingTakes(justStopped: true) } }
    }

    /// Fetches the takes that are waiting. Right after a recording it first lets the camera finish the file.
    func copyWaitingTakes(justStopped: Bool = false) async {
        guard pendingTakes > 0, cardActivity == nil else { return }
        if justStopped {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if let cfgs = try? await service.readConfigs(["/main/other/d21d"]), cfgs["d21d"]?.current == "0" { break }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // Recording again already? Then this take stays on the list and is fetched with the next one.
        await runCard(.catchUp(after: copyFrom, count: pendingTakes, everyAbove: watchedSinceMark))
    }

    func download(_ clipsToGet: [ClipFile]) {
        guard clipSource != nil else { return }
        if clipSource == .camera {
            Task { await runCard(.download(clipsToGet.filter { $0.cameraHandle != nil })) }
            return
        }
        Task {
            for clip in clipsToGet {
                if case .running = downloadStates[clip.id] { continue }
                downloadStates[clip.id] = .running
                do {
                    let dir = downloadRoot.appendingPathComponent(clip.dayFolder, isDirectory: true)
                    let url: URL
                    if clip.diskURL != nil {
                        url = try await Task.detached { try CardVolume.copy(clip, to: dir) }.value
                    } else {
                        url = try await service.download(clip, to: dir)
                    }
                    downloadStates[clip.id] = .done(url)
                    onMac[clip.id] = url
                } catch {
                    downloadStates[clip.id] = .failed(describe(error))
                    lastError = "Download failed: \(clip.name): \(describe(error))"
                }
            }
        }
    }

    /// Unmounts the card so the cable can be pulled safely.
    // MARK: - setting up the ESP32-C3 board

    /// Opens the board set-up sheet. Nothing is sent to any board here.
    func openBoardSetup() {
        var problem: String?
        var version: Int?
        do { version = try EspFlasher.bundledImage().version } catch { problem = error.localizedDescription }
        let ports = EspFlasher.ports().filter(\.isEspressif)
        boardSetup = BoardSetup(ports: ports, selected: ports.count == 1 ? ports[0].path : nil,
                                imageVersion: version, imageProblem: problem)
    }

    func refreshBoardPorts() {
        guard var setup = boardSetup, !setup.isWorking else { return }
        setup.ports = EspFlasher.ports().filter(\.isEspressif)
        if !setup.ports.contains(where: { $0.path == setup.selected }) {
            setup.selected = setup.ports.count == 1 ? setup.ports[0].path : nil
        }
        setup.phase = .choose
        boardSetup = setup
    }

    /// Writes the bridge program to the chosen board, after the bridge has let go of the port.
    func flashBoard() {
        guard var setup = boardSetup, !setup.isWorking, let path = setup.selected,
              let port = setup.ports.first(where: { $0.path == path }) else { return }
        guard !isRecording, cardActivity == nil, !timelapseRunning else {
            setup.phase = .failed("The board carries the camera's link: wait until the camera is not recording, copying or taking a timelapse.")
            boardSetup = setup
            return
        }
        setup.phase = .working("Getting ready…", nil)
        boardSetup = setup
        boardFlashing = true
        debugLog("board set-up: writing the bridge program to \(port.label)")
        Task {
            await Task.detached { BridgeController.shared.stop() }.value
            if self.link == .wifi(BridgeController.localHost) {
                await self.service.setWifiTarget(nil)
            }
            self.bridge = .off
            let result: Result<EspFlasher.Outcome, Error> = await Task.detached {
                do {
                    let image = try EspFlasher.bundledImage()
                    return .success(try EspFlasher.flash(port: port.path, image: image, expectMAC: port.serial) { step in
                        let (text, fraction) = BoardSetup.text(for: step)
                        Task { @MainActor in
                            if self.boardSetup?.isWorking == true { self.boardSetup?.phase = .working(text, fraction) }
                        }
                    })
                } catch {
                    return .failure(error)
                }
            }.value
            try? await Task.sleep(nanoseconds: 1_500_000_000)     // the new program starts up
            self.boardFlashing = false
            switch result {
            case .success(let out):
                debugLog(String(format: "board set-up: done, %@, %d bytes in %.1f s", out.mac, out.bytes, out.seconds))
                let next = self.bridgeSettings.usable
                    ? "The app now joins the camera through it."
                    : "Turn on “ESP32 bridge” in the Wi-Fi panel and enter the camera's network name and password."
                self.boardSetup?.phase = .done("The bridge program is on the board (\(out.mac)). \(next)")
            case .failure(let error):
                debugLog("board set-up failed: \(error.localizedDescription)")
                self.boardSetup?.phase = .failed(error.localizedDescription)
            }
        }
    }

    func closeBoardSetup() {
        guard boardSetup?.isWorking != true else { return }
        boardSetup = nil
    }

    // MARK: - erasing the card

    /// Looks at the card and opens the confirmation. Nothing is deleted here.
    func prepareWipe() {
        guard !isRecording, cardActivity == nil, !timelapseRunning, !wiping else {
            lastError = "The card cannot be erased while the camera is recording, copying or taking a timelapse."
            return
        }
        switch clipSource {
        case .disk(let root):
            do {
                wipePlan = try CardWipe.plan(root, facts: .read(root), isOnMac: { self.isDownloaded($0) })
                debugLog("erase asked for: \(wipePlan?.summary ?? "")")
            } catch {
                lastError = error.localizedDescription
            }
        case .camera, .mtp:
            lastError = CardWipe.Refusal.phoneControl.localizedDescription
        case nil:
            lastError = CardWipe.Refusal.noCard.localizedDescription
        }
    }

    func cancelWipe() {
        if !wiping { wipePlan = nil }
    }

    /// Erases the card shown in `wipePlan`, once a person has typed the confirmation word.
    func confirmWipe(typed: String) {
        guard let plan = wipePlan, !wiping else { return }
        wiping = true
        Task {
            let facts = CardWipe.VolumeFacts.read(plan.volume)
            do {
                let result = try await Task.detached { try CardWipe.erase(plan, facts: facts, typed: typed) { _, _ in } }.value
                let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
                wipeOutcome = result.failed.isEmpty
                    ? "The card “\(plan.volumeName)” is erased: \(plan.files) files, \(size). The camera sets up its folders again the next time it uses the card."
                    : "Partly erased. Not deleted: " + result.failed.joined(separator: "; ")
                debugLog("card erased: \(plan.summary); \(result.deleted) items deleted, \(result.failed.count) not")
            } catch {
                wipeOutcome = "Not erased: \(error.localizedDescription)"
                debugLog("erase refused: \(error.localizedDescription)")
            }
            wiping = false
            wipePlan = nil
            await refreshClips()
        }
    }

    func ejectCard() {
        guard case .disk(let root) = clipSource else { return }
        Task {
            do {
                try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: root) }.value
            } catch {
                lastError = "Could not eject the card: \(describe(error))"
            }
        }
    }

    func downloadNew() {
        let fresh = clips.filter { !isDownloaded($0) }
        guard !fresh.isEmpty else { return }
        download(fresh)
    }

    /// Where a clip of the list would be in the download folder.
    private func localURL(for clip: ClipFile) -> URL {
        downloadRoot.appendingPathComponent(clip.dayFolder, isDirectory: true).appendingPathComponent(clip.name)
    }

    /// Looks on the disk which clips of the list are here (same name and size).
    private func refreshOnMac() {
        var found: [String: URL] = [:]
        let fm = FileManager.default
        for clip in clips {
            let url = localURL(for: clip)
            if let size = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value, size == clip.sizeBytes {
                found[clip.id] = url
            }
        }
        if found != onMac { onMac = found }
    }

    func isDownloaded(_ clip: ClipFile) -> Bool {
        onMac[clip.id] != nil
    }

    func showDownloadFolder() {
        try? FileManager.default.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(downloadRoot)
    }

    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where clips are saved"
        if panel.runModal() == .OK, let url = panel.url {
            downloadRoot = url
            UserDefaults.standard.set(url.path, forKey: "downloadRoot")
        }
    }

    /// Opens a clip that is on this Mac in its usual player.
    func open(_ clip: ClipFile) {
        if let url = onMac[clip.id] { NSWorkspace.shared.open(url) }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func describe(_ error: Error) -> String {
        error.localizedDescription
    }
}

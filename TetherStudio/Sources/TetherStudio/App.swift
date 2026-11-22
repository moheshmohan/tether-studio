import SwiftUI

@main
struct TetherStudioApp: App {
    @StateObject private var store = CameraStore()

    init() {
        // A connection that drops while something is being written to it must be an error
        // to handle, not the end of the app: without this, macOS ends the process with
        // SIGPIPE (seen when the bridge board restarted while the camera library was sending).
        signal(SIGPIPE, SIG_IGN)
        LegacyData.migrate()            // settings of the app's earlier name, copied once
        BundledLibraries.configure()    // the camera library's plug-ins inside the app, when bundled
        WifiCheck.runIfRequested()      // `TetherStudio --wifi-check [address]`: text-only connection test
        // One window only: a second copy would open the board's USB port as well, and the two would
        // take each other's answers (done by mistake on 19 Nov 2026; the first copy lost the camera).
        if !SingleInstance.claim() {
            fputs("Tether Studio is already open.\n", stderr)
            NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "io.github.moheshmohan.tetherstudio")
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                .activate(options: [])
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Tether Studio") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 980, minHeight: 660)
        }
        .commands {
            CommandMenu("Camera") {
                Button(store.isRecording ? "Stop Recording" : "Start Recording") {
                    store.toggleRecording()
                }
                .keyboardShortcut("r")
                .disabled(store.mode != .pcRemote || store.busyMessage != nil)

                Button("Take Photo") {
                    store.takePhoto()
                }
                .keyboardShortcut("t")
                .disabled(!store.photoAvailable)
                if store.timelapse?.phase == .shooting {
                    Button("Stop Timelapse") { store.stopTimelapse() }
                }
                Picker("Photo Mode", selection: $store.preferredPhotoMode) {
                    ForEach(CameraService.photoModes, id: \.self) { Text($0).tag($0) }
                }

                Button("Autofocus") {
                    store.triggerAutofocus()
                }
                .keyboardShortcut("f")
                .disabled(store.mode != .pcRemote)

                Menu("Apply Preset") {
                    ForEach(Array(store.allPresets.enumerated()), id: \.element.id) { index, preset in
                        if index < 9 {
                            Button(preset.name) { store.applyPreset(preset) }
                                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        } else {
                            Button(preset.name) { store.applyPreset(preset) }
                        }
                    }
                }
                .disabled(!store.presetsAvailable)
                Picker("Preset on Connect", selection: $store.startupPresetID) {
                    Text("None").tag(String?.none)
                    Divider()
                    ForEach(store.allPresets) { preset in
                        Text(preset.name).tag(String?.some(preset.id))
                    }
                }

                Divider()
                Toggle("Alert When Recording Stops by Itself", isOn: $store.stopAlertSound)
                Button("Try the Stop Alert") {
                    store.tryStopAlert()
                }

                Divider()
                Button("Set Camera Clock Now") {
                    store.setCameraClockNow()
                }
                .disabled(!store.clockAvailable)
                Toggle("Set Camera Clock on Connect", isOn: $store.clockSync)
                if let at = store.clockSetAt {
                    Text("Camera clock set at \(at.formatted(date: .omitted, time: .standard))")
                }

                Divider()
                Button("Refresh Clip List") {
                    Task { await store.refreshClips() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.isRecording || store.cardActivity != nil)

                Button("Copy New Clips") {
                    store.downloadNew()
                }
                .keyboardShortcut("d")
                .disabled(store.isRecording || store.cardActivity != nil || store.clips.allSatisfy { store.isDownloaded($0) })

                Divider()
                Toggle("MCP Server for AI Assistants", isOn: $store.mcpEnabled)
                Button("Copy MCP Setup Command") { store.copyMcpSetupCommand() }
                    .disabled(!store.mcpEnabled)

                Button("Erase Card…") {
                    store.prepareWipe()
                }
                .disabled(store.isRecording || store.cardActivity != nil)

                Button("Set Up ESP32-C3 Board…") {
                    store.openBoardSetup()
                }

                Button("Show Download Folder") {
                    store.showDownloadFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

/// A lock file that says "a window of this app is open". The window holds it for as long as it
/// runs; macOS releases it when the process ends, however it ends.
enum SingleInstance {
    private static var held: Int32 = -1

    static var url: URL {
        BridgeSettings.url.deletingLastPathComponent().appendingPathComponent("app.lock")
    }

    private static func lock(_ url: URL) -> Int32? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
        close(fd)
        return -1
    }

    /// Takes the lock for this process. False when another copy has it. (True also when the lock
    /// file cannot be made at all: that must not keep the app from starting.)
    static func claim(_ url: URL = SingleInstance.url) -> Bool {
        guard let fd = lock(url) else { return true }
        if fd < 0 { return false }
        held = fd
        return true
    }

    /// Is a window of the app open in another process? For the command-line checks, which need the board to themselves.
    static func windowIsOpen(_ url: URL = SingleInstance.url) -> Bool {
        guard let fd = lock(url) else { return false }
        if fd < 0 { return true }
        flock(fd, LOCK_UN)
        close(fd)
        return false
    }
}

import AppKit
import Foundation

/// Every option of the window as an MCP tool. Each one goes through the same store call as the
/// window's button or menu item, with the same checks; settings only through the whitelist.
/// Erasing the card can only be asked for: a person confirms it in the app.
@MainActor
enum McpTools {
    nonisolated static let instructions = """
    Tether Studio controls a Sony ZV-E10 camera (over its own Wi-Fi through a USB board, or USB). \
    Start with get_status. Settings: list_settings, then set_setting with a value from its choices. \
    Recording, photos and timelapses land on the camera's card; copies come to the download folder on this Mac. \
    get_live_view_image returns the camera's current picture. erase_card and set_up_board only open a sheet in the app; \
    a person must type ERASE there. Nothing here updates the camera's firmware.
    """

    struct Tool {
        let name: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]
        let readOnly: Bool
        let destructive: Bool
        let run: @MainActor (CameraStore, [String: Any]) async -> McpToolResult

        var listing: [String: Any] {
            [
                "name": name,
                "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false],
            ]
        }
    }

    static func string(_ description: String, _ choices: [String]? = nil) -> [String: Any] {
        var p: [String: Any] = ["type": "string", "description": description]
        if let choices { p["enum"] = choices }
        return p
    }
    static func number(_ description: String, min: Double? = nil, max: Double? = nil) -> [String: Any] {
        var p: [String: Any] = ["type": "number", "description": description]
        if let min { p["minimum"] = min }
        if let max { p["maximum"] = max }
        return p
    }
    static func bool(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }

    /// Settings moved by their own tools, never by set_setting.
    static let actionLeaves: Set<String> = ["movie", "autofocus", "manualfocus", "capture", CameraClock.setting]

    // MARK: - waiting for the camera

    /// Waits until `done` holds or `seconds` pass; true when it held.
    static func wait(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if done() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return done()
    }

    static func iso(_ date: Date?) -> Any { date.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull() }

    // MARK: - what is shown

    static func status(_ s: CameraStore) -> [String: Any] {
        var out: [String: Any] = [
            "connection": s.mode.title,
            "phone_control": s.phoneControl,
            "link": s.link.map { $0.isWifi ? "wifi" : "usb" } ?? NSNull(),
            "camera": s.mode == .disconnected ? NSNull() : "\(s.snapshot.model) fw \(s.snapshot.firmware)",
            "battery_percent": s.snapshot.batteryPercent ?? NSNull(),
            "card": s.snapshot.remainingLabel ?? NSNull(),
            "camera_hot": s.snapshot.overheating,
            "mode": s.configs["expprogram"]?.current ?? NSNull(),
            "recording": s.isRecording,
            "recording_since": iso(s.recordingStarted),
            "busy": s.busyMessage ?? NSNull(),
            "card_activity": s.cardActivity?.title ?? NSNull(),
            "last_error": s.lastError ?? NSNull(),
            "ready_check": s.readyIssues.map { ["level": "\($0.level)", "text": $0.text] },
            "summary": ReadyCheck.summary(snapshot: s.snapshot, configs: s.configs),
            "takes_waiting_to_copy": s.pendingTakes,
            "download_folder": s.downloadRoot.path,
            "mac_free_bytes": s.macFreeBytes ?? NSNull(),
            "live_view": s.previewEnabled,
            "zoom": s.zoomPosition.map { "\($0)" } ?? NSNull(),
        ]
        if let alert = s.stopAlert {
            out["stop_alert"] = ["title": alert.title, "detail": alert.detail, "when": alert.when]
        }
        if let t = s.timelapse {
            var phase = "\(t.phase)"
            if case .finished(let url) = t.phase { phase = "finished"; out["timelapse_movie"] = url.path }
            out["timelapse"] = ["phase": phase, "taken": t.taken, "missed": t.missed, "of": t.plan.frames,
                                "plan": t.plan.summary, "folder": t.folder.path, "next_photo_at": iso(t.nextAt)]
        }
        if let photo = s.lastPhoto { out["last_photo"] = photo.path }
        if let preset = s.presetOutcome { out["last_preset"] = preset.text }
        switch s.bridge {
        case .joined(let net, let dbm): out["bridge"] = "joined \(net) (\(dbm) dBm)"
        default: out["bridge"] = "\(s.bridge)"
        }
        return out
    }

    static func title(_ leaf: String, _ cfg: CameraConfig?) -> String {
        PresetCatalogue.field(leaf)?.title ?? cfg?.label ?? leaf
    }

    static func settings(_ s: CameraStore) -> [[String: Any]] {
        s.configs.keys.sorted().compactMap { leaf in
            guard let c = s.configs[leaf] else { return nil }
            var item: [String: Any] = [
                "setting": leaf,
                "name": title(leaf, c),
                "value": c.current ?? NSNull(),
                "shown_as": c.current.map { SettingNames.label(leaf: leaf, value: $0) } ?? NSNull(),
                "can_set_now": WritableConfig.allowed.contains(leaf) && !actionLeaves.contains(leaf) && !c.readOnly,
            ]
            if c.isRange {
                item["range"] = ["min": c.bottom ?? 0, "max": c.top ?? 0, "step": c.step ?? 1]
            } else if !c.options.isEmpty {
                item["choices"] = c.options.map { o -> [String: String] in
                    let shown = SettingNames.label(leaf: leaf, value: o.value)
                    return shown == o.value ? ["value": o.value] : ["value": o.value, "shown_as": shown]
                }
            }
            return item
        }
    }

    static func clips(_ s: CameraStore) -> [[String: Any]] {
        s.clips.map { c in
            var item: [String: Any] = ["name": c.name, "day": c.dayFolder, "size": c.sizeLabel, "bytes": c.sizeBytes,
                                       "kind": c.isVideo ? "clip" : "photo", "on_mac": s.isDownloaded(c)]
            if case .failed(let why) = s.downloadStates[c.id] { item["copy_failed"] = why }
            if case .running = s.downloadStates[c.id] { item["copying"] = true }
            return item
        }
    }

    static func preset(named name: String, in s: CameraStore) -> Preset? {
        s.allPresets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }
    }

    // MARK: - the tools

    static let all: [Tool] = [
        Tool(name: "get_status", description: "Connection, camera, battery, card room, mode, recording, timelapse, copies, warnings and the last error.",
             properties: [:], required: [], readOnly: true, destructive: false) { s, _ in .data(status(s)) },

        Tool(name: "list_settings", description: "Every camera setting the app reads: value, the choices (or range), and whether it can be set now. Many are locked in Movie (Scene) mode.",
             properties: [:], required: [], readOnly: true, destructive: false) { s, _ in
            s.configs.isEmpty ? .failure("No settings: the camera is not connected in remote control.") : .data(settings(s))
        },

        Tool(name: "set_setting", description: "Change one camera setting, e.g. setting=shutterspeed value=1/50, iso=400, whitebalance=Daylight, colortemperature=5600, expprogram=\"Movie (M)\", d242 (movie quality) by value or its shown name. Only whitelisted settings.",
             properties: ["setting": string("The setting's id from list_settings (or its name)"),
                          "value": string("A choice's value or shown name, or a number for a range")],
             required: ["setting", "value"], readOnly: false, destructive: false) { s, a in
            guard let asked = a["setting"] as? String, let value = (a["value"] as? String) ?? (a["value"] as? NSNumber)?.stringValue else {
                return .failure("setting and value are needed")
            }
            let leaf = s.configs.keys.first { $0 == asked } ?? s.configs.keys.first { title($0, s.configs[$0]).caseInsensitiveCompare(asked) == .orderedSame } ?? asked
            guard WritableConfig.allowed.contains(leaf), !actionLeaves.contains(leaf) else { return .failure("\(asked) cannot be set from here") }
            guard let cfg = s.configs[leaf] else { return .failure("The camera does not report \(asked) now") }
            guard !cfg.readOnly else { return .failure("\(title(leaf, cfg)) is locked in the camera's present mode (\(s.configs["expprogram"]?.current ?? "?"))") }
            let path = CameraService.path(forLeaf: leaf)
            var wanted = value
            if cfg.isRange {
                guard let number = Double(value.filter { "0123456789.-".contains($0) }) else { return .failure("\(asked) wants a number") }
                s.setRange(path, value: number)
                wanted = String(Int(number))
            } else {
                guard let option = cfg.options.first(where: { $0.value == value })
                        ?? cfg.options.first(where: { $0.value.caseInsensitiveCompare(value) == .orderedSame })
                        ?? cfg.options.first(where: { SettingNames.label(leaf: leaf, value: $0.value).caseInsensitiveCompare(value) == .orderedSame })
                else {
                    return .failure("\(value) is not offered for \(title(leaf, cfg)). Choices: " + cfg.options.map(\.value).joined(separator: ", "))
                }
                wanted = option.value
                s.setOption(path, index: option.index)
            }
            let took = await wait(6) { s.configs[leaf]?.shows(wanted) == true && s.lastError == nil }
            let now = s.configs[leaf]?.current ?? "?"
            return took ? .text("\(title(leaf, cfg)) is now \(SettingNames.label(leaf: leaf, value: now))")
                : .failure("The camera reports \(title(leaf, cfg)) = \(now)" + (s.lastError.map { " (\($0))" } ?? ""))
        },

        Tool(name: "start_recording", description: "Start recording a movie on the camera's card (switches a photo or S&Q mode to the preferred movie mode).",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            guard !s.isRecording else { return .text("Already recording") }
            s.lastError = nil
            s.startRecording()
            _ = await wait(15) { s.isRecording || (s.busyMessage == nil && s.lastError != nil) }
            return s.isRecording ? .text("Recording") : .failure(s.lastError ?? "The camera did not start recording")
        },
        Tool(name: "stop_recording", description: "Stop recording. With automatic copy on, the clip is then copied to this Mac.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            guard s.isRecording else { return .text("Not recording") }
            s.stopRecording()
            _ = await wait(15) { !s.isRecording && s.busyMessage == nil }
            return s.isRecording ? .failure(s.lastError ?? "Still recording") : .text("Stopped")
        },
        Tool(name: "force_stop_recording", description: "Send the stop signal again when a stop did not take.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            s.forceStopRecording(); return .text("Stop sent")
        },

        Tool(name: "take_photo", description: "Take a photo. Full size on the card; an HD copy comes to the day's Photos folder. Switches a movie mode to the photo mode set with set_app_option photo_mode.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            guard s.photoAvailable else { return .failure("Not possible now: " + (s.busyMessage ?? (s.isRecording ? "recording" : s.timelapse?.running == true ? "a timelapse is running" : "the camera is not ready"))) }
            let before = s.lastPhoto
            s.lastError = nil
            s.takePhoto()
            _ = await wait(40) { s.busyMessage == nil && (s.lastPhoto != before || s.lastError != nil) }
            if let photo = s.lastPhoto, photo != before { return .text("Photo saved: \(photo.path)") }
            return .failure(s.lastError ?? "No photo came")
        },

        Tool(name: "start_timelapse", description: "Start a timelapse: a photo every interval, then a movie of them. Leave out what should stay as last set.",
             properties: ["interval_seconds": number("Seconds between photos (at least 4)", min: TimelapsePlan.minInterval),
                          "photos": number("How many photos (at least 2)", min: 2),
                          "fps": number("Movie frames per second (24, 25 or 30)", min: 1, max: 60),
                          "hold_focus": bool("Focus on the first photo, then hold it"),
                          "photo_mode": string("Photo mode to use", CameraService.photoModes)],
             required: [], readOnly: false, destructive: false) { s, a in
            var plan = s.timelapsePlan
            if let v = (a["interval_seconds"] as? NSNumber)?.doubleValue { plan.interval = v }
            if let v = (a["photos"] as? NSNumber)?.intValue { plan.frames = v }
            if let v = (a["fps"] as? NSNumber)?.intValue { plan.fps = v }
            if let v = a["hold_focus"] as? Bool { plan.lockFocus = v }
            if let m = a["photo_mode"] as? String, CameraService.photoModes.contains(m) { s.preferredPhotoMode = m }
            s.timelapsePlan = plan.usable
            s.lastError = nil
            s.startTimelapse()
            return s.timelapse?.running == true ? .text("Timelapse started: \(plan.usable.summary)") : .failure(s.lastError ?? "Not started")
        },
        Tool(name: "stop_timelapse", description: "End the timelapse after the photo in hand; the movie is made from the photos taken.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            guard s.timelapse?.phase == .shooting else { return .text("No timelapse is shooting") }
            s.stopTimelapse()
            _ = await wait(60) { s.timelapse?.running != true }
            if case .finished(let url) = s.timelapse?.phase { return .text("Movie made: \(url.path)") }
            return .data(status(s)["timelapse"] ?? [:])
        },

        Tool(name: "autofocus", description: "Focus once (a half press of the shutter button).",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in s.triggerAutofocus(); return .text("Focusing") },
        Tool(name: "manual_focus_step", description: "Move the focus while on manual focus: negative nearer, positive farther; 1 is a small step, 7 a large one.",
             properties: ["step": number("-7 … 7, not 0", min: -7, max: 7)], required: ["step"], readOnly: false, destructive: false) { s, a in
            guard let step = (a["step"] as? NSNumber)?.intValue, step != 0, abs(step) <= 7 else { return .failure("step is -7 … 7, not 0") }
            s.setRange("/main/actions/manualfocus", value: Double(step)); return .text("Focus moved \(step)")
        },
        Tool(name: "touch_focus", description: "Focus (or track, see set_app_option touch_tracks) at a point of the picture, as fractions from the top left.",
             properties: ["x": number("0 left … 1 right", min: 0, max: 1), "y": number("0 top … 1 bottom", min: 0, max: 1)],
             required: ["x", "y"], readOnly: false, destructive: false) { s, a in
            guard let x = (a["x"] as? NSNumber)?.doubleValue, let y = (a["y"] as? NSNumber)?.doubleValue else { return .failure("x and y are needed") }
            guard s.touchAvailable else { return .failure("Touch focus is not available now (Wi-Fi only, not at 100p)") }
            s.touchFocus(at: CGPoint(x: x, y: y)); return .text("Touched at \(x), \(y)")
        },
        Tool(name: "cancel_touch_focus", description: "End touch focus or tracking.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in s.cancelTouchFocus(); return .text("Cancelled") },
        Tool(name: "zoom", description: "Zoom in or out for a while (Wi-Fi only), then stop.",
             properties: ["direction": string("in or out", ["in", "out"]), "seconds": number("How long, 0.1 … 5", min: 0.1, max: 5)],
             required: ["direction"], readOnly: false, destructive: false) { s, a in
            guard s.zoomAvailable else { return .failure("Zoom is not available now") }
            let dir = (a["direction"] as? String) == "out" ? -1 : 1
            let seconds = min(5, max(0.1, (a["seconds"] as? NSNumber)?.doubleValue ?? 0.5))
            s.zoom(dir)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            s.zoom(0)
            _ = await wait(3) { s.zoomDirection == 0 }
            return .text("Zoomed \(dir > 0 ? "in" : "out") for \(seconds) s; position \(s.zoomPosition.map { "\($0)" } ?? "unknown")")
        },

        Tool(name: "get_live_view_image", description: "The camera's current live view picture (JPEG).",
             properties: [:], required: [], readOnly: true, destructive: false) { s, _ in
            guard s.previewEnabled else { return .failure("Live view is off in the app; set_app_option live_view true") }
            guard let image = s.preview.image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                return .failure("No picture yet" + (s.lastPreviewError.map { ": \($0)" } ?? ""))
            }
            return McpToolResult(content: [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
                                           ["type": "text", "text": "\(rep.pixelsWide)×\(rep.pixelsHigh), \(String(format: "%.1f", s.preview.fps)) fps"]])
        },

        Tool(name: "list_presets", description: "The ready-made and saved presets, what each sets, and which one is applied on connect.",
             properties: [:], required: [], readOnly: true, destructive: false) { s, _ in
            .data(s.allPresets.map { p -> [String: Any] in
                ["name": p.name, "built_in": p.builtIn, "note": p.note, "sets": p.summary,
                 "matches_camera_now": p.matches(s.configs), "on_connect": s.startupPresetID == p.id]
            })
        },
        Tool(name: "apply_preset", description: "Apply a preset by its name.",
             properties: ["name": string("Preset name from list_presets")], required: ["name"], readOnly: false, destructive: false) { s, a in
            guard let p = preset(named: a["name"] as? String ?? "", in: s) else { return .failure("No preset of that name") }
            guard s.presetsAvailable else { return .failure("Presets are not available now (recording, copying or a timelapse)") }
            s.applyPreset(p)
            _ = await wait(60) { s.applyingPreset == nil }
            return .text(s.presetOutcome?.text ?? "Applied")
        },
        Tool(name: "save_preset", description: "Save the camera's present settings as a preset (replaces one of the same name).",
             properties: ["name": string("Name"),
                          "groups": ["type": "array", "items": ["type": "string", "enum": PresetGroup.allCases.map(\.rawValue)],
                                     "description": "Which groups to keep (all when left out)"]],
             required: ["name"], readOnly: false, destructive: false) { s, a in
            let names = a["groups"] as? [String]
            let groups = Set(PresetGroup.allCases.filter { names?.contains($0.rawValue) ?? true })
            return s.savePreset(name: a["name"] as? String ?? "", groups: groups) ? .text("Saved") : .failure("Not saved (no name, or nothing can be saved now)")
        },
        Tool(name: "delete_preset", description: "Delete one of the presets saved in the app (not a ready-made one). The camera's settings stay as they are.",
             properties: ["name": string("Preset name")], required: ["name"], readOnly: false, destructive: true) { s, a in
            guard let p = preset(named: a["name"] as? String ?? "", in: s), !p.builtIn else { return .failure("No saved preset of that name") }
            s.deletePreset(p.id); return .text("Deleted the preset \(p.name)")
        },
        Tool(name: "set_preset_on_connect", description: "Choose the preset applied by itself when the camera connects, or none.",
             properties: ["name": string("Preset name, or none")], required: ["name"], readOnly: false, destructive: false) { s, a in
            let name = a["name"] as? String ?? ""
            if name.lowercased() == "none" || name.isEmpty { s.startupPresetID = nil; return .text("No preset on connect") }
            guard let p = preset(named: name, in: s) else { return .failure("No preset of that name") }
            s.startupPresetID = p.id; return .text("\(p.name) is applied on connect")
        },

        Tool(name: "set_camera_clock", description: "Set the camera's date, time and time zone to this Mac's now.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            guard s.clockAvailable else { return .failure("Not now (recording, copying or not connected)") }
            let before = s.clockSetAt
            s.setCameraClockNow()
            _ = await wait(10) { s.clockSetAt != before }
            return s.clockSetAt != before ? .text("Camera clock set") : .failure(s.lastError ?? "No answer")
        },

        Tool(name: "list_clips", description: "Clips and photos on the card as last read, and whether each is on this Mac.",
             properties: [:], required: [], readOnly: true, destructive: false) { s, _ in
            .data(["source": s.clipSource.map { "\($0)" } ?? NSNull(), "read_at": iso(s.cameraClipsReadAt), "files": clips(s)])
        },
        Tool(name: "refresh_clip_list", description: "Read the card's list again (over Wi-Fi this pauses live view and control for a while).",
             properties: [:], required: [], readOnly: true, destructive: false) { s, _ in
            await s.refreshClips(); return .text("\(s.clips.count) files on the card")
        },
        Tool(name: "copy_clips", description: "Copy the named clips or photos from the card to the download folder. Nothing on the card is changed, nothing on the Mac replaced.",
             properties: ["names": ["type": "array", "items": ["type": "string"], "description": "File names, e.g. C0208.MP4"]],
             required: ["names"], readOnly: false, destructive: false) { s, a in
            let names = Set((a["names"] as? [String] ?? []).map { $0.uppercased() })
            let picked = s.clips.filter { names.contains($0.name.uppercased()) }
            guard !picked.isEmpty else { return .failure("None of those are on the card list; refresh_clip_list first?") }
            s.download(picked); return .text("Copying \(picked.count) file(s); see get_status card_activity")
        },
        Tool(name: "copy_new_clips", description: "Copy every clip and photo not yet on this Mac.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            s.downloadNew(); return .text("Copying the new files; see get_status card_activity")
        },
        Tool(name: "copy_waiting_takes", description: "Copy the takes recorded since the last automatic copy.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            await s.copyWaitingTakes(); return .text("Done; \(s.pendingTakes) take(s) still waiting")
        },
        Tool(name: "stop_copy", description: "Stop a copy after the piece in flight; what is copied is kept and continued later.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in s.stopCardCopy(); return .text("Stopping") },
        Tool(name: "eject_card", description: "Eject the card when it is mounted as a disk.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in s.ejectCard(); return .text("Ejecting") },

        Tool(name: "erase_card", description: "Ask to erase every file on the camera's card (only when the card is mounted as a disk). This does NOT erase: it opens a confirmation in the app listing what would be lost, and a person must type ERASE there.",
             properties: [:], required: [], readOnly: false, destructive: true) { s, _ in
            s.lastError = nil
            s.prepareWipe()
            if let plan = s.wipePlan {
                return .data(["asked": true, "what": plan.summary, "not_on_mac": plan.notOnMac,
                              "next": "A person must type \(CardWipe.confirmWord) in the app's window to erase. Nothing has been deleted."])
            }
            return .failure(s.lastError ?? "Not possible now")
        },

        Tool(name: "set_up_board", description: "Open the app's sheet that writes the bridge program to an ESP32-C3 board (Seeed XIAO ESP32-C3) on USB, needed once per board. This does NOT write: it lists the boards found and a person clicks Install in the app's window.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in
            s.openBoardSetup()
            let ports = s.boardSetup?.ports ?? []
            return .data(["opened": true, "boards": ports.map { ["port": $0.path, "mac": $0.serial ?? ""] },
                          "bridge_program_version": s.boardSetup?.imageVersion ?? 0,
                          "next": ports.isEmpty ? "No Espressif board is on USB; plug one in." : "A person must click Install Bridge Program in the app's window."])
        },

        Tool(name: "get_app_options", description: "The app's own options.",
             properties: [:], required: [], readOnly: true, destructive: false) { s, _ in .data(options(s)) },
        Tool(name: "set_app_option", description: "Change one of the app's own options (see get_app_options for names and values).",
             properties: ["option": string("Option name", optionNames), "value": string("New value: true/false, a mode name, a path or an address")],
             required: ["option", "value"], readOnly: false, destructive: false) { s, a in
            setOption(s, a["option"] as? String ?? "", (a["value"] as? String) ?? (a["value"] as? NSNumber)?.stringValue ?? "\(a["value"] ?? "")")
        },

        Tool(name: "clear_stop_alert", description: "Close the stop alert banner.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in s.stopAlert = nil; return .text("Closed") },
        Tool(name: "try_stop_alert", description: "Play the stop alert with a made-up full card (sound, Dock, notification).",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in s.tryStopAlert(); return .text("Played") },
        Tool(name: "retry_connection", description: "Look for the camera again now.",
             properties: [:], required: [], readOnly: false, destructive: false) { s, _ in s.retryWifi(); return .text("Looking") },
    ]

    static let optionNames = ["auto_copy", "stop_alert", "clock_on_connect", "movie_mode", "photo_mode", "live_view",
                              "live_view_smooth", "touch_tracks", "wifi", "camera_address", "download_folder"]

    static func options(_ s: CameraStore) -> [String: Any] {
        [
            "auto_copy": s.autoCopy,
            "stop_alert": s.stopAlertSound,
            "clock_on_connect": s.clockSync,
            "movie_mode": s.preferredMovieMode,
            "photo_mode": s.preferredPhotoMode,
            "live_view": s.previewEnabled,
            "live_view_smooth": s.liveViewSmooth,
            "touch_tracks": s.configs["d283"]?.current == "4",
            "wifi": s.wifiEnabled,
            "camera_address": s.wifiManualHost,
            "download_folder": s.downloadRoot.path,
            "timelapse_plan": s.timelapsePlan.summary,
            "preset_on_connect": s.allPresets.first { $0.id == s.startupPresetID }?.name ?? "none",
            "movie_mode_choices": (s.configs["expprogram"]?.options.map(\.value).filter { $0.hasPrefix("Movie (") }) ?? [],
            "photo_mode_choices": CameraService.photoModes,
        ]
    }

    static func setOption(_ s: CameraStore, _ name: String, _ value: String) -> McpToolResult {
        let on = ["true", "yes", "on", "1"].contains(value.lowercased())
        switch name {
        case "auto_copy": s.autoCopy = on
        case "stop_alert": s.stopAlertSound = on
        case "clock_on_connect": s.clockSync = on
        case "live_view": s.previewEnabled = on
        case "live_view_smooth": s.setLiveViewSmooth(on)
        case "touch_tracks": s.setTouchTracks(on)
        case "wifi": s.wifiEnabled = on
        case "camera_address": s.wifiManualHost = value.trimmingCharacters(in: .whitespaces)
        case "movie_mode":
            guard value.hasPrefix("Movie (") else { return .failure("A movie mode such as Movie (M) or Movie (Scene)") }
            s.preferredMovieMode = value
        case "photo_mode":
            guard CameraService.photoModes.contains(value) else { return .failure("One of " + CameraService.photoModes.joined(separator: ", ")) }
            s.preferredPhotoMode = value
        case "download_folder":
            let url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch { return .failure("Cannot use \(url.path): \(error.localizedDescription)") }
            s.downloadRoot = url
            UserDefaults.standard.set(url.path, forKey: "downloadRoot")
        default:
            return .failure("Unknown option. Options: " + optionNames.joined(separator: ", "))
        }
        return .text("\(name) set to \(value)")
    }

    static func listing() -> [[String: Any]] { all.map(\.listing) }

    static func call(_ name: String, _ args: [String: Any], store: CameraStore) async -> McpToolResult {
        guard let tool = all.first(where: { $0.name == name }) else { return McpToolResult(content: [], unknownTool: true) }
        return await tool.run(store, args)
    }
}

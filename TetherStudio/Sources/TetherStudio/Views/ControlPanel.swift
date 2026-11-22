import SwiftUI

struct ControlPanel: View {
    @EnvironmentObject var store: CameraStore

    /// Map a leaf config name to its full PTP path.
    static func path(for leaf: String) -> String { CameraService.path(forLeaf: leaf) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Presets") {
                    PresetsSection()
                }

                section("Zoom") {
                    zoomControls
                    optionalPicker("Zoom type", "d25f")
                }

                section("Exposure") {
                    movieModePicker
                    configPicker("Shutter", "shutterspeed")
                    configPicker("Aperture", "f-number")
                    configPicker("ISO", "iso")
                    configPicker("Exp. comp.", "exposurecompensation")
                    configPicker("Metering", "exposuremetermode")
                }

                section("Movie") {
                    configPicker("Format", "d241", label: MovieSettings.format)
                    configPicker("Quality", "d242", label: MovieSettings.quality)
                }
                .disabled(store.isRecording)

                section("Color") {
                    configPicker("White balance", "whitebalance")
                    RangeRow(
                        title: "Color temp",
                        config: store.configs["colortemperature"],
                        path: Self.path(for: "colortemperature"),
                        unit: "K",
                        onSet: { store.setRange($0, value: $1) }
                    )
                    shiftRow("Shift amber–blue", "d21c")
                    shiftRow("Shift green–mag.", "d210")
                }

                if ["d23f", "d240", "d21b", "dro"].contains(where: { store.configs[$0] != nil }) {
                    section("Look") {
                        optionalPicker("Picture profile", "d23f")
                        optionalPicker("Creative style", "d240")
                        optionalPicker("Picture effect", "d21b")
                        optionalPicker("D-Range Opt.", "dro")
                    }
                }

                section("Focus") {
                    configPicker("Focus mode", "focusmode")
                    HStack {
                        Text("Autofocus").foregroundStyle(.secondary).frame(width: settingsLabelWidth, alignment: .leading)
                        Button("Focus now") { store.triggerAutofocus() }
                            .disabled(store.configs["focusmode"]?.current == "Manual")
                            .help("Has the camera focus once (⌘F)")
                    }
                    RangeRow(
                        title: "Focus distance",
                        config: store.configs["focalposition"],
                        path: Self.path(for: "focalposition"),
                        unit: "",
                        onSet: { store.setRange($0, value: $1) }
                    )
                }

                section("Focus area") {
                    configPicker("Area", "focusarea")
                    touchFunction
                    manualFocusNudge
                    if let state = store.configs["focusindication"]?.current {
                        HStack {
                            Text("Focus").foregroundStyle(.secondary).frame(width: settingsLabelWidth, alignment: .leading)
                            Text(state).foregroundStyle(state.contains("Locked") || state.contains("Focused") ? .green : .secondary)
                        }
                    }
                }

                if let err = readOnlyHint {
                    Label(err, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(14)
        }
    }

    // MARK: - pieces

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
            Divider()
        }
    }

    private var movieModePicker: some View {
        AdaptiveRow(title: "Mode") {
            if let cfg = store.configs["expprogram"], !cfg.options.isEmpty {
                // In a photo mode the photo modes are offered, otherwise the movie modes; Record and
                // Take Photo each switch to the other kind by themselves.
                let photo = CameraService.isPhotoMode(cfg.current)
                let modes = photo
                    ? cfg.options.filter { CameraService.photoModes.contains($0.value) }
                    : cfg.options.filter { $0.value.hasPrefix("Movie (") }
                Picker("", selection: Binding(
                    get: {
                        modes.first { $0.value == cfg.current }?.index
                            ?? modes.first { $0.value == (photo ? store.preferredPhotoMode : store.preferredMovieMode) }?.index
                            ?? modes.first?.index ?? -1
                    },
                    set: { idx in
                        if let opt = modes.first(where: { $0.index == idx }) {
                            if photo { store.preferredPhotoMode = opt.value } else { store.preferredMovieMode = opt.value }
                            store.setOption(Self.path(for: "expprogram"), index: idx)
                        }
                    }
                )) {
                    ForEach(modes) { opt in
                        Text(opt.value == "Intelligent Auto" ? "Auto" : shortMode(opt.value)).tag(opt.index)
                    }
                }
                .help(photo ? "Photo modes. Record switches to \(store.preferredMovieMode) by itself."
                      : "Movie modes. Take Photo switches to \(store.preferredPhotoMode) by itself.")
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(cfg.readOnly)
            } else {
                Text(store.configs["expprogram"]?.current ?? "—").foregroundStyle(.tertiary)
            }
        }
    }

    // Press and hold: the lens moves while a button is down and stops on release.
    @ViewBuilder
    private var zoomControls: some View {
        HStack(spacing: 10) {
            HoldButton(title: "Wide", systemImage: "minus.magnifyingglass",
                       onPress: { store.zoom(-1) }, onRelease: { store.zoom(0) })
            VStack(spacing: 3) {
                ProgressView(value: store.zoomPosition?.fraction ?? 0)
                Text(store.zoomDirection != 0 ? "Zooming…" : store.zoomPosition?.label ?? "—")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HoldButton(title: "Tele", systemImage: "plus.magnifyingglass",
                       onPress: { store.zoom(1) }, onRelease: { store.zoom(0) })
        }
        .disabled(!store.zoomAvailable)
        if !store.zoomAvailable {
            Text(store.link == .usb
                 ? "Zoom works over the Wi-Fi connection only."
                 : store.cardActivity != nil ? "Zoom is back when the clips have been handed over."
                 : store.mode == .pcRemote ? "The camera says zoom is not available right now." : "Connect over Wi-Fi to zoom.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// What a click on the live picture does (the camera's "touch function").
    @ViewBuilder
    private var touchFunction: some View {
        AdaptiveRow(title: "Click picture") {
            Picker("", selection: Binding(get: { store.touchTracks }, set: { store.setTouchTracks($0) })) {
                Text("Focus there").tag(false)
                Text("Track subject").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .disabled(!store.touchAvailable && !store.touchCancelAvailable)
        .help("Click on the live picture to focus on that spot or to follow that subject. Wi-Fi connection only.")
        if store.mode == .pcRemote && store.link == .usb {
            Text("Click-to-focus works over the Wi-Fi connection only.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Small manual-focus steps (the camera accepts them in Manual focus mode only).
    private var manualFocusNudge: some View {
        AdaptiveRow(title: "MF step") {
            HStack(spacing: 4) {
                ForEach([(-3, "Near ◀◀"), (-1, "◀"), (1, "▶"), (3, "▶▶ Far")], id: \.0) { step, label in
                    Button(label) { store.setRange("/main/actions/manualfocus", value: Double(step)) }
                }
            }
        }
        .controlSize(.small)
        .disabled(store.configs["focusmode"]?.current != "Manual")
        .help("Moves the focus a little nearer or farther. Set Focus Mode to Manual first.")
    }

    private func shortMode(_ v: String) -> String {
        // "Movie (M)" → "M"
        guard let open = v.lastIndex(of: "("), let close = v.lastIndex(of: ")"), open < close else { return v }
        return String(v[v.index(after: open)..<close])
    }

    private func configPicker(_ title: String, _ leaf: String, label: @escaping (String) -> String = { $0 }) -> some View {
        ConfigPicker(title: title, config: store.configs[leaf], path: Self.path(for: leaf), label: label) { idx in
            store.setOption(Self.path(for: leaf), index: idx)
        }
    }

    /// A setting not every connection offers: the row is there only when the camera lists it.
    @ViewBuilder
    private func optionalPicker(_ title: String, _ leaf: String) -> some View {
        if store.configs[leaf] != nil {
            configPicker(title, leaf, label: { SettingNames.label(leaf: leaf, value: $0) })
        }
    }

    /// A white balance shift: a slider where the camera gives a range, a menu where it gives a list.
    @ViewBuilder
    private func shiftRow(_ title: String, _ leaf: String) -> some View {
        if let cfg = store.configs[leaf] {
            if cfg.isRange {
                RangeRow(title: title, config: cfg, path: Self.path(for: leaf), unit: "",
                         format: { SettingNames.label(leaf: leaf, value: String(Int($0))) },
                         onSet: { store.setRange($0, value: $1) })
            } else {
                optionalPicker(title, leaf)
            }
        }
    }

    private var readOnlyHint: String? {
        let ro = ["shutterspeed", "f-number", "iso"].compactMap { store.configs[$0] }
        guard !ro.isEmpty else { return nil }
        if ro.allSatisfy({ !$0.readOnly }) { return nil }
        return "Some settings are read-only until the camera is in a matching mode (try Movie S/M)."
    }
}

// MARK: - reusable rows

/// The width of a row's title column in the settings sidebar.
let settingsLabelWidth: CGFloat = 100

/// A title and a wide control side by side when the sidebar has room, the title above it when not.
struct AdaptiveRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).foregroundStyle(.secondary).frame(width: settingsLabelWidth, alignment: .leading)
                control().fixedSize()
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                control()
            }
        }
    }
}

struct ConfigPicker: View {
    let title: String
    let config: CameraConfig?
    let path: String
    /// Turns the camera's value into what is shown (for settings the camera reports as bare numbers).
    var label: (String) -> String = { $0 }
    var onSet: (Int) -> Void

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: settingsLabelWidth, alignment: .leading)
            if let cfg = config, !cfg.options.isEmpty {
                Picker("", selection: Binding(
                    get: { cfg.currentIndex ?? -1 },
                    set: { if $0 >= 0 { onSet($0) } }
                )) {
                    ForEach(cfg.options) { Text(label($0.value)).tag($0.index) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(cfg.readOnly)
            } else {
                // No choices: the camera sets this itself in the current mode (it then also reports no value).
                Text(config?.current.flatMap { $0.isEmpty ? nil : label($0) } ?? "—").foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .help(config.map { "\($0.label)\($0.readOnly ? " · read-only in current camera mode" : "")" } ?? title)
    }
}

struct RangeRow: View {
    let title: String
    let config: CameraConfig?
    let path: String
    let unit: String
    /// How a value is written next to the slider; nil = the whole number and the unit.
    var format: ((Double) -> String)? = nil
    let onSet: (String, Double) -> Void

    @State private var local: Double?

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary).frame(width: settingsLabelWidth, alignment: .leading)
            if let cfg = config, cfg.isRange, cfg.readOnly, let bottom = cfg.bottom, let top = cfg.top, top > bottom {
                // The camera only reports this value here (the focus distance always, the colour
                // temperature while white balance is automatic): show it, do not pretend it can be dragged.
                let value = min(max(cfg.currentValueDouble ?? bottom, bottom), top)
                ProgressView(value: value - bottom, total: top - bottom)
                Text(text(value))
                    .monospacedDigit().frame(width: 54, alignment: .trailing)
                    .foregroundStyle(.tertiary)
            } else if let cfg = config, cfg.isRange, let bottom = cfg.bottom, let top = cfg.top {
                Slider(
                    value: Binding(
                        get: { local ?? cfg.currentValueDouble ?? (bottom + top) / 2 },
                        set: { local = $0 }
                    ),
                    in: bottom...top,
                    step: cfg.step ?? 1
                ) { editing in
                    if !editing, let v = local {
                        onSet(path, v)
                        local = nil
                    }
                }
                Text(text(local ?? cfg.currentValueDouble ?? 0))
                    .monospacedDigit().frame(width: 54, alignment: .trailing)
                    .foregroundStyle(.secondary)
            } else {
                Text(config?.current ?? "—").foregroundStyle(.tertiary)
            }
        }
        .disabled(config?.readOnly ?? true)
        .help(config.map { "\($0.label)\($0.readOnly ? " · shown only; the camera sets it in the current mode" : "")" } ?? title)
    }

    private func text(_ value: Double) -> String {
        format?(value) ?? "\(Int(value))\(unit)"
    }
}

/// A button that reports press and release separately (for hold-to-zoom).
struct HoldButton: View {
    let title: String
    let systemImage: String
    let onPress: () -> Void
    let onRelease: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var down = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(down ? Color.accentColor.opacity(0.45) : Color(nsColor: .controlColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.4)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if isEnabled && !down { down = true; onPress() }
                    }
                    .onEnded { _ in
                        if down { down = false; onRelease() }
                    }
            )
            .help("Hold to zoom, release to stop")
    }
}

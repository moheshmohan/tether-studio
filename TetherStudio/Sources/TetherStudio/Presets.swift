import Foundation

// Presets: a named package of camera settings that is applied with one click.
//
// A preset holds settings by the camera's own value text ("Movie (P)", "1/50", "Auto ISO"), never
// by position in a list: the lists change with the mode and the lens. Applying one goes through the
// same whitelisted setter as every single control in the window (`CameraService.setConfig`), one
// setting after the other in the order of `PresetCatalogue.fields`, and waits for the camera to
// report each value before the next one is sent.

/// The camera's bare numbers in words, for the settings libgphoto2 has no names for.
/// Picture profile, picture effect, zoom setting and the white balance shifts follow Sony's own app
/// (EnumPictureEffect, EnumZoomSetting, RangeBiaxialFineTuning…); the creative style numbers are that
/// app's list as this camera reports it (1 2 3 4 5 6 13 = its seven styles).
enum SettingNames {
    static let creativeStyles: [String: String] = [
        "1": "Standard", "2": "Vivid", "3": "Portrait", "4": "Landscape", "5": "Sunset", "6": "Black & White",
        "7": "Light", "8": "Neutral", "9": "Clear", "10": "Deep", "11": "Night View", "12": "Autumn Leaves",
        "13": "Sepia",
    ]

    static let pictureEffects: [String: String] = [
        "32768": "Off", "32769": "Toy Camera: Normal", "32770": "Toy Camera: Cool", "32771": "Toy Camera: Warm",
        "32772": "Toy Camera: Green", "32773": "Toy Camera: Magenta", "32784": "Pop Color",
        "32800": "Posterization: B/W", "32801": "Posterization: Color", "32816": "Retro Photo",
        "32832": "Soft High-key", "32848": "Partial Color: Red", "32849": "Partial Color: Green",
        "32850": "Partial Color: Blue", "32851": "Partial Color: Yellow", "32864": "High Contrast Mono",
        "32880": "Soft Focus: Low", "32881": "Soft Focus: Mid", "32882": "Soft Focus: High",
        "32896": "HDR Painting: Low", "32897": "HDR Painting: Mid", "32898": "HDR Painting: High",
        "32912": "Rich-tone Mono", "32928": "Miniature: Auto", "32929": "Miniature: Top",
        "32930": "Miniature: Middle (horizontal)", "32931": "Miniature: Bottom", "32932": "Miniature: Right",
        "32933": "Miniature: Middle (vertical)", "32934": "Miniature: Left", "32944": "Watercolor",
        "32960": "Illustration: Low", "32961": "Illustration: Mid", "32962": "Illustration: High",
    ]

    static let zoomSettings: [String: String] = [
        "1": "Optical zoom only", "2": "Smart zoom only", "3": "Clear Image Zoom", "4": "Digital zoom",
    ]

    static let touchFunctions: [String: String] = ["3": "Focus there", "4": "Track subject"]

    static func pictureProfile(_ value: String) -> String {
        value == "0" ? "Off" : "PP\(value)"
    }

    /// A white balance shift: 192 is the middle, a quarter step per unit. `low` and `high` are the
    /// letters of the two directions (B and A for amber–blue, M and G for green–magenta).
    static func shift(_ value: String, low: String, high: String) -> String {
        guard let number = Double(value) else { return value }
        let steps = (number - 192) / 4
        if steps == 0 { return "0" }
        let size = abs(steps)
        let text = size == size.rounded() ? String(Int(size)) : String(size)
        return (steps < 0 ? low : high) + text
    }

    /// What a setting's value is called in the window.
    static func label(leaf: String, value: String) -> String {
        switch leaf {
        case "d241": return MovieSettings.format(value)
        case "d242": return MovieSettings.quality(value)
        case "d23f": return pictureProfile(value)
        case "d240": return creativeStyles[value] ?? "Style \(value)"
        case "d21b": return pictureEffects[value] ?? "Effect \(value)"
        case "d25f": return zoomSettings[value] ?? "Zoom setting \(value)"
        case "d283": return touchFunctions[value] ?? value
        case "d21c": return shift(value, low: "B", high: "A")
        case "d210": return shift(value, low: "M", high: "G")
        case "colortemperature": return (Double(value).map { String(Int($0)) } ?? value) + " K"
        case "expprogram": return value.replacingOccurrences(of: "Movie (", with: "Movie ").replacingOccurrences(of: ")", with: "")
        default: return value
        }
    }
}

/// One setting a preset can carry.
struct PresetField: Equatable {
    let leaf: String
    let title: String
    let group: PresetGroup
}

enum PresetGroup: String, CaseIterable, Codable, Identifiable {
    case movie = "Mode and movie format"
    case focus = "Focus"
    case colour = "Colour"
    case exposure = "Exposure"
    case look = "Look"

    var id: String { rawValue }
}

enum PresetCatalogue {
    /// Every setting a preset can carry, in the order they are sent to the camera. The order matters:
    /// the mode decides which exposure settings can be set, the format decides which qualities exist,
    /// the white balance has to be on "colour temperature" before a temperature is taken, and a
    /// picture profile or a picture effect locks the creative style.
    static let fields: [PresetField] = [
        PresetField(leaf: "expprogram", title: "Mode", group: .movie),
        PresetField(leaf: "d241", title: "Format", group: .movie),
        PresetField(leaf: "d242", title: "Quality", group: .movie),
        PresetField(leaf: "d25f", title: "Zoom setting", group: .movie),
        PresetField(leaf: "focusmode", title: "Focus mode", group: .focus),
        PresetField(leaf: "focusarea", title: "Focus area", group: .focus),
        PresetField(leaf: "d283", title: "Click on picture", group: .focus),
        PresetField(leaf: "whitebalance", title: "White balance", group: .colour),
        PresetField(leaf: "colortemperature", title: "Colour temperature", group: .colour),
        PresetField(leaf: "d21c", title: "WB shift amber–blue", group: .colour),
        PresetField(leaf: "d210", title: "WB shift green–magenta", group: .colour),
        PresetField(leaf: "iso", title: "ISO", group: .exposure),
        PresetField(leaf: "shutterspeed", title: "Shutter", group: .exposure),
        PresetField(leaf: "f-number", title: "Aperture", group: .exposure),
        PresetField(leaf: "exposurecompensation", title: "Exposure compensation", group: .exposure),
        PresetField(leaf: "exposuremetermode", title: "Metering", group: .exposure),
        PresetField(leaf: "d23f", title: "Picture profile", group: .look),
        PresetField(leaf: "d21b", title: "Picture effect", group: .look),
        PresetField(leaf: "dro", title: "D-Range Optimizer", group: .look),
        PresetField(leaf: "d240", title: "Creative style", group: .look),
    ]

    static func field(_ leaf: String) -> PresetField? { fields.first { $0.leaf == leaf } }
    static func position(_ leaf: String) -> Int { fields.firstIndex { $0.leaf == leaf } ?? Int.max }

    /// Settings where a value that is not on offer is replaced by the nearest one that is (another
    /// lens opens less wide; another mode has fewer shutter speeds).
    static let nearestAllowed: Set<String> = ["shutterspeed", "f-number", "iso", "exposurecompensation"]
}

struct PresetSetting: Codable, Equatable {
    var leaf: String
    /// The wanted value. More than one: alternatives in order of preference, the first the camera
    /// offers is taken (a camera set to 60 Hz has 30p where one set to 50 Hz has 25p).
    var values: [String]

    init(_ leaf: String, _ values: String...) {
        self.leaf = leaf
        self.values = values
    }

    init(leaf: String, values: [String]) {
        self.leaf = leaf
        self.values = values
    }
}

struct Preset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var symbol: String = "slider.horizontal.3"
    var note: String = ""
    var settings: [PresetSetting]
    var builtIn: Bool = false

    /// The settings in the order they are sent; settings this app does not know are left out.
    var ordered: [PresetSetting] {
        settings.filter { PresetCatalogue.field($0.leaf) != nil }
            .sorted { PresetCatalogue.position($0.leaf) < PresetCatalogue.position($1.leaf) }
    }

    /// One line per setting, for the tooltip.
    var summary: String {
        ordered.map { setting in
            let title = PresetCatalogue.field(setting.leaf)?.title ?? setting.leaf
            return "\(title): " + setting.values.map { SettingNames.label(leaf: setting.leaf, value: $0) }.joined(separator: " or ")
        }.joined(separator: "\n")
    }

    /// The camera's settings as they are now, as a preset. Only what can be set right now is taken:
    /// a value the camera chooses itself in this mode (shutter in Movie P, the creative style while a
    /// picture profile is on) is not the user's setting and would be refused on the way back.
    static func capture(name: String, from configs: [String: CameraConfig], groups: Set<PresetGroup> = Set(PresetGroup.allCases),
                        id: String = UUID().uuidString) -> Preset {
        var settings: [PresetSetting] = []
        for field in PresetCatalogue.fields where groups.contains(field.group) {
            guard let cfg = configs[field.leaf], !cfg.readOnly, let current = cfg.current, !current.isEmpty else { continue }
            if cfg.isRange {
                guard let number = cfg.currentValueDouble else { continue }
                settings.append(PresetSetting(field.leaf, String(Int(number))))
            } else if cfg.options.contains(where: { $0.value == current }) {
                settings.append(PresetSetting(field.leaf, current))
            }
        }
        return Preset(id: id, name: name, symbol: "star", note: "", settings: settings)
    }

    /// Does the camera show this preset's settings right now? Every value the camera shows has to
    /// agree, also one it would not let be changed (in Movie (Scene) the white balance reads
    /// "Automatic" and is locked: a colour preset is not active then, whatever temperature is still
    /// stored). Settings the camera does not list, or lists without a value, are left out; at least
    /// one has to be there and agree.
    func matches(_ configs: [String: CameraConfig]) -> Bool {
        var agreed = 0
        for setting in ordered {
            switch PresetPlan.step(for: setting, in: configs[setting.leaf]) {
            case .already: agreed += 1
            case .choose, .slide, .noSuchValue: return false
            case .locked:
                if let shown = configs[setting.leaf]?.current, !shown.isEmpty { return false }
            case .notOffered: continue
            }
        }
        return agreed > 0
    }
}

/// What has to happen for one setting of a preset.
enum PresetStep: Equatable {
    case already                                        // the camera shows the value
    case choose(index: Int, value: String, nearest: Bool)
    case slide(value: Int)
    case notOffered                                     // the camera does not list this setting
    case locked                                         // the camera sets it itself in the current mode
    case noSuchValue                                    // not among the choices on offer right now

    var canWait: Bool {
        switch self {
        case .locked, .noSuchValue, .notOffered: return true
        default: return false
        }
    }
}

enum PresetPlan {
    static func step(for setting: PresetSetting, in config: CameraConfig?) -> PresetStep {
        guard let cfg = config else { return .notOffered }
        if cfg.isRange {
            guard var wanted = setting.values.compactMap({ Double($0) }).first else { return .noSuchValue }
            if let bottom = cfg.bottom, let top = cfg.top, top > bottom { wanted = min(max(wanted, bottom), top) }
            if cfg.currentValueDouble == wanted { return .already }
            return cfg.readOnly ? .locked : .slide(value: Int(wanted))
        }
        // Any of the wanted values that the camera shows already is good enough; otherwise the first
        // one it offers.
        if let current = cfg.current, setting.values.contains(current) { return .already }
        for value in setting.values {
            if !cfg.readOnly, let option = cfg.options.first(where: { $0.value == value }) {
                return .choose(index: option.index, value: option.value, nearest: false)
            }
        }
        if cfg.readOnly { return .locked }
        if PresetCatalogue.nearestAllowed.contains(setting.leaf), let wanted = setting.values.first.flatMap(number),
           let option = nearest(to: wanted, in: cfg.options) {
            if option.value == cfg.current { return .already }
            return .choose(index: option.index, value: option.value, nearest: true)
        }
        return cfg.options.isEmpty ? .locked : .noSuchValue
    }

    /// "1/50" → 0.02, "2.8" → 2.8, "F4" → 4, "-0.7" → -0.7, "0.5\"" → 0.5; nil for words ("Auto ISO", "Bulb").
    static func number(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.hasSuffix("\"") { t.removeLast() }
        if t.lowercased().hasPrefix("f/") { t.removeFirst(2) } else if t.lowercased().hasPrefix("f") { t.removeFirst() }
        let parts = t.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
        return parts.count == 1 ? Double(t) : nil
    }

    static func nearest(to wanted: Double, in options: [ConfigOption]) -> ConfigOption? {
        options.compactMap { option in number(option.value).map { (option, abs($0 - wanted)) } }
            .min { $0.1 < $1.1 }?.0
    }
}

/// What applying a preset did, for the line under the preset buttons.
struct PresetOutcome: Equatable {
    var name: String
    var set: [String] = []          // titles of settings sent and confirmed
    var kept: Int = 0               // already as wanted
    var adjusted: [String] = []     // "Aperture 3.5 (nearest to 1.8)"
    var skipped: [String] = []      // "Shutter (the camera sets it in this mode)"
    var failed: [String] = []       // "ISO (the camera did not report it back)"
    var seconds: Double = 0
    var stopped: String?            // why it ended early

    var ok: Bool { skipped.isEmpty && failed.isEmpty && stopped == nil }

    var text: String {
        var parts: [String] = []
        let changed = set.count + adjusted.count
        if let stopped {
            parts.append("\(name) stopped: \(stopped)")
        } else if changed == 0 && skipped.isEmpty && failed.isEmpty {
            parts.append("\(name): the camera already had all of it")
        } else {
            parts.append(String(format: "\(name): \(changed) set, \(kept) already right (%.0f s)", seconds))
        }
        if !adjusted.isEmpty { parts.append("Nearest value taken: " + adjusted.joined(separator: ", ")) }
        if !skipped.isEmpty { parts.append("Not set: " + skipped.joined(separator: ", ")) }
        if !failed.isEmpty { parts.append("Not confirmed: " + failed.joined(separator: ", ")) }
        return parts.joined(separator: ". ") + "."
    }
}

/// The user's own presets, kept in `~/Library/Application Support/Tether Studio/presets.json`.
struct PresetLibrary: Codable, Equatable {
    var presets: [Preset] = []

    static var url: URL {
        BridgeSettings.url.deletingLastPathComponent().appendingPathComponent("presets.json")
    }

    static func load(from url: URL = PresetLibrary.url) -> PresetLibrary {
        guard let data = try? Data(contentsOf: url),
              let library = try? JSONDecoder().decode(PresetLibrary.self, from: data) else { return PresetLibrary() }
        return library
    }

    func save(to url: URL = PresetLibrary.url) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Saves under a name: a preset of that name (upper and lower case alike) is replaced and keeps
    /// its place, a new name is added at the end.
    mutating func put(_ preset: Preset) {
        var new = preset
        new.builtIn = false
        if let i = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(new.name) == .orderedSame }) {
            new.id = presets[i].id
            presets[i] = new
        } else {
            presets.append(new)
        }
    }

    mutating func remove(id: String) {
        presets.removeAll { $0.id == id }
    }
}

extension Preset {
    // Movie qualities as the camera numbers them (see MovieSettings.quality). Each built-in names the
    // 50 Hz value first and the 60 Hz one second, so it works on a camera set either way.
    private static let auto: [PresetSetting] = [
        PresetSetting("focusmode", "AF-C"), PresetSetting("focusarea", "Wide"),
        PresetSetting("whitebalance", "Automatic"), PresetSetting("iso", "Auto ISO"),
        PresetSetting("exposurecompensation", "0"), PresetSetting("exposuremetermode", "Multi"),
    ]

    /// Ready-made packages. They use only values this camera has been seen to offer, and only
    /// settings that do not depend on the lens (no aperture).
    static let builtIns: [Preset] = [
        Preset(id: "builtin.auto4k", name: "Auto 4K", symbol: "wand.and.stars",
               note: "Everything automatic at the best quality.",
               settings: [PresetSetting("expprogram", "Movie (P)"), PresetSetting("d241", "8"),
                          PresetSetting("d242", "33", "32")] + auto
                   + [PresetSetting("d23f", "0"), PresetSetting("d21b", "32768"), PresetSetting("dro", "DRO Auto"),
                      PresetSetting("d240", "1")],
               builtIn: true),
        Preset(id: "builtin.quickhd", name: "Quick-copy HD", symbol: "hare",
               note: "HD at 16 Mbit/s: small files that copy to the Mac in about twice the clip's length.",
               settings: [PresetSetting("expprogram", "Movie (P)"), PresetSetting("d241", "9"),
                          PresetSetting("d242", "27", "26")] + auto,
               builtIn: true),
        Preset(id: "builtin.hd50", name: "Smooth HD", symbol: "figure.run",
               note: "HD at 50 or 60 frames a second for movement.",
               settings: [PresetSetting("expprogram", "Movie (P)"), PresetSetting("d241", "9"),
                          PresetSetting("d242", "4", "1")] + auto,
               builtIn: true),
        Preset(id: "builtin.slowmo", name: "Slow motion", symbol: "tortoise",
               note: "HD at 100 or 120 frames a second with a short shutter, to slow down afterwards.",
               settings: [PresetSetting("expprogram", "Movie (S)"), PresetSetting("d241", "9"),
                          PresetSetting("d242", "29", "28"), PresetSetting("shutterspeed", "1/200", "1/250"),
                          PresetSetting("iso", "Auto ISO"), PresetSetting("focusmode", "AF-C"),
                          PresetSetting("whitebalance", "Automatic")],
               builtIn: true),
        Preset(id: "builtin.film", name: "Film look", symbol: "film",
               note: "4K, shutter fixed at 1/50 for natural motion blur, the camera picks aperture and ISO.",
               settings: [PresetSetting("expprogram", "Movie (S)"), PresetSetting("d241", "8"),
                          PresetSetting("d242", "33", "34", "32"), PresetSetting("shutterspeed", "1/50"),
                          PresetSetting("iso", "Auto ISO"), PresetSetting("focusmode", "AF-C"),
                          PresetSetting("exposurecompensation", "0")],
               builtIn: true),
        // The format is kept; the frame rate goes to 25p or 30p (24p last), because at 50p and above the
        // camera allows nothing slower than 1/50 or 1/100 (seen 21 Nov: after Slow motion it took 1/100).
        Preset(id: "builtin.lowlight", name: "Low light", symbol: "moon.stars",
               note: "Slow shutter (1/25 or 1/30) and automatic ISO for dim rooms, at 25p or 30p in the format already set. Keep the camera still.",
               settings: [PresetSetting("expprogram", "Movie (S)"),
                          PresetSetting("d242", "33", "36", "5", "27", "32", "35", "2", "26", "34", "37", "3"),
                          PresetSetting("shutterspeed", "1/25", "1/30"),
                          PresetSetting("iso", "Auto ISO"), PresetSetting("exposuremetermode", "Multi"),
                          PresetSetting("exposurecompensation", "0")],
               builtIn: true),
        Preset(id: "builtin.daylight", name: "Daylight 5600 K", symbol: "sun.max",
               note: "Colour only: white balance fixed at 5600 K.",
               settings: [PresetSetting("whitebalance", "Choose Color Temperature"), PresetSetting("colortemperature", "5600")],
               builtIn: true),
        Preset(id: "builtin.tungsten", name: "Indoor 3200 K", symbol: "lightbulb",
               note: "Colour only: white balance fixed at 3200 K for warm lamps.",
               settings: [PresetSetting("whitebalance", "Choose Color Temperature"), PresetSetting("colortemperature", "3200")],
               builtIn: true),
        Preset(id: "builtin.tracking", name: "Follow subject", symbol: "scope",
               note: "Focus only: continuous autofocus over the whole picture, and a click on the picture follows that subject.",
               settings: [PresetSetting("focusmode", "AF-C"), PresetSetting("focusarea", "Wide"), PresetSetting("d283", "4")],
               builtIn: true),
    ]
}

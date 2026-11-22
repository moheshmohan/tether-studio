import Foundation
import AppKit
import Combine

enum CameraMode: Equatable {
    case disconnected
    case pcRemote
    case mtp

    var title: String {
        switch self {
        case .disconnected: return "Not connected"
        case .pcRemote: return "PC Remote · full control"
        case .mtp: return "MTP · file transfer"
        }
    }
}

struct ConfigOption: Identifiable, Hashable {
    let index: Int
    let value: String
    var id: Int { index }
}

struct CameraConfig: Identifiable, Equatable {
    let path: String
    let label: String
    let type: String          // RADIO / TOGGLE / RANGE / MENU / TEXT
    let readOnly: Bool
    let current: String?
    let options: [ConfigOption]
    let bottom: Double?
    let top: Double?
    let step: Double?

    var id: String { path }
    var leaf: String { CameraService.leaf(of: path) }
    var isRange: Bool { type == "RANGE" }
    var currentValueDouble: Double? {
        guard let c = current else { return nil }
        return Double(c.replacingOccurrences(of: ",", with: "."))
    }
    var currentIndex: Int? {
        guard let c = current else { return nil }
        return options.first { $0.value == c }?.index
    }

    /// The same control showing another value (for a value just sent that the camera has not reported yet).
    func with(current value: String) -> CameraConfig {
        CameraConfig(path: path, label: label, type: type, readOnly: readOnly, current: value, options: options,
                     bottom: bottom, top: top, step: step)
    }

    /// Does this control already show `value`? Numbers are compared as numbers ("4300" and "4300.0").
    func shows(_ value: String) -> Bool {
        if current == value { return true }
        if let a = currentValueDouble, let b = Double(value) { return a == b }
        return false
    }
}

struct ClipFile: Identifiable, Hashable, Codable {
    let number: Int        // gphoto2 file id within its folder
    let folder: String     // e.g. /store_00010001/2023-09-23
    let name: String
    let sizeBytes: UInt64
    let width: Int?
    let height: Int?
    let mime: String
    let unixTime: Int64
    /// Set when the file sits on a mounted card rather than behind libgphoto2.
    var diskURL: URL? = nil
    /// Set when the file is read over the camera's phone service: its handle there.
    var cameraHandle: UInt32? = nil

    var id: String { "\(folder)/\(name)#\(number)" }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(unixTime)) }
    var isVideo: Bool { mime.contains("video") }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file) }
    var dayFolder: String {
        guard diskURL != nil else { return String(folder.split(separator: "/").last ?? "") }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

struct CameraSnapshot: Equatable {
    var model = "—"
    var firmware = "—"
    var batteryPercent: Int?
    /// Seconds of recording that still fit on the card at the current movie setting.
    var remainingSeconds: Int?
    /// Photos that still fit on the card; only reported in a photo mode.
    var photosLeft: Int?
    /// The camera is in a photo mode: then the card is counted in photos, not in minutes.
    var photoMode = false
    var overheating = false

    var remainingLabel: String? {
        if photoMode { return photosLeft.map { "\($0) photos left" } }
        guard let s = remainingSeconds else { return nil }
        return s >= 3600 ? "\(s / 3600) h \((s % 3600) / 60) min left" : "\(s / 60) min left"
    }
}

enum DownloadPhase: Equatable {
    case running
    case done(URL)
    case failed(String)

    static func == (a: DownloadPhase, b: DownloadPhase) -> Bool {
        switch (a, b) {
        case (.running, .running): return true
        case (.done(let u1), .done(let u2)): return u1 == u2
        case (.failed, .failed): return true
        default: return false
        }
    }
}

/// Where the search for the camera on Wi-Fi stands. Drives the panel shown
/// while nothing is connected.
enum WifiState: Equatable {
    case idle                           // connected by USB, nothing to do
    case off                            // switched off by the user
    case searching
    case notFound
    case blocked                        // macOS Local Network permission denied
    case connecting(WifiCamera)
    case needsPairing(WifiCamera)       // camera does not know this Mac; open its Pairing screen
    case confirmOnCamera(WifiCamera)    // camera is asking to confirm this Mac
    case failed(String)
    case connected(String)              // address
}

/// Zoom position as the camera reports it (property 0xD25D "Zoom Bar Info"
/// and 0xD25C "Zoom Scale"; layout worked out on a ZV-E10, firmware 2.03):
/// the bar value's top byte is the number of zoom ranges, the next byte the
/// range in use (0 = the lens's optical range, 1 = Clear Image Zoom), and the
/// low 16 bits the position inside that range, 0…100.
struct ZoomPosition: Equatable {
    let ranges: Int
    let range: Int
    let position: Int       // 0…100 within the range
    let scale: Double       // 1.0…2.0, magnification added by Clear Image Zoom

    init?(bar: String?, scale: String?) {
        guard let bar, let raw = UInt32(bar.trimmingCharacters(in: .whitespaces)) else { return nil }
        ranges = max(1, Int(raw >> 24))
        range = Int((raw >> 16) & 0xFF)
        position = min(100, Int(raw & 0xFFFF))
        self.scale = (scale.flatMap { Double($0) } ?? 1000) / 1000
    }

    /// 0…1 across all ranges, for a single bar.
    var fraction: Double {
        min(1, (Double(min(range, ranges - 1)) + Double(position) / 100) / Double(ranges))
    }

    var label: String {
        range == 0 ? "Optical \(position)%" : String(format: "Clear Image Zoom %.1f×", scale)
    }
}

/// The camera's movie format (property 0xD241) and recording setting (0xD242) in words.
/// Values from Sony's own app (EnumFileFormatMovieMode, EnumRecordingSettingMovieMode; the
/// camera's numbers are one below that list's), checked against this camera: 9 is HD and
/// 25 is 50p 25M, which is what its clips are.
enum MovieSettings {
    static let format4K = "8", formatHD = "9"

    static func format(_ value: String) -> String {
        ["8": "4K (XAVC S 4K)", "9": "HD (XAVC S HD)"][value] ?? "Format \(value)"
    }

    static func quality(_ value: String) -> String {
        let known: [String: String] = [
            "1": "60p 50M", "2": "30p 50M", "3": "24p 50M", "4": "50p 50M", "5": "25p 50M",
            "16": "120p 50M", "17": "100p 50M", "24": "60p 25M", "25": "50p 25M", "26": "30p 16M", "27": "25p 16M",
            "28": "120p 100M", "29": "100p 100M", "30": "120p 60M", "31": "100p 60M",
            "32": "30p 100M", "33": "25p 100M", "34": "24p 100M", "35": "30p 60M", "36": "25p 60M", "37": "24p 60M",
        ]
        return known[value] ?? "Setting \(value)"
    }

    /// Megabits per second, for estimating how big a recording gets; nil when not known.
    static func megabits(_ value: String) -> Int? {
        let label = quality(value)
        guard label.hasSuffix("M"), let number = label.split(separator: " ").last?.dropLast() else { return nil }
        return Int(number)
    }
}

/// Reading the card over the camera's phone service: what is happening now.
struct CardActivity: Equatable {
    var title: String
    var done: Int64 = 0
    var total: Int64?
    var bytesPerSecond: Double?

    var detail: String? {
        guard done > 0 || total != nil else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        var text = f.string(fromByteCount: done)
        if let total { text += " of " + f.string(fromByteCount: total) }
        if let rate = bytesPerSecond, rate > 0 {
            text += String(format: " · %.1f MB/s", rate / 1_000_000)
            if let total, total > done {
                let left = Int(Double(total - done) / rate)
                text += left >= 90 ? " · about \((left + 30) / 60) min left" : " · about \(left) s left"
            }
        }
        return text
    }
}

// State that changes several times a second has its own small objects. A new value then redraws
// only the view that shows it. (Published on the store, every frame and every progress tick redrew
// the whole window; after two and a half hours of copying one redraw took longer than the pause
// between two ticks, and the window fell half an hour behind the copy. Measured 2026-11-18.)

/// The live picture and its frame rate.
@MainActor
final class PreviewFeed: ObservableObject {
    @Published var image: NSImage?
    @Published var fps: Double = 0
}

/// How far the file being copied has got.
@MainActor
final class CopyProgress: ObservableObject {
    @Published var done: Int64 = 0
    @Published var total: Int64?
    @Published var bytesPerSecond: Double?

    func reset(total: Int64? = nil) {
        done = 0
        self.total = total
        bytesPerSecond = nil
    }
}

/// The card's list as last read over the phone service, kept between runs of the app so that the
/// window can show it at once ("as read at …"). It is only ever something to look at: every copy
/// reads the card first and takes nothing from here on trust.
struct ClipListCache: Codable, Equatable {
    var readAt: Date
    var clips: [ClipFile]

    static var url: URL {
        BridgeSettings.url.deletingLastPathComponent().appendingPathComponent("clips.json")
    }

    static func load(from url: URL = ClipListCache.url) -> ClipListCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ClipListCache.self, from: data)
    }

    func save(to url: URL = ClipListCache.url) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Where the clip list comes from.
enum ClipSource: Equatable {
    case mtp            // camera on USB in MTP mode, read through libgphoto2
    case camera         // over the camera's phone service, on the link that also controls it
    case disk(URL)      // the card mounted as a disk (camera on USB in Mass Storage mode, or a card reader)
}

/// The camera's clock. The camera has one write-only setting for it (property 0xD223 "Date/Time
/// Setting"); Sony's own phone app sets the clock through it with the phone's local time and its
/// offset from UTC, summer time included, as one text: `20261121T141530.0+0400`.
enum CameraClock {
    static let setting = "d223"

    static func text(_ date: Date, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = zone.secondsFromGMT(for: date) / 60        // minutes; summer time is in it
        return String(format: "%04d%02d%02dT%02d%02d%02d.0%@%02d%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
                      offset < 0 ? "-" : "+", abs(offset) / 60, abs(offset) % 60)
    }
}

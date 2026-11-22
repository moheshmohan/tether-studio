import Foundation

/// Something that would spoil or cut short the next take, found from what the camera reports.
struct ReadyIssue: Equatable, Identifiable {
    enum Level: Int, Comparable {
        case note, warning, stop
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    let level: Level
    let text: String
    var id: String { text }
}

/// The check next to the Record button. It never keeps anyone from recording: it says what is
/// about to go wrong (card, battery, heat, mode, room on the Mac) while there is time to do
/// something about it.
enum ReadyCheck {
    static let cardWarningSeconds = 300, cardStopSeconds = 60
    static let batteryWarning = 30, batteryStop = 15
    static let photoWarning = 100
    /// Room wanted on the Mac while clips are copied by themselves: this much recording, on top of
    /// what the copy code always leaves free.
    static let macMinutes = 10

    static func issues(snapshot: CameraSnapshot, configs: [String: CameraConfig], preferredMovieMode: String,
                       autoCopy: Bool, macFree: Int64?) -> [ReadyIssue] {
        var found: [ReadyIssue] = []

        if snapshot.photoMode, let shots = snapshot.photosLeft {
            if shots <= 0 {
                found.append(ReadyIssue(level: .stop, text: "No room for photos on the card (full, or no card in the camera)"))
            } else if shots < photoWarning {
                found.append(ReadyIssue(level: .warning, text: "Room for only \(shots) photos on the card"))
            }
        } else if let left = snapshot.remainingSeconds {
            if left <= 0 {
                found.append(ReadyIssue(level: .stop, text: "No recording time left on the card (full, or no card in the camera)"))
            } else if left < cardStopSeconds {
                found.append(ReadyIssue(level: .stop, text: "Under a minute left on the card"))
            } else if left < cardWarningSeconds {
                found.append(ReadyIssue(level: .warning, text: "Only \(left / 60) min left on the card"))
            }
        }
        if let battery = snapshot.batteryPercent, battery <= batteryWarning {
            found.append(ReadyIssue(level: battery <= batteryStop ? .stop : .warning, text: "Camera battery at \(battery) %"))
        }
        if snapshot.overheating {
            found.append(ReadyIssue(level: .stop, text: "The camera is hot and may stop by itself"))
        }

        if let mode = configs["expprogram"]?.current, !mode.isEmpty {
            // Record itself leaves a photo mode and S&Q (slow and quick motion, no sound) for the
            // movie mode last used; saying so beforehand avoids a surprise.
            if mode.contains("S&Q") {
                found.append(ReadyIssue(level: .note, text: "S&Q mode: Record switches the camera to \(preferredMovieMode)"))
            } else if !mode.hasPrefix("Movie") {
                found.append(ReadyIssue(level: .note, text: "Photo mode (\(mode)): Record switches the camera to \(preferredMovieMode)"))
            }
        }
        if configs["focusmode"]?.current == "Manual" {
            found.append(ReadyIssue(level: .note, text: "Manual focus"))
        }

        if autoCopy, let free = macFree {
            let megabits = configs["d242"]?.current.flatMap(MovieSettings.megabits) ?? 100
            let perMinute = Int64(megabits) * 1_000_000 / 8 * 60
            let usable = free - CopyTarget.spare
            let size = ByteCountFormatter.string(fromByteCount: max(free, 0), countStyle: .file)
            if usable <= 0 {
                found.append(ReadyIssue(level: .warning, text: "No room on this Mac for copies (\(size) free): clips will stay on the card"))
            } else if usable < perMinute * Int64(macMinutes) {
                found.append(ReadyIssue(level: .warning,
                                        text: "\(size) free on this Mac: room for about \(usable / perMinute) min of clips at this quality"))
            }
        }
        return found.sorted { $0.level > $1.level }
    }

    /// What the camera is set to record, in one line, for when nothing is wrong.
    static func summary(snapshot: CameraSnapshot, configs: [String: CameraConfig]) -> String {
        var parts: [String] = []
        if let mode = configs["expprogram"]?.current, !mode.isEmpty { parts.append(SettingNames.label(leaf: "expprogram", value: mode)) }
        if let format = configs["d241"]?.current, let quality = configs["d242"]?.current, !format.isEmpty, !quality.isEmpty {
            parts.append((format == MovieSettings.format4K ? "4K " : "HD ") + MovieSettings.quality(quality))
        }
        if let left = snapshot.remainingLabel { parts.append(left.replacingOccurrences(of: " left", with: " on the card")) }
        if let battery = snapshot.batteryPercent { parts.append("battery \(battery) %") }
        return parts.joined(separator: " · ")
    }
}

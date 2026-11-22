import AppKit
import UserNotifications

/// A recording that ended, or may have ended, without Stop being pressed in this app; with the
/// likely cause, read from what the camera reported last.
struct StopAlert: Equatable, Identifiable {
    enum Kind: Equatable {
        /// The card ran out of room.
        case cardFull
        /// The camera stopped to cool down.
        case hot
        /// The camera reports that the recording failed (its state 2).
        case failed
        /// The battery was almost flat.
        case battery
        /// Stopped on the camera with nothing else to explain it: its movie button, most likely.
        case onCamera
        /// The connection went while recording; the camera may still be recording.
        case linkLost
        /// The connection came back and the camera had kept recording all along.
        case kept
        /// The connection came back and the recording had ended meanwhile.
        case endedWhileAway
    }

    let kind: Kind
    let at: Date
    /// How long it had been recording when this happened, where the app knows.
    let length: TimeInterval?
    /// The battery reading last seen, for the wording of a lost link.
    var lastBattery: Int? = nil

    var id: Date { at }

    /// Worth a loud alert: something went wrong, rather than a press of the camera's own button
    /// or a connection that came back with the camera still recording.
    var serious: Bool { kind != .onCamera && kind != .kept }

    /// Cards with less than this left count as full when the camera stops: it stops with a little room
    /// still reported (it keeps some for closing the file).
    static let fullCardSeconds = 30
    /// The camera stops recording itself on a battery this low.
    static let flatBattery = 5

    /// Why the camera stopped, from its state and the readings taken with it.
    static func cause(state: String?, snapshot: CameraSnapshot) -> Kind {
        if state == "2" { return .failed }
        if let left = snapshot.remainingSeconds, left < fullCardSeconds { return .cardFull }
        if snapshot.overheating { return .hot }
        if let battery = snapshot.batteryPercent, battery <= flatBattery { return .battery }
        return .onCamera
    }

    var title: String {
        switch kind {
        case .cardFull: return "Recording stopped: the card is full"
        case .hot: return "Recording stopped: the camera is too hot"
        case .failed: return "Recording failed on the camera"
        case .battery: return "Recording stopped: the camera's battery is flat"
        case .onCamera: return "Recording stopped on the camera"
        case .linkLost: return "Lost the camera while recording"
        case .kept: return "The camera kept recording"
        case .endedWhileAway: return "The recording ended while the camera was away"
        }
    }

    var detail: String {
        switch kind {
        case .cardFull:
            return "Free room on the card (copy the clips, then delete them on the camera) or put in another card."
        case .hot:
            return "Let the camera cool down; out of the sun, with the screen flipped out, it recovers faster."
        case .failed:
            return "The camera could not write the clip. Check the card in the camera."
        case .battery:
            return "Change or charge the battery before the next take."
        case .onCamera:
            return "Its movie button was pressed, or the camera reached one of its own limits."
        case .linkLost:
            if let battery = lastBattery, battery <= ReadyCheck.batteryStop {
                return "The battery was at \(battery) %: the camera has probably switched off. It may also still be recording. The app reconnects by itself."
            }
            return "The camera may still be recording. The app reconnects by itself and then says whether it is."
        case .kept:
            return "The connection dropped for a moment; the take went on and the timer shows its whole length."
        case .endedWhileAway:
            return "The clip is on the card up to the moment it stopped."
        }
    }

    /// "at 14:32:05, after 12 min 04 s"
    var when: String {
        var text = "at " + at.formatted(date: .omitted, time: .standard)
        if let length, length >= 1 { text += ", after " + Self.duration(length) }
        return text
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return String(format: "%d h %02d min", s / 3600, (s % 3600) / 60) }
        if s >= 60 { return String(format: "%d min %02d s", s / 60, s % 60) }
        return "\(s) s"
    }
}

/// Makes a stop alert heard and seen when the window is not being looked at: a sound, the Dock
/// icon, and a macOS notification.
@MainActor
final class StopAlerter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StopAlerter()

    /// Notifications need the app bundle; the bare binary (tests, command-line checks) has none.
    private var inBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    private var prepared = false
    private var soundTask: Task<Void, Never>?

    /// Asks macOS once for leave to post notifications. The first time, macOS shows its own
    /// "Allow" question; after that it answers from System Settings ▸ Notifications.
    func prepare(log: @escaping (String) -> Void) {
        guard inBundle, !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            log("notifications \(granted ? "allowed" : "not allowed")\(error.map { ": \($0.localizedDescription)" } ?? "")")
        }
    }

    func announce(_ alert: StopAlert, log: @escaping (String) -> Void) {
        play(serious: alert.serious)
        NSApp.requestUserAttention(alert.serious ? .criticalRequest : .informationalRequest)
        guard inBundle else { return }
        prepare(log: log)
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail + " (" + alert.when + ")"
        content.sound = nil         // the app plays its own, so it is heard once and as wanted
        let request = UNNotificationRequest(identifier: "stop-\(alert.at.timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log("notification not posted: \(error.localizedDescription)") }
        }
    }

    /// Something went wrong: three sharp sounds a second apart, to be heard across a room.
    /// Otherwise one soft one.
    private func play(serious: Bool) {
        soundTask?.cancel()
        let name = serious ? "Sosumi" : "Glass"
        let times = serious ? 3 : 1
        soundTask = Task { @MainActor in
            for n in 0..<times {
                if Task.isCancelled { return }
                NSSound(named: NSSound.Name(name))?.play()
                if n < times - 1 { try? await Task.sleep(nanoseconds: 1_100_000_000) }
            }
        }
    }

    /// Shown while the window is in front too: the banner in the window says it as well, but the
    /// window may be behind the camera's own screen on the desk.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

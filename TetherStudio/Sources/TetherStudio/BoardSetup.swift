import Foundation

/// The "Set Up ESP32-C3 Board" sheet: which board to write and how far it has got.
struct BoardSetup: Identifiable, Equatable {
    enum Phase: Equatable {
        case choose
        case working(String, Double?)
        case done(String)
        case failed(String)
    }

    let id = UUID()
    var ports: [EspFlasher.Port]
    var selected: String?
    var phase: Phase = .choose
    let imageVersion: Int?
    let imageProblem: String?

    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    static func text(for step: EspFlasher.Step) -> (String, Double?) {
        switch step {
        case .restarting: return ("Restarting the board into its bootloader…", nil)
        case .talking: return ("Talking to the bootloader…", nil)
        case .found(let mac): return ("ESP32-C3 \(mac) found. Erasing…", nil)
        case .erasing: return ("Erasing the board's flash…", nil)
        case .writing(let f): return ("Writing the bridge program…", f)
        case .verifying: return ("Checking what was written…", 1)
        case .starting: return ("Starting the bridge program…", 1)
        }
    }
}

import SwiftUI

/// Shown in the monitor area while no camera is connected: where the search
/// for the camera on Wi-Fi stands, and what to do on the camera (pairing).
struct WifiPanel: View {
    @EnvironmentObject var store: CameraStore
    @State private var address = ""
    @State private var network = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 38))
                .foregroundStyle(tint)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary)
                            Text(step).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: 460, alignment: .leading)
            }

            if showsSpinner { ProgressView().controlSize(.small).colorScheme(.dark) }

            if store.wifi == .blocked {
                Button("Open Local Network Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Divider().frame(maxWidth: 460).overlay(Color.white.opacity(0.2))

            HStack(spacing: 10) {
                Toggle("Wi-Fi", isOn: $store.wifiEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                TextField("Camera address (optional)", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .disabled(!store.wifiEnabled)
                    .onSubmit(useAddress)
                Button(address.isEmpty && !store.wifiManualHost.isEmpty ? "Auto" : "Connect", action: useAddress)
                    .disabled(!store.wifiEnabled || address == store.wifiManualHost)
            }
            .foregroundStyle(.white.opacity(0.85))

            bridgeRow

            Text("Or plug in the USB cable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .onAppear {
            address = store.wifiManualHost
            network = store.bridgeSettings.network
            password = store.bridgeSettings.password
        }
    }

    /// The camera's own network, reached through the ESP32 board on USB: the
    /// one connection that both controls the camera and hands over its clips.
    private var bridgeRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Toggle("ESP32 bridge", isOn: Binding(get: { store.bridgeSettings.enabled },
                                                     set: { store.bridgeSettings.enabled = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("An ESP32 board on this Mac's USB joins the camera's own Wi-Fi, so the Mac stays on the router. Camera: PC Remote Off, Ctrl w/ Smartphone On, Connection screen open.")
                TextField("Camera's network (DIRECT-…)", text: $network)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Button("Use", action: useBridge)
                    .disabled(network.trimmingCharacters(in: .whitespaces).isEmpty
                              || (network == store.bridgeSettings.network && password == store.bridgeSettings.password
                                  && store.bridgeSettings.enabled))
            }
            .onSubmit(useBridge)
            if needsBoardSetup {
                Button("Set Up ESP32-C3 Board…") { store.openBoardSetup() }
                    .controlSize(.small)
                    .help("Writes the bridge program to a Seeed XIAO ESP32-C3 on this Mac's USB")
            }
            if store.bridge != .off {
                Text(bridgeText)
                    .font(.caption)
                    .foregroundStyle(store.bridge.isJoined ? Color.green : Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private var needsBoardSetup: Bool {
        switch store.bridge {
        case .notAnswering, .noBoard: return true
        default: return false
        }
    }

    private func useBridge() {
        store.bridgeSettings = BridgeSettings(enabled: true, network: network.trimmingCharacters(in: .whitespaces),
                                              password: password)
    }

    private var bridgeText: String {
        switch store.bridge {
        case .off: return ""
        case .noBoard: return "ESP32 bridge: no board on USB. Plug in an ESP32-C3 board (Seeed XIAO ESP32-C3)."
        case .notAnswering(let port): return "ESP32 bridge: the board on \(port) does not run the bridge program yet. Set it up with the button above."
        case .unavailable(let why): return "ESP32 bridge: \(why)."
        case .joining(let name): return "ESP32 bridge: joining \(name)…"
        case .cannotJoin(let name, let why): return "ESP32 bridge: cannot join \(name): \(why)"
        case .joined(let name, let signal): return "ESP32 bridge: joined \(name) (signal \(signal) dBm)"
        }
    }

    private func useAddress() {
        store.wifiManualHost = address.trimmingCharacters(in: .whitespaces)
        store.retryWifi()
    }

    private var name: String { store.wifiClientName.isEmpty ? "this Mac" : "“\(store.wifiClientName)”" }

    private func label(_ camera: WifiCamera) -> String {
        "\(camera.model.isEmpty ? "Camera" : camera.model) at \(camera.host)"
    }

    private var icon: String {
        switch store.wifi {
        case .off: return "wifi.slash"
        case .blocked, .failed: return "exclamationmark.triangle"
        case .needsPairing, .confirmOnCamera: return "link.badge.plus"
        default: return "wifi"
        }
    }

    private var tint: Color {
        switch store.wifi {
        case .blocked, .failed: return .orange
        case .needsPairing, .confirmOnCamera: return .yellow
        default: return .secondary
        }
    }

    private var showsSpinner: Bool {
        switch store.wifi {
        case .searching, .connecting, .confirmOnCamera, .notFound, .needsPairing: return true
        default: return false
        }
    }

    private var title: String {
        switch store.wifi {
        case .idle, .searching: return "Looking for the camera on Wi-Fi…"
        case .off: return "Wi-Fi connection is off"
        case .notFound: return "No camera found on this network yet"
        case .blocked: return "macOS is not letting this app reach the local network"
        case .connecting(let c): return "\(label(c)): connecting…"
        case .needsPairing(let c): return "\(label(c)) needs to be paired with this Mac"
        case .confirmOnCamera(let c): return "Confirm on the camera (\(c.host))"
        case .failed(let message): return message
        case .connected(let host): return "Connected to \(host)"
        }
    }

    private var steps: [String] {
        switch store.wifi {
        case .notFound:
            return [
                "Camera on, USB cable unplugged (a data cable takes the camera off Wi-Fi).",
                "MENU → Network → Wi-Fi Settings: joined to the same router as this Mac.",
                "MENU → Network → PC Remote Function → PC Remote: On, PC Remote Cnct Method: Wi-Fi Access Point.",
                "The app keeps looking; it connects by itself when the camera appears.",
                "For clips over the same connection instead: PC Remote Off, Ctrl w/ Smartphone On, open its Connection screen, and switch on the ESP32 bridge below.",
            ]
        case .blocked:
            return [
                "System Settings → Privacy & Security → Local Network.",
                "Switch on Tether Studio. The app keeps trying and connects once it is allowed.",
            ]
        case .needsPairing:
            return [
                "On the camera: MENU → Network → PC Remote Function → Pairing.",
                "Leave that screen open. The camera will show \(name).",
                "Press OK on the camera. This is needed once; the camera remembers this Mac.",
            ]
        case .confirmOnCamera:
            return ["The camera is asking whether to pair with \(name). Press OK on the camera."]
        default:
            return []
        }
    }
}

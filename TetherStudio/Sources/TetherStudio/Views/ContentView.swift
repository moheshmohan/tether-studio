import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: CameraStore

    var body: some View {
        VStack(spacing: 0) {
            StatusBar()
            Divider()
            RecordBar()
            Divider()
            if let status = store.timelapse {
                TimelapseBanner(status: status)
                Divider()
            }
            if let alert = store.stopAlert {
                StopAlertBanner(alert: alert)
                Divider()
            }
            HStack(spacing: 0) {
                ControlPanel()
                    .frame(width: 340)
                Divider()
                VStack(spacing: 0) {
                    PreviewView()
                    Divider()
                    ClipsView()
                        .frame(height: 230)
                }
            }
        }
        .overlay(alignment: .bottom) { errorToast }
        .sheet(item: $store.wipePlan) { plan in WipeSheet(plan: plan).environmentObject(store) }
        .sheet(item: Binding(get: { store.boardSetup }, set: { if $0 == nil { store.closeBoardSetup() } })) { setup in
            BoardSetupSheet(setup: setup).environmentObject(store)
        }
        .alert("Erase card", isPresented: Binding(get: { store.wipeOutcome != nil }, set: { if !$0 { store.wipeOutcome = nil } })) {
            Button("OK") { store.wipeOutcome = nil }
        } message: {
            Text(store.wipeOutcome ?? "")
        }
    }

    @ViewBuilder
    private var errorToast: some View {
        if let err = store.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(err).lineLimit(2)
                Spacer()
                Button {
                    store.lastError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
            .padding(10)
            .background(.thinMaterial)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Under the record bar when a take ended without Stop being pressed here. Stays until closed or
/// the next take starts, so it is still there for whoever comes back to the Mac.
struct StopAlertBanner: View {
    @EnvironmentObject var store: CameraStore
    let alert: StopAlert

    private var tint: Color {
        alert.kind == .kept ? .green : alert.serious ? .red : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: alert.kind == .kept ? "checkmark.circle.fill"
                  : alert.kind == .linkLost ? "wifi.exclamationmark" : "stop.circle.fill")
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(alert.title).fontWeight(.semibold)
                    Text(alert.when).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(alert.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                store.stopAlert = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close the stop alert")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stop alert: \(alert.title)")
    }
}

struct StatusBar: View {
    @EnvironmentObject var store: CameraStore

    private var dotColor: Color {
        switch store.mode {
        case .pcRemote: return .green
        case .mtp: return .yellow
        case .disconnected: return .red
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
            Text(store.phoneControl && store.mode == .pcRemote ? "Ctrl w/ Smartphone · control and clips" : store.mode.title)
                .fontWeight(.medium)
            if let link = store.link {
                Label(linkLabel(link), systemImage: link.isWifi ? "wifi" : "cable.connector")
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 14)

            if store.mode != .disconnected {
                Text(store.snapshot.model)
                Text("fw \(store.snapshot.firmware)").foregroundStyle(.secondary)
                if let batt = store.snapshot.batteryPercent {
                    let low = batt <= 15
                    Image(systemName: batt > 87 ? "battery.100" : batt > 62 ? "battery.75" : batt > 37 ? "battery.50"
                          : batt > 12 ? "battery.25" : "battery.0")
                        .foregroundStyle(low ? Color.red : Color.primary)
                    Text("\(batt)%").foregroundStyle(low ? Color.red : Color.secondary)
                        .help(low ? "The camera's battery is low" : "The camera's battery")
                }
                if let left = store.snapshot.remainingLabel {
                    Image(systemName: "sdcard")
                    Text(left).foregroundStyle(.secondary)
                        .help("Recording time that still fits on the card at the current movie setting")
                }
                if store.snapshot.overheating {
                    Label("Camera is hot", systemImage: "thermometer.high")
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            modeHint
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func linkLabel(_ link: CameraLink) -> String {
        switch link {
        case .usb: return "USB"
        case .wifi(let host):
            if host == BridgeController.localHost { return "Camera's own Wi-Fi through the ESP32 board" }
            return store.phoneControl ? "Camera's own Wi-Fi \(host)" : "Wi-Fi \(host)"
        }
    }

    @ViewBuilder
    private var modeHint: some View {
        switch store.mode {
        case .pcRemote:
            Text(store.phoneControl ? "Clips come over this same connection, see below"
                 : store.link?.isWifi == true
                 ? "Clips: plug in the USB cable, the card then shows up below"
                 : "Clip sync: flip USB → MTP (app auto-detects)")
                .font(.caption).foregroundStyle(.secondary)
        case .mtp:
            Text("Control: flip USB → PC Remote (MENU → Setup → USB Connection)")
                .font(.caption).foregroundStyle(.secondary)
        case .disconnected:
            Text("Connect the camera over USB or Wi-Fi")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

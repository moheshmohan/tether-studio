import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: CameraStore

    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            ControlPanel()
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 440)
        } detail: {
            VStack(spacing: 0) {
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
                // The picture takes whatever room the window has; the clip list keeps a height the
                // user can change by dragging the divider.
                PreviewAndClips()
            }
            .overlay(alignment: .bottom) { errorToast }
            .navigationSplitViewColumnWidth(min: 460, ideal: 860)
        }
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolbarStatus()
            }
        }
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

    /// Under the window title: which camera, and over what.
    private var subtitle: String {
        guard store.mode != .disconnected else { return "No camera connected" }
        let camera = [store.snapshot.model, store.snapshot.firmware.isEmpty ? "" : "fw \(store.snapshot.firmware)"]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return [camera, ToolbarStatus.linkText(store)].filter { !$0.isEmpty }.joined(separator: " · ")
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

/// In the window's toolbar: connection, battery, card room and heat, each short; the long
/// explanations are in the tooltips.
struct ToolbarStatus: View {
    @EnvironmentObject var store: CameraStore

    static func linkText(_ store: CameraStore) -> String {
        guard let link = store.link else { return store.mode == .mtp ? "USB (MTP)" : "" }
        switch link {
        case .usb: return store.mode == .mtp ? "USB (MTP)" : "USB"
        case .wifi(let host):
            if host == BridgeController.localHost { return "Camera Wi-Fi via board" }
            return store.phoneControl ? "Camera Wi-Fi" : "Wi-Fi \(host)"
        }
    }

    private var dotColor: Color {
        switch store.mode {
        case .pcRemote: return .green
        case .mtp: return .yellow
        case .disconnected: return .red
        }
    }

    private var connectionHelp: String {
        switch store.mode {
        case .pcRemote:
            return store.phoneControl
                ? "Ctrl w/ Smartphone: control and clips over this one connection"
                : store.link?.isWifi == true
                    ? "PC Remote over Wi-Fi. Clips: plug in the USB cable; the card then shows up in the clip list"
                    : "PC Remote over USB. To copy clips, switch the camera's USB connection to Mass Storage"
        case .mtp:
            return "The camera is a USB drive (MTP). For control: MENU → Setup → USB Connection → PC Remote"
        case .disconnected:
            return "No camera. Connect it over USB, or open its Wi-Fi Connection screen with the ESP32 bridge on"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(store.mode == .disconnected ? "Not connected" : Self.linkText(store))
                    .lineLimit(1)
            }
            .help(connectionHelp)

            if store.mode != .disconnected {
                if let batt = store.snapshot.batteryPercent {
                    let low = batt <= 15
                    Label("\(batt)%", systemImage: batt > 87 ? "battery.100" : batt > 62 ? "battery.75"
                          : batt > 37 ? "battery.50" : batt > 12 ? "battery.25" : "battery.0")
                        .foregroundStyle(low ? Color.red : Color.primary)
                        .help(low ? "The camera's battery is low" : "The camera's battery")
                }
                if let left = store.snapshot.remainingLabel {
                    Label(left, systemImage: "sdcard")
                        .lineLimit(1)
                        .help("Room left on the camera's card at the current setting")
                }
                if store.snapshot.overheating {
                    Label("Hot", systemImage: "thermometer.high")
                        .foregroundStyle(.orange)
                        .help("The camera is hot and may stop recording")
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 8)
    }
}

/// The live picture above the clip list, with a divider to drag between them. The list keeps the
/// height it was given (remembered between launches); the picture takes the rest, so it is the one
/// that grows when the window is made larger, maximised or put in full screen. Both stay usable at
/// the window's smallest size.
struct PreviewAndClips: View {
    @AppStorage("clipListHeight") private var clipsHeight: Double = 250
    @State private var dragStart: Double?

    private let minPreview: Double = 200
    private let minClips: Double = 120

    var body: some View {
        GeometryReader { geo in
            let total = Double(geo.size.height)
            let clips = clamp(clipsHeight, total: total)
            VStack(spacing: 0) {
                PreviewView()
                    .frame(height: max(0, total - clips - 9))
                divider(total: total, current: clips)
                ClipsView()
                    .frame(height: clips)
            }
        }
    }

    private func clamp(_ height: Double, total: Double) -> Double {
        let most = max(minClips, total - minPreview - 9)
        return min(max(height, minClips), most)
    }

    private func divider(total: Double, current: Double) -> some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor)).frame(height: 9)
            Divider()
            Capsule().fill(.secondary.opacity(0.5)).frame(width: 36, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = dragStart ?? current
                    if dragStart == nil { dragStart = start }
                    clipsHeight = clamp(start - Double(value.translation.height), total: total)
                }
                .onEnded { _ in dragStart = nil }
        )
        .onTapGesture(count: 2) { clipsHeight = 250 }
        .help("Drag to change how much room the clip list has. Double-click for the usual size.")
        .accessibilityLabel("Divider between the live picture and the clip list")
    }
}

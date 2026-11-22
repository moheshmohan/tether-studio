import SwiftUI

struct ClipsView: View {
    @EnvironmentObject var store: CameraStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let activity = store.cardActivity {
                CardActivityRow(activity: activity, progress: store.copyProgress) { store.stopCardCopy() }
                Divider()
            }
            content
        }
    }

    /// The camera cannot hand over clips while it records or is already handing some over.
    private var busy: Bool { store.cardActivity != nil || store.isRecording }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Clips")
                .font(.headline)
            if store.clipSource != nil {
                Text("\(store.clips.count)")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            sourceLabel
                .lineLimit(1)
                .layoutPriority(-1)

            Spacer(minLength: 8)

            if store.clipSource == .camera && store.pendingTakes > 0 && store.cardActivity == nil {
                Button(store.pendingTakes == 1 ? "Copy waiting take" : "Copy \(store.pendingTakes) waiting takes") {
                    Task { await store.copyWaitingTakes() }
                }
                .disabled(store.isRecording)
                .help("Takes recorded over this connection that are not on this Mac yet")
            }

            if store.clipSource == .camera {
                Toggle(isOn: $store.autoCopy) {
                    ViewThatFits {
                        Text("Copy each clip when recording stops")
                        Text("Auto-copy")
                    }
                }
                .toggleStyle(.checkbox)
                .help("After every recording the camera hands the new clip over on this same connection. Live view and the controls pause while it copies.")
            }

            if listable {
                Button {
                    Task { await store.refreshClips() }
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Read the clip list again")
                .disabled(busy)

                Button("Download New") { store.downloadNew() }
                    .disabled(busy || store.clips.allSatisfy { store.isDownloaded($0) })
                    .help("Copies the clips that are not in the download folder yet (⌘D)")
            }

            Menu {
                if listable {
                    Button("Download All") { store.download(Array(store.clips)) }
                        .disabled(busy || store.clips.isEmpty)
                }
                if case .disk = store.clipSource {
                    Button("Eject Card") { store.ejectCard() }
                }
                if listable { Divider() }
                Button("Show Download Folder") { store.showDownloadFolder() }
                Button("Choose Download Folder…") { store.chooseDownloadFolder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More: download all, eject, download folder (\(store.downloadRoot.path))")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// Whether the list can be read and copied from right now.
    private var listable: Bool {
        store.clipSource != nil && (store.clipSource != .camera || store.cameraClipsLoaded)
    }

    @ViewBuilder
    private var sourceLabel: some View {
        if store.clipSource == .camera, store.cameraClipsLoaded, let at = store.cameraClipsReadAt {
            Text("as read at \(at.formatted(date: .omitted, time: .shortened))")
                .font(.caption).foregroundStyle(.tertiary)
                .help("The card's list as it was then. The refresh button reads it again; every copy checks the card first.")
        } else if case .disk(let root) = store.clipSource {
            Label(root.lastPathComponent, systemImage: "externaldrive")
                .font(.caption).foregroundStyle(.secondary)
                .help("Reading the card as a disk at \(root.path)")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let card = store.cardNeedsAccess {
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.questionmark").font(.title2).foregroundStyle(.secondary)
                Text("“\(card.lastPathComponent)” is mounted").font(.callout.weight(.medium))
                Text("macOS asks once per card before Tether Studio may list, copy or erase its files.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Allow Access to the Card…") { store.allowCardAccess() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.clipSource == .camera && !store.cameraClipsLoaded {
            cameraPrompt
        } else if store.clipSource != nil {
            clipList
        } else {
            switch store.mode {
            case .pcRemote:
                if store.phoneControl { cameraPrompt }
                else if store.link?.isWifi == true { wifiInstructions } else { mtpInstructions }
            case .mtp:
                clipList
            case .disconnected:
                VStack(spacing: 4) {
                    Text("No camera connected")
                        .foregroundStyle(.secondary)
                    Text("A card in a reader, or the camera on USB as a disk, is listed here too.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var cameraPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "sdcard").foregroundStyle(.secondary)
            Text("Clips come over this same connection")
                .font(.callout.weight(.medium))
            Text("While the camera hands over its card, live view and the controls pause; they come back by themselves.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show the clips on the card") {
                Task { await store.refreshClips() }
            }
            .disabled(store.cardActivity != nil || store.isRecording)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var mtpInstructions: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
            Text("Clip downloads happen over MTP")
                .font(.callout.weight(.medium))
            Text("On the camera: MENU → Setup → USB Connection → MTP\nThis window switches automatically when you flip it.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wifiInstructions: some View {
        VStack(spacing: 6) {
            Image(systemName: "wifi").foregroundStyle(.secondary)
            Text("The camera does not hand over clips on Wi-Fi")
                .font(.callout.weight(.medium))
            Text("To copy them: plug in the USB cable. The card appears as a disk and its clips are listed here.\nWhile the cable is in, the camera is off Wi-Fi; afterwards eject, unplug, and switch the camera off and on.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clipList: some View {
        List {
            ForEach(store.clips) { clip in
                ClipRow(clip: clip)
            }
        }
        .listStyle(.plain)
    }
}

/// What the camera is doing with its card right now, and a way to stop it.
/// A view of its own, so that a progress tick redraws this row and nothing else.
struct CardActivityRow: View {
    let activity: CardActivity
    @ObservedObject var progress: CopyProgress
    let stop: () -> Void

    private var shown: CardActivity {
        var now = activity
        now.done = progress.done
        now.total = progress.total ?? activity.total
        now.bytesPerSecond = progress.bytesPerSecond
        return now
    }

    var body: some View {
        let shown = self.shown
        HStack(spacing: 10) {
            if let total = shown.total, total > 0 {
                ProgressView(value: Double(min(shown.done, total)), total: Double(total))
                    .frame(minWidth: 80, idealWidth: 160, maxWidth: 160)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(shown.title).fontWeight(.medium).lineLimit(1)
            if let detail = shown.detail {
                Text(detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 8)
            ViewThatFits {
                Text("Live view and controls are paused")
                Text("Controls paused")
                EmptyView()
            }
            .font(.caption).foregroundStyle(.secondary)
            Button("Stop", action: stop)
                .help("Stops after the piece being copied; the part already here is kept and continued next time")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct ClipRow: View {
    @EnvironmentObject var store: CameraStore
    let clip: ClipFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: clip.isVideo ? "video.fill" : "photo")
                .foregroundStyle(clip.isVideo ? .blue : .purple)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(clip.dayFolder) · \(clip.sizeLabel)\(dimsLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            stateView

            Button {
                store.download([clip])
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .help("Download this file")
            .disabled(isRunning || store.cardActivity != nil || store.isRecording)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.open(clip) }
        .help(store.onMac[clip.id] != nil ? "Double-click to play the copy on this Mac" : "")
    }

    private var isRunning: Bool {
        if case .running = store.downloadStates[clip.id] { return true }
        return false
    }

    @ViewBuilder
    private var stateView: some View {
        switch store.downloadStates[clip.id] {
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading…").foregroundStyle(.secondary)
            }
        case .done(let url):
            Button {
                store.revealInFinder(url)
            } label: {
                Label("Saved", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder — \(url.path)")
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case nil:
            if let url = store.onMac[clip.id] {
                Button {
                    store.revealInFinder(url)
                } label: {
                    Label("On this Mac", systemImage: "checkmark")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Reveal in Finder — \(url.path)")
            } else {
                Text("").frame(width: 60)
            }
        }
    }

    private var dimsLabel: String {
        guard let w = clip.width, let h = clip.height else { return "" }
        return " · \(w)×\(h)"
    }
}

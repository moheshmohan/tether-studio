import SwiftUI

struct PreviewView: View {
    @EnvironmentObject var store: CameraStore

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LivePicture(feed: store.preview)

            if store.touchCancelAvailable {
                Button {
                    store.cancelTouchFocus()
                } label: {
                    Label(store.touchTracks ? "Stop tracking" : "Release focus", systemImage: "xmark.circle")
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if store.isRecording {
                recBadge
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 10) {
                if store.mode == .pcRemote, store.previewEnabled {
                    FrameRateLabel(feed: store.preview)
                }
                if store.configs["d26a"] != nil {
                    Picker("", selection: Binding(get: { store.liveViewSmooth }, set: { store.setLiveViewSmooth($0) })) {
                        Text("Sharp").tag(false)
                        Text("Smooth").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)
                    .help("Sharp: 1024×576 picture. Smooth: 640×360, more frames per second.")
                }
                Toggle("Live monitor", isOn: $store.previewEnabled)
                    .toggleStyle(.switch)
            }
            .controlSize(.mini)
            .fixedSize()
            .padding(8)
            .background(.thinMaterial)
            .cornerRadius(6)
            .padding(8)
            .disabled(store.mode != .pcRemote)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(store.isRecording ? Color.red.opacity(0.8) : .clear, lineWidth: 3)
        )
        .animation(.easeInOut(duration: 0.3), value: store.isRecording)
    }

    private var recBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let s = store.recordingStarted.map { Int(timeline.date.timeIntervalSince($0)) } ?? 0
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(String(format: "REC %02d:%02d", s / 60, s % 60))
                    .font(.callout.monospacedDigit().weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.55))
            .cornerRadius(6)
        }
    }
}

/// The frame rate of the live picture; redrawn alone when it changes.
private struct FrameRateLabel: View {
    @ObservedObject var feed: PreviewFeed

    var body: some View {
        if feed.fps > 0 {
            Text(String(format: "%.0f fps", feed.fps))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The live picture, or what is shown in its place. A view of its own: a new frame redraws this
/// and nothing else in the window.
private struct LivePicture: View {
    @EnvironmentObject var store: CameraStore
    @ObservedObject var feed: PreviewFeed

    var body: some View {
        if let img = feed.image {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay { touchLayer }
                .padding(10)
        } else if store.mode == .disconnected {
            // Centred when it fits, scrollable when the picture area is small.
            GeometryReader { geo in
                ScrollView {
                    WifiPanel()
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "video.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(previewPlaceholder)
                    .foregroundStyle(.secondary)
                if let err = store.lastPreviewError {
                    Text(err)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }
        }
    }

    /// Click on the picture = touch on the camera's screen: it focuses there,
    /// or starts following that subject, depending on the camera's touch setting.
    private var touchLayer: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard geo.size.width > 0, geo.size.height > 0 else { return }
                        store.touchFocus(at: CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height))
                    }
                if let marker = store.touchMarker {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.green, lineWidth: 2)
                        .frame(width: 46, height: 46)
                        .position(x: marker.x * geo.size.width, y: marker.y * geo.size.height)
                        .allowsHitTesting(false)
                }
            }
        }
        .allowsHitTesting(store.touchAvailable)
        .help(store.touchAvailable
              ? (store.touchTracks ? "Click a subject to have the camera follow it" : "Click where the camera should focus")
              : "")
    }

    private var previewPlaceholder: String {
        switch store.mode {
        case .pcRemote: return store.previewEnabled ? "Starting live monitor…" : "Live monitor off"
        case .mtp: return "Live monitor needs PC Remote mode"
        case .disconnected: return "No camera connected"
        }
    }
}

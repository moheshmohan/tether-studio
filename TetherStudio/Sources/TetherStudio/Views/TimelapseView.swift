import SwiftUI

/// The plan of a timelapse, opened from the Timelapse button.
struct TimelapseForm: View {
    @EnvironmentObject var store: CameraStore
    let close: () -> Void

    var body: some View {
        let plan = store.timelapsePlan
        VStack(alignment: .leading, spacing: 10) {
            Text("Timelapse").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("A photo every")
                    Picker("", selection: $store.timelapsePlan.interval) {
                        ForEach(TimelapsePlan.intervals, id: \.self) { Text(TimelapsePlan.seconds($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                GridRow {
                    Text("Photos")
                    Picker("", selection: $store.timelapsePlan.frames) {
                        ForEach(TimelapsePlan.frameChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                GridRow {
                    Text("Movie speed")
                    Picker("", selection: $store.timelapsePlan.fps) {
                        ForEach(TimelapsePlan.fpsChoices, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
                GridRow {
                    Text("Photo mode")
                    Picker("", selection: $store.preferredPhotoMode) {
                        ForEach(CameraService.photoModes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 110)
                }
            }
            Toggle("Focus on the first photo, then hold it", isOn: $store.timelapsePlan.lockFocus)
            Text(plan.summary)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("Photos come to this Mac in HD (1920 × 1080) as they are taken; the camera keeps full-size ones on its card. "
                 + "For an even picture, set the camera to M with fixed ISO and white balance; P follows the light (sunsets). "
                 + "No shutter sound: on the camera, Silent Shooting On and Audio signals Off.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: close)
                Button("Start") {
                    store.startTimelapse()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!store.photoAvailable)
            }
        }
        .padding(14)
    }
}

/// Under the record bar while a timelapse runs, and with its result afterwards.
struct TimelapseBanner: View {
    @EnvironmentObject var store: CameraStore
    let status: TimelapseStatus
    @State private var thumb: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            if let image = thumb {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 36).clipped().cornerRadius(3)
            } else {
                Image(systemName: "timelapse").font(.title2).foregroundStyle(.secondary).frame(width: 64)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            switch status.phase {
            case .shooting:
                ProgressView(value: Double(status.taken + status.missed), total: Double(status.plan.frames)).frame(width: 140)
                Button("Stop") { store.stopTimelapse() }
                    .help("Ends the shooting now; the movie is made from the photos taken so far")
            case .stopping:
                ProgressView().controlSize(.small)
            case .making(let part):
                ProgressView(value: part).frame(width: 140)
            case .finished(let movie):
                Button("Play") { NSWorkspace.shared.open(movie) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([movie]) }
                closeButton
            case .failed:
                Button("Show Photos") { NSWorkspace.shared.open(status.folder) }
                closeButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
        .task(id: status.lastFrame) {
            guard let url = status.lastFrame else { return }
            thumb = await Task.detached { Self.thumbnail(url) }.value
        }
    }

    /// A small picture of the latest photo, made once per photo (not on every redraw).
    nonisolated static func thumbnail(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private var closeButton: some View {
        Button { store.closeTimelapse() } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    private var title: String {
        switch status.phase {
        case .shooting: return "Timelapse: photo \(status.taken) of \(status.plan.frames)"
        case .stopping: return "Timelapse: finishing the photo in hand…"
        case .making(let part): return "Making the movie… \(Int(part * 100)) %"
        case .finished(let movie): return "Timelapse ready: \(movie.lastPathComponent)"
        case .failed(let why): return "Timelapse: \(why)"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if case .shooting = status.phase, let next = status.nextAt {
            let left = Int(next.timeIntervalSinceNow.rounded(.up))
            parts.append(left > 0 ? "next in \(left) s" : "taking it…")
            let remaining = Double(status.plan.frames - status.taken - status.missed) * status.plan.interval
            parts.append("about \(TimelapsePlan.clock(max(0, remaining))) to go")
        }
        if status.missed > 0 { parts.append("\(status.missed) missed") }
        parts.append(status.plan.summary)
        return parts.joined(separator: " · ")
    }
}

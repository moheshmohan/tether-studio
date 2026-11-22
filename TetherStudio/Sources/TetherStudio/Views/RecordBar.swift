import SwiftUI

struct RecordBar: View {
    @EnvironmentObject var store: CameraStore
    @State private var planning = false

    var body: some View {
        HStack(spacing: 16) {
            recordButton
            photoButton
            Button {
                planning = true
            } label: {
                ViewThatFits {
                    Label("Timelapse", systemImage: "timelapse")
                    Image(systemName: "timelapse")
                }
            }
            .controlSize(.large)
            .disabled(!store.photoAvailable)
            .help("Take a photo every few seconds and make a movie of them")
            .popover(isPresented: $planning, arrowEdge: .bottom) { TimelapseForm(close: { planning = false }) }

            VStack(alignment: .leading, spacing: 2) {
                if store.isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text("● REC  \(elapsedLabel)")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    if let issue = issues.first, issue.level >= .warning {
                        issueLabel(issue)
                    } else {
                        Text("Recording to the camera's card")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    let worst = issues.first?.level
                    Text(store.mode != .pcRemote ? "Recording needs PC Remote mode"
                         : store.timelapse?.running == true ? "Timelapse running"
                         : worst == .stop ? "Check before you record" : "Ready to record")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(worst == .stop ? Color.red : Color.primary)
                    if issues.isEmpty {
                        Text(readyLine)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .help(readyLine == subtitle ? subtitle : readyLine + "\n\n" + subtitle)
                    } else {
                        // As many warnings as the width allows, worst first; the rest in the tooltip.
                        ViewThatFits(in: .horizontal) {
                            issueRow(3)
                            issueRow(2)
                            issueRow(1)
                            Text(issues.count == 1 ? "1 thing to check" : "\(issues.count) things to check")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        .help(issues.map(\.text).joined(separator: "\n") + "\n\n" + subtitle)
                    }
                }
            }

            .frame(minWidth: 120, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 8)

            if store.isRecording {
                Button("Force Stop") { store.forceStopRecording() }
                    .controlSize(.large)
                    .help("Sends the stop signal again. If the camera keeps recording, press its movie button.")
            }

            if let busy = store.busyMessage {
                ProgressView()
                    .controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(busy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var issues: [ReadyIssue] { store.readyIssues }

    /// With nothing wrong: what the camera will record, where the old hint used to be (the hint is the tooltip now).
    private var readyLine: String {
        guard store.mode == .pcRemote, store.cardActivity == nil else { return subtitle }
        let summary = ReadyCheck.summary(snapshot: store.snapshot, configs: store.configs)
        return summary.isEmpty ? subtitle : summary
    }

    private func issueRow(_ count: Int) -> some View {
        HStack(spacing: 12) {
            ForEach(issues.prefix(count)) { issueLabel($0) }
            if issues.count > count { Text("+\(issues.count - count) more").font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize()
    }

    private func issueLabel(_ issue: ReadyIssue) -> some View {
        Label(issue.text, systemImage: issue.level == .note ? "info.circle" : "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(issue.level == .stop ? Color.red : issue.level == .warning ? Color.orange : Color.secondary)
            .lineLimit(1)
    }

    private var subtitle: String {
        switch store.mode {
        case .pcRemote:
            if store.cardActivity != nil {
                return "The camera is handing over clips. Press record to stop the copy and record; the copy continues afterwards"
            }
            return "Camera will auto-switch to \(store.preferredMovieMode) if needed"
                + (store.phoneControl && store.autoCopy ? "; the clip is copied when you stop" : "")
        case .mtp:
            return "MENU → Setup → USB Connection → PC Remote"
        case .disconnected:
            return "Plug in the ZV-E10 over USB, or put it on this Wi-Fi in PC Remote mode"
        }
    }

    private var elapsedLabel: String {
        guard let start = store.recordingStarted else { return "00:00" }
        let s = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var photoButton: some View {
        Button(action: { store.takePhoto() }) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder(.secondary, lineWidth: 1.5))
                Image(systemName: "camera.fill").font(.system(size: 14))
            }
        }
        .buttonStyle(.plain)
        .disabled(!store.photoAvailable)
        .help("Take a photo (⌘T). It goes to the camera's card, and in HD to this Mac's Photos folder for the day."
              + (store.lastPhoto.map { "\nLast: \($0.lastPathComponent)" } ?? ""))
        .accessibilityLabel("Take photo")
    }

    private var recordButton: some View {
        Button(action: { store.toggleRecording() }) {
            ZStack {
                Circle()
                    .fill(store.isRecording ? Color.red : Color(nsColor: .controlBackgroundColor))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(store.isRecording ? .red : .secondary, lineWidth: 2))
                if store.isRecording {
                    Rectangle().fill(.white).cornerRadius(3).frame(width: 14, height: 14)
                } else {
                    Circle().fill(.red).frame(width: 30, height: 30)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(store.mode != .pcRemote || store.busyMessage != nil || store.timelapse?.running == true)
        .help(store.isRecording ? "Stop recording (⌘R)"
              : store.cardActivity != nil ? "Stop the copy and start recording (⌘R)" : "Start recording (⌘R)")
    }
}

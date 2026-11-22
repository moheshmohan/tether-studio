import SwiftUI

/// Puts the bridge program on a Seeed XIAO ESP32-C3 (or any ESP32-C3 on its own USB port).
struct BoardSetupSheet: View {
    @EnvironmentObject var store: CameraStore
    let setup: BoardSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.system(size: 30))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up the ESP32-C3 Board").font(.title2).fontWeight(.semibold)
                    Text("The board joins the camera's own Wi-Fi so this Mac can stay on your router.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Plug a Seeed Studio XIAO ESP32-C3 (or another ESP32-C3 board with its own USB port) into this Mac. "
                 + "Tether Studio writes its bridge program to it, replacing whatever is on the board. It takes about 20 seconds "
                 + "and only has to be done once.")
                .fixedSize(horizontal: false, vertical: true)

            Label("Attach the flexible antenna from the board's box to its small round antenna connector first. "
                  + "The XIAO ESP32-C3 has no antenna of its own and barely reaches the camera without it.",
                  systemImage: "antenna.radiowaves.left.and.right")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = setup.imageProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if setup.ports.isEmpty {
                        Text("No Espressif board on USB. Plug it in with a data cable (a charge-only cable shows nothing), then Look Again.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(setup.ports) { port in
                            HStack {
                                Image(systemName: setup.selected == port.path ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(setup.selected == port.path ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading) {
                                    Text(port.serial.map { "Board \($0)" } ?? "Board").fontWeight(.medium)
                                    Text(port.path).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if !setup.isWorking { store.boardSetup?.selected = port.path } }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(setup.selected == port.path ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                HStack {
                    Text("Board")
                    Spacer()
                    Button("Look Again") { store.refreshBoardPorts() }
                        .controlSize(.small)
                        .disabled(setup.isWorking)
                }
            }

            Text("The chip is checked before anything is written: a board that is not an ESP32-C3, or not the one chosen, is left untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            phaseView

            HStack {
                if let v = setup.imageVersion {
                    Text("Bridge program version \(v)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(isDone ? "Done" : "Cancel") { store.closeBoardSetup() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(setup.isWorking)
                if !isDone {
                    Button(isFailed ? "Try Again" : "Install Bridge Program") { store.flashBoard() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(setup.selected == nil || setup.isWorking || setup.imageProblem != nil)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var isDone: Bool { if case .done = setup.phase { return true } else { return false } }
    private var isFailed: Bool { if case .failed = setup.phase { return true } else { return false } }

    @ViewBuilder
    private var phaseView: some View {
        switch setup.phase {
        case .choose:
            EmptyView()
        case .working(let text, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        case .done(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

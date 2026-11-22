import SwiftUI

/// The confirmation for erasing the card: says what goes, and what of it is only on the card, and
/// asks for the confirmation word to be typed.
struct WipeSheet: View {
    @EnvironmentObject var store: CameraStore
    let plan: CardWipe.Plan
    @State private var typed = ""

    private var ready: Bool { typed.trimmingCharacters(in: .whitespacesAndNewlines) == CardWipe.confirmWord && !store.wiping }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Erase the camera's card?", systemImage: "exclamationmark.triangle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.red)
            Text("This permanently deletes everything on the card: \(plan.summary). It cannot be undone, and nothing goes to the Trash.")
                .fixedSize(horizontal: false, vertical: true)
            if plan.notOnMac.isEmpty {
                Label("Every clip and photo on the card has a copy on this Mac.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(plan.notOnMac.count) of them are not on this Mac and will be lost:", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).fontWeight(.semibold)
                    Text(plan.notOnMac.prefix(12).joined(separator: ", ") + (plan.notOnMac.count > 12 ? " and \(plan.notOnMac.count - 12) more" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Type \(CardWipe.confirmWord) to confirm.").font(.callout)
            TextField(CardWipe.confirmWord, text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { if ready { store.confirmWipe(typed: typed) } }
            HStack {
                if store.wiping { ProgressView().controlSize(.small); Text("Erasing…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { store.cancelWipe() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.wiping)
                Button("Erase Card", role: .destructive) { store.confirmWipe(typed: typed) }
                    .disabled(!ready)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}

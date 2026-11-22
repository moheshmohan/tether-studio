import SwiftUI

/// The presets at the top of the control panel: one click sends a whole package of settings.
struct PresetsSection: View {
    @EnvironmentObject var store: CameraStore
    @State private var saving = false
    @State private var editing = false
    @State private var name = ""
    @State private var groups = Set(PresetGroup.allCases)
    @State private var deleting: Preset?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(store.allPresets) { preset in
                    chip(preset)
                }
            }

            HStack(spacing: 8) {
                Button {
                    name = ""
                    saving = true
                } label: {
                    Label("Save current…", systemImage: "plus")
                }
                .disabled(store.mode != .pcRemote)
                .help("Saves the camera's settings as they are now as a preset of your own")
                .popover(isPresented: $saving, arrowEdge: .trailing) { saveForm }

                if !store.presetLibrary.presets.isEmpty {
                    Toggle("Edit", isOn: $editing)
                        .toggleStyle(.button)
                        .help("Update or delete your own presets")
                }
                Spacer()
            }
            .controlSize(.small)

            if let startup = store.allPresets.first(where: { $0.id == store.startupPresetID }) {
                Label("On connect: \(startup.name)", systemImage: "power")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Applied by itself when the app first connects and when the camera comes back after a minute or more. Change it under Camera ▸ Preset on Connect.")
            }

            if let outcome = store.presetOutcome {
                Label(outcome.text, systemImage: outcome.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(outcome.ok ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if store.mode == .pcRemote && !store.presetsAvailable && store.applyingPreset == nil {
                Text(store.isRecording ? "Presets are back when the recording has stopped."
                     : store.cardActivity != nil ? "Presets are back when the clips have been handed over." : "")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: store.presetLibrary.presets.isEmpty) { empty in
            if empty { editing = false }
        }
        .alert("Delete the preset “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let preset = deleting { store.deletePreset(preset.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Only the saved preset goes; the camera's settings stay as they are.")
        }
    }

    @ViewBuilder
    private func chip(_ preset: Preset) -> some View {
        let active = store.applyingPreset == nil && preset.matches(store.configs)
        HStack(spacing: 4) {
            Button {
                store.applyPreset(preset)
            } label: {
                HStack(spacing: 5) {
                    if store.applyingPreset == preset.id {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: active ? "checkmark.circle.fill" : preset.symbol)
                            .foregroundStyle(active ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                    }
                    Text(preset.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if store.startupPresetID == preset.id {
                        Image(systemName: "power").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlColor)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(active ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.presetsAvailable)
            .opacity(store.presetsAvailable || store.applyingPreset == preset.id ? 1 : 0.5)
            .help(help(for: preset, active: active))
            .accessibilityLabel("Preset \(preset.name)")

            if editing && !preset.builtIn {
                Button {
                    store.savePreset(name: preset.name, groups: Set(preset.settings.compactMap { PresetCatalogue.field($0.leaf)?.group }))
                } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .help("Replace this preset's values with the camera's settings as they are now")
                    .accessibilityLabel("Update preset \(preset.name)")
                    .disabled(store.mode != .pcRemote)
                Button {
                    deleting = preset
                } label: { Image(systemName: "trash") }
                    .help("Delete this preset")
                    .accessibilityLabel("Delete preset \(preset.name)")
            }
        }
        .buttonStyle(.borderless)
        .contextMenu {
            Button("Apply") { store.applyPreset(preset) }.disabled(!store.presetsAvailable)
            Toggle("Apply Each Time the Camera Connects", isOn: Binding(
                get: { store.startupPresetID == preset.id },
                set: { store.startupPresetID = $0 ? preset.id : nil }))
            if !preset.builtIn {
                Button("Update with the Current Settings") {
                    store.savePreset(name: preset.name, groups: Set(preset.settings.compactMap { PresetCatalogue.field($0.leaf)?.group }))
                }
                .disabled(store.mode != .pcRemote)
                Button("Delete…") { deleting = preset }
            }
        }
    }

    private func help(for preset: Preset, active: Bool) -> String {
        var lines: [String] = []
        if !preset.note.isEmpty { lines.append(preset.note) }
        if active { lines.append("The camera is set like this now.") }
        if store.startupPresetID == preset.id { lines.append("Applied by itself each time the camera connects.") }
        lines.append(preset.summary)
        return lines.joined(separator: "\n")
    }

    private var saveForm: some View {
        let draft = Preset.capture(name: name, from: store.configs, groups: groups)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaces = store.presetLibrary.presets.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Save the camera's current settings").font(.headline)
            TextField("Name, for example “Desk interview”", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { save(draft) }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PresetGroup.allCases) { group in
                    Toggle(group.rawValue, isOn: Binding(
                        get: { groups.contains(group) },
                        set: { on in if on { groups.insert(group) } else { groups.remove(group) } }))
                }
            }
            Text(draft.settings.isEmpty
                 ? "Nothing to save: the camera lets none of these be set right now."
                 : "\(draft.settings.count) settings:\n" + draft.summary)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let replaces {
                Label("Replaces your preset “\(replaces.name)”.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { saving = false }
                Button("Save") { save(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || draft.settings.isEmpty)
            }
        }
        .padding(14)
    }

    private func save(_ draft: Preset) {
        guard !draft.settings.isEmpty, store.savePreset(name: name, groups: groups) else { return }
        saving = false
    }
}

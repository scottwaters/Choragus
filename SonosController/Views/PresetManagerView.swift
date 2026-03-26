/// PresetManagerView.swift — Sheet for creating and editing group presets.
import SwiftUI
import SonosKit

struct PresetManagerView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var presetManager: PresetManager
    @Environment(\.dismiss) private var dismiss

    @State private var newPresetName = ""
    @State private var editingPreset: GroupPreset?
    @State private var deleteConfirmPreset: GroupPreset?
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L10n.groupPresets)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(L10n.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Save from current group
            VStack(alignment: .leading, spacing: 8) {
                Text("Save current group and volumes as a preset:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    // Group picker showing all groups
                    Picker("Group", selection: $selectedSaveGroupID) {
                        ForEach(sonosManager.groups) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                    .frame(maxWidth: 200)

                    TextField("Preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)

                    Button("Save") {
                        saveCurrentAsPreset()
                    }
                    .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty || saveGroup == nil)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Preset list
            if presetManager.presets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.plus")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.noPresets)
                        .foregroundStyle(.secondary)
                    Text("Set up your speakers, adjust volumes, then save as a preset above.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(presetManager.presets) { preset in
                            PresetRow(
                                preset: preset,
                                onApply: { applyPreset(preset) },
                                onEdit: { editingPreset = preset },
                                onDelete: { deleteConfirmPreset = preset },
                                isApplying: presetManager.applyingPreset == preset.id,
                                sonosManager: sonosManager
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            // Status message
            if let msg = statusMessage {
                HStack {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .frame(width: 560, height: 480)
        .sheet(item: $editingPreset) { preset in
            PresetEditView(preset: preset)
                .environmentObject(sonosManager)
                .environmentObject(presetManager)
        }
        .alert("Delete Preset?", isPresented: Binding(
            get: { deleteConfirmPreset != nil },
            set: { if !$0 { deleteConfirmPreset = nil } }
        )) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let preset = deleteConfirmPreset {
                    presetManager.deletePreset(id: preset.id)
                    showStatus("Deleted \"\(preset.name)\"")
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(deleteConfirmPreset?.name ?? "")\"?")
        }
        .onAppear {
            if selectedSaveGroupID == nil {
                selectedSaveGroupID = UserDefaults.standard.string(forKey: "lastSelectedGroupID")
                    ?? sonosManager.groups.first?.id
            }
        }
    }

    // MARK: - State

    @State private var selectedSaveGroupID: String?

    private var saveGroup: SonosGroup? {
        guard let id = selectedSaveGroupID else { return nil }
        return sonosManager.groups.first { $0.id == id }
    }

    // MARK: - Actions

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let group = saveGroup else { return }
        presetManager.saveFromCurrent(name: name, group: group, deviceVolumes: sonosManager.deviceVolumes)
        newPresetName = ""
        showStatus("Saved \"\(name)\" (\(group.name))")
    }

    private func applyPreset(_ preset: GroupPreset) {
        Task {
            await presetManager.applyPreset(preset, using: sonosManager)
            showStatus("Applied \"\(preset.name)\"")
        }
    }

    private func showStatus(_ message: String) {
        statusMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if statusMessage == message { statusMessage = nil }
        }
    }
}

// MARK: - Preset Row

private struct PresetRow: View {
    let preset: GroupPreset
    let onApply: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let isApplying: Bool
    let sonosManager: SonosManager

    private var memberSummary: String {
        let coordName = sonosManager.devices[preset.coordinatorDeviceID]?.roomName ?? "?"
        let others = preset.members
            .filter { $0.deviceID != preset.coordinatorDeviceID }
            .compactMap { sonosManager.devices[$0.deviceID]?.roomName }
            .sorted()
        let names = [coordName] + others
        let volumes = preset.members.map { "\($0.volume)" }.joined(separator: "/")
        return "\(names.joined(separator: " + "))  ·  Vol: \(volumes)"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(memberSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isApplying {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Apply", action: onApply)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Preset Edit View

private struct PresetEditView: View {
    @State var preset: GroupPreset
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var presetManager: PresetManager
    @Environment(\.dismiss) private var dismiss

    private var visibleDevices: [SonosDevice] {
        var seen = Set<String>()
        var result: [SonosDevice] = []
        for group in sonosManager.groups {
            for member in group.members where !seen.contains(member.id) {
                seen.insert(member.id)
                result.append(member)
            }
        }
        return result.sorted { $0.roomName < $1.roomName }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Preset")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button(L10n.cancel) { dismiss() }
                Button("Save") {
                    presetManager.updatePreset(preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name
                    HStack {
                        Text("Name")
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)
                        TextField("Preset name", text: $preset.name)
                            .textFieldStyle(.roundedBorder)
                    }

                    Divider()

                    // Coordinator
                    HStack {
                        Text("Coordinator")
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)
                        Picker("", selection: $preset.coordinatorDeviceID) {
                            ForEach(preset.members, id: \.deviceID) { member in
                                Text(sonosManager.devices[member.deviceID]?.roomName ?? member.deviceID)
                                    .tag(member.deviceID)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider()

                    // Speakers
                    Text("Speakers")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    ForEach(visibleDevices) { device in
                        let isIncluded = preset.members.contains { $0.deviceID == device.id }
                        let memberIdx = preset.members.firstIndex { $0.deviceID == device.id }

                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { isIncluded },
                                set: { include in
                                    if include {
                                        preset.members.append(PresetMember(deviceID: device.id, volume: 30))
                                    } else {
                                        preset.members.removeAll { $0.deviceID == device.id }
                                        if preset.coordinatorDeviceID == device.id,
                                           let first = preset.members.first {
                                            preset.coordinatorDeviceID = first.deviceID
                                        }
                                    }
                                }
                            ))
                            .labelsHidden()

                            Text(device.roomName)
                                .frame(width: 120, alignment: .leading)

                            if let idx = memberIdx {
                                Slider(value: Binding(
                                    get: { Double(preset.members[idx].volume) },
                                    set: { preset.members[idx].volume = Int($0) }
                                ), in: 0...100)

                                Text("\(preset.members[safe: idx]?.volume ?? 0)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .frame(width: 28)
                            } else {
                                Spacer()
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 500, height: 450)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

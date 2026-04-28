/// PresetManagerView.swift — Pro-audio style preset manager with EQ support.
import SwiftUI
import SonosKit

struct PresetManagerView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var presetManager: PresetManager
    @Environment(\.dismiss) private var dismiss

    @State private var newPresetName = ""
    @State private var includeEQ = false
    @State private var isSaving = false
    @State private var editingPreset: GroupPreset?
    @State private var deleteConfirmPreset: GroupPreset?
    @State private var statusMessage: String?
    @State private var selectedSaveGroupID: String?

    private var saveGroup: SonosGroup? {
        guard let id = selectedSaveGroupID else { return nil }
        return sonosManager.groups.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            saveSection
            Divider()

            if presetManager.presets.isEmpty {
                emptyState
            } else {
                presetList
            }

            statusBar
        }
        .frame(width: 680, height: 580)
        .sheet(item: $editingPreset) { preset in
            PresetEditView(preset: preset)
                .environmentObject(sonosManager)
                .environmentObject(presetManager)
        }
        .alert("Delete Preset?", isPresented: Binding(
            get: { deleteConfirmPreset != nil },
            set: { if !$0 { deleteConfirmPreset = nil } }
        )) {
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.delete, role: .destructive) {
                if let preset = deleteConfirmPreset {
                    presetManager.deletePreset(id: preset.id)
                    showStatus("Deleted \"\(preset.name)\"")
                }
            }
        } message: {
            Text(L10n.confirmDeleteItem(deleteConfirmPreset?.name ?? ""))
        }
        .onAppear {
            if selectedSaveGroupID == nil {
                selectedSaveGroupID = UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
                    ?? sonosManager.groups.first?.id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3")
                .font(.title2)
                .foregroundStyle(.secondary)
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
    }

    // MARK: - Save Section

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.presetSaveHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Picker("", selection: $selectedSaveGroupID) {
                    ForEach(sonosManager.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                .frame(maxWidth: 180)

                TextField(L10n.presetName, text: $newPresetName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                Toggle(L10n.includeEQ, isOn: $includeEQ)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(L10n.save) { saveCurrentAsPreset() }
                        .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty || saveGroup == nil)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "slider.horizontal.below.square.and.square.filled")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(L10n.noPresets)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(L10n.presetSetupHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Preset List

    private var presetList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(presetManager.presets) { preset in
                    presetCard(preset)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func presetCard(_ preset: GroupPreset) -> some View {
        let isApplying = presetManager.applyingPreset == preset.id

        return HStack(spacing: 12) {
            // Icon
            Image(systemName: preset.homeTheaterEQ != nil ? "hifispeaker.and.homepodmini.fill" : "hifispeaker.2.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            // Info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(preset.name)
                        .font(.body)
                        .fontWeight(.semibold)

                    if preset.includesEQ {
                        Text("EQ")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.7), in: Capsule())
                    }
                    if preset.homeTheaterEQ != nil {
                        Text("5.1")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.7), in: Capsule())
                    }
                }

                // Members summary
                Text(memberSummary(preset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // EQ summary
                if preset.includesEQ, let eqSummary = eqSummaryText(preset) {
                    Text(eqSummary)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Actions
            if isApplying {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task {
                        await presetManager.applyPreset(preset, using: sonosManager)
                        showStatus("Applied \"\(preset.name)\"")
                    }
                } label: {
                    Text(L10n.apply)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button { editingPreset = preset } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button { deleteConfirmPreset = preset } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }

    // MARK: - Helpers

    private func memberSummary(_ preset: GroupPreset) -> String {
        let names = preset.members.compactMap { member in
            sonosManager.devices[member.deviceID]?.roomName ?? nil
        }.sorted()
        let volumes = preset.members.map { "\($0.volume)" }.joined(separator: "/")
        return "\(names.joined(separator: " + "))  ·  Vol: \(volumes)"
    }

    private func eqSummaryText(_ preset: GroupPreset) -> String? {
        let parts = preset.members.compactMap { member -> String? in
            guard let eq = member.eq else { return nil }
            let name = sonosManager.devices[member.deviceID]?.roomName ?? "?"
            return "\(name): B\(eq.bass > 0 ? "+" : "")\(eq.bass) T\(eq.treble > 0 ? "+" : "")\(eq.treble)"
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "  ·  ")
    }

    private var statusBar: some View {
        Group {
            if let msg = statusMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Actions

    private func saveCurrentAsPreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let group = saveGroup else { return }

        if includeEQ {
            isSaving = true
            Task {
                await presetManager.saveFromCurrent(
                    name: name, group: group,
                    deviceVolumes: sonosManager.deviceVolumes,
                    includeEQ: true, using: sonosManager
                )
                isSaving = false
                newPresetName = ""
                showStatus("Saved \"\(name)\" with EQ (\(group.name))")
            }
        } else {
            presetManager.saveFromCurrent(name: name, group: group, deviceVolumes: sonosManager.deviceVolumes)
            newPresetName = ""
            showStatus("Saved \"\(name)\" (\(group.name))")
        }
    }

    private func showStatus(_ message: String) {
        withAnimation { statusMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.statusMessageDismiss) {
            withAnimation {
                if statusMessage == message { statusMessage = nil }
            }
        }
    }
}

// MARK: - Preset Edit View

private struct PresetEditView: View {
    @State var preset: GroupPreset
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var presetManager: PresetManager
    @Environment(\.dismiss) private var dismiss
    @State private var isLoadingEQ = false
    @State private var selectedEQDevice: String?

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

    private var includedMembers: [(index: Int, member: PresetMember, name: String)] {
        preset.members.enumerated().compactMap { idx, member in
            let name = sonosManager.devices[member.deviceID]?.roomName ?? member.deviceID
            return (idx, member, name)
        }
    }

    private var isHTZone: Bool {
        sonosManager.homeTheaterZones.contains { $0.coordinatorID == preset.coordinatorDeviceID }
    }

    private var htZone: HomeTheaterZone? {
        sonosManager.homeTheaterZones.first { $0.coordinatorID == preset.coordinatorDeviceID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L10n.editPreset)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button(L10n.cancel) { dismiss() }
                Button(L10n.save) {
                    presetManager.updatePreset(preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Section 1: Name & Coordinator
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(L10n.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            TextField(L10n.presetName, text: $preset.name)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack {
                            Text(L10n.coordinatorLabel)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            Picker("", selection: $preset.coordinatorDeviceID) {
                                ForEach(preset.members, id: \.deviceID) { member in
                                    Text(sonosManager.devices[member.deviceID]?.roomName ?? member.deviceID)
                                        .tag(member.deviceID)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    Divider()

                    // Section 2: Speakers & Volumes
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.speakersAndVolumes)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ForEach(visibleDevices) { device in
                            speakerVolumeRow(device)
                        }
                    }

                    // Section 3: EQ (separate section)
                    if preset.includesEQ {
                        Divider()
                        eqSection
                    }

                    // Section 4: Home Theater. Driven by the preset's
                    // own `homeTheaterEQ` value rather than the live
                    // `isHTZone` lookup — `sonosManager.homeTheaterZones`
                    // is computed off `@Published` topology and
                    // briefly returns nil mid-edit on every topology
                    // event, which used to make the whole section
                    // disappear and reappear. The data is in
                    // `preset.homeTheaterEQ` regardless.
                    if preset.includesEQ && preset.homeTheaterEQ != nil {
                        Divider()
                        homeTheaterSection
                    }
                }
                .padding(24)
            }

            // Footer with EQ toggle
            Divider()
            HStack {
                Toggle(L10n.includeEQSettings, isOn: $preset.includesEQ)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
                    .onChange(of: preset.includesEQ) {
                        if preset.includesEQ {
                            for i in preset.members.indices where preset.members[i].eq == nil {
                                preset.members[i].eq = SpeakerEQ()
                            }
                            if isHTZone && preset.homeTheaterEQ == nil {
                                preset.homeTheaterEQ = HomeTheaterEQ()
                            }
                            if selectedEQDevice == nil {
                                selectedEQDevice = preset.members.first?.deviceID
                            }
                        }
                    }

                Spacer()

                if preset.includesEQ {
                    Button {
                        Task { await loadCurrentEQ() }
                    } label: {
                        HStack(spacing: 4) {
                            if isLoadingEQ {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.caption)
                            }
                            Text(L10n.loadCurrentEQ)
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isLoadingEQ)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .frame(width: 520, height: 600)
        .onAppear { ensureHomeTheaterEQInitialised() }
        // Coordinator can be re-picked mid-edit — when switching from
        // a stereo pair to an HT zone, the HT section's `homeTheaterEQ`
        // is still nil from the previous coordinator and renders empty
        // until the user toggles. Re-run the same lazy init.
        .onChange(of: preset.coordinatorDeviceID) {
            ensureHomeTheaterEQInitialised()
        }
        // `isHTZone` walks `sonosManager.homeTheaterZones`, which is
        // populated asynchronously after launch. If the sheet opens
        // before the channel-map info has come back, `isHTZone` is
        // false at first and `ensureHomeTheaterEQInitialised()`
        // skips the init. Re-fire the check the moment the data
        // populates.
        .onChange(of: isHTZone) {
            ensureHomeTheaterEQInitialised()
        }
    }

    /// If the current state needs a `HomeTheaterEQ` but doesn't have
    /// one, allocate it. Idempotent.
    private func ensureHomeTheaterEQInitialised() {
        if preset.includesEQ && isHTZone && preset.homeTheaterEQ == nil {
            preset.homeTheaterEQ = HomeTheaterEQ()
        }
    }

    // MARK: - Speaker Volume Row

    private func speakerVolumeRow(_ device: SonosDevice) -> some View {
        let isIncluded = preset.members.contains { $0.deviceID == device.id }
        let memberIdx = preset.members.firstIndex { $0.deviceID == device.id }

        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isIncluded },
                set: { include in
                    if include {
                        preset.members.append(PresetMember(deviceID: device.id, volume: 30, eq: preset.includesEQ ? SpeakerEQ() : nil))
                    } else {
                        preset.members.removeAll { $0.deviceID == device.id }
                        if preset.coordinatorDeviceID == device.id, let first = preset.members.first {
                            preset.coordinatorDeviceID = first.deviceID
                        }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            HStack(spacing: 4) {
                Text(device.roomName)
                    .font(.system(size: 13))
                if device.id == preset.coordinatorDeviceID {
                    Text(L10n.lead)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.7), in: Capsule())
                }
            }
            .frame(width: 140, alignment: .leading)

            if let idx = memberIdx {
                Slider(value: Binding(
                    get: { Double(preset.members[idx].volume) },
                    set: { preset.members[idx].volume = Int($0) }
                ), in: 0...100)

                Text("\(preset.members[safe: idx]?.volume ?? 0)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            } else {
                Spacer()
            }
        }
        .opacity(isIncluded ? 1 : 0.35)
    }

    // MARK: - EQ Section (speaker picker + sliders)

    private var eqSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.speakerEQ)
                .font(.subheadline)
                .fontWeight(.medium)

            // Speaker picker tabs
            HStack(spacing: 6) {
                ForEach(includedMembers, id: \.member.deviceID) { item in
                    Button {
                        selectedEQDevice = item.member.deviceID
                    } label: {
                        Text(item.name)
                            .font(.system(size: 11, weight: selectedEQDevice == item.member.deviceID ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selectedEQDevice == item.member.deviceID
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.gray.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            // EQ controls for selected speaker
            if let deviceID = selectedEQDevice,
               let idx = preset.members.firstIndex(where: { $0.deviceID == deviceID }),
               preset.members[safe: idx]?.eq != nil {

                VStack(alignment: .leading, spacing: 12) {
                    eqSlider("Bass", value: Binding(
                        get: { Double(preset.members[idx].eq?.bass ?? 0) },
                        set: { preset.members[idx].eq?.bass = Int(round($0)) }
                    ), range: -10...10)

                    eqSlider("Treble", value: Binding(
                        get: { Double(preset.members[idx].eq?.treble ?? 0) },
                        set: { preset.members[idx].eq?.treble = Int(round($0)) }
                    ), range: -10...10)

                    Toggle(L10n.loudness, isOn: Binding(
                        get: { preset.members[safe: idx]?.eq?.loudness ?? true },
                        set: { preset.members[idx].eq?.loudness = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                }
                .padding(16)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear {
            if selectedEQDevice == nil {
                selectedEQDevice = preset.members.first?.deviceID
            }
        }
    }

    private func eqSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .frame(width: 50, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: - Home Theater Section

    private var homeTheaterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.homeTheaterEQSection)
                .font(.subheadline)
                .fontWeight(.medium)

            if preset.homeTheaterEQ != nil {
                VStack(alignment: .leading, spacing: 12) {
                    // Toggles row
                    HStack(spacing: 24) {
                        Toggle(L10n.nightMode, isOn: binding(for: \.nightMode))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 13))
                        Toggle(L10n.dialogEnhancement, isOn: binding(for: \.dialogLevel))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 13))
                    }

                    // Sub + Surround controls always render in the
                    // preset editor — the live device's `hasSub` /
                    // `hasSurrounds` capability isn't a reliable
                    // gate when editing a preset that may be applied
                    // to a different bonded setup later. The data
                    // we're editing lives in `preset.homeTheaterEQ`;
                    // showing the full set of controls is what the
                    // user expects.
                    Divider()
                    Toggle(L10n.subTab, isOn: binding(for: \.subEnabled))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))

                    eqSlider("Sub Level", value: Binding(
                        get: { Double(preset.homeTheaterEQ?.subGain ?? 0) },
                        set: { preset.homeTheaterEQ?.subGain = Int(round($0)) }
                    ), range: -15...15)
                    .disabled(!(preset.homeTheaterEQ?.subEnabled ?? true))

                    Divider()
                    Toggle(L10n.surroundsTab, isOn: binding(for: \.surroundEnabled))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 13))

                    let surroundsOn = preset.homeTheaterEQ?.surroundEnabled ?? true

                    eqSlider("TV Level", value: Binding(
                        get: { Double(preset.homeTheaterEQ?.surroundLevel ?? 0) },
                        set: { preset.homeTheaterEQ?.surroundLevel = Int(round($0)) }
                    ), range: -15...15)
                    .disabled(!surroundsOn)

                    eqSlider("Music", value: Binding(
                        get: { Double(preset.homeTheaterEQ?.musicSurroundLevel ?? 0) },
                        set: { preset.homeTheaterEQ?.musicSurroundLevel = Int(round($0)) }
                    ), range: -15...15)
                    .disabled(!surroundsOn)

                    HStack(spacing: 10) {
                        Text(L10n.playbackLabel)
                            .font(.system(size: 13))
                            .frame(width: 70, alignment: .leading)
                        Picker("", selection: binding(for: \.surroundMode)) {
                            Text(L10n.surroundModeFull).tag(1)
                            Text(L10n.surroundModeAmbient).tag(0)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 180)
                    }
                    .disabled(!surroundsOn)
                }
                .padding(16)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Bindings

    private func binding(for keyPath: WritableKeyPath<HomeTheaterEQ, Bool>) -> Binding<Bool> {
        Binding(
            get: { preset.homeTheaterEQ?[keyPath: keyPath] ?? false },
            set: { preset.homeTheaterEQ?[keyPath: keyPath] = $0 }
        )
    }

    private func binding(for keyPath: WritableKeyPath<HomeTheaterEQ, Int>) -> Binding<Int> {
        Binding(
            get: { preset.homeTheaterEQ?[keyPath: keyPath] ?? 0 },
            set: { preset.homeTheaterEQ?[keyPath: keyPath] = $0 }
        )
    }

    // MARK: - Load Current EQ

    private func loadCurrentEQ() async {
        isLoadingEQ = true
        defer { isLoadingEQ = false }

        for i in preset.members.indices {
            guard let device = sonosManager.devices[preset.members[i].deviceID] else { continue }
            do {
                let bass = try await sonosManager.getBass(device: device)
                let treble = try await sonosManager.getTreble(device: device)
                let loudness = try await sonosManager.getLoudness(device: device)
                preset.members[i].eq = SpeakerEQ(bass: bass, treble: treble, loudness: loudness)
            } catch {
                sonosDebugLog("[PRESET] Failed to read EQ for \(device.roomName): \(error)")
            }
        }

        if isHTZone, let device = sonosManager.devices[preset.coordinatorDeviceID] {
            let nightMode = (try? await sonosManager.getEQ(device: device, eqType: "NightMode")) == 1
            let dialogLevel = (try? await sonosManager.getEQ(device: device, eqType: "DialogLevel")) == 1
            let subEnabled = (try? await sonosManager.getEQ(device: device, eqType: "SubEnable")) != 0
            let subGain = (try? await sonosManager.getEQ(device: device, eqType: "SubGain")) ?? 0
            let subPolarity = (try? await sonosManager.getEQ(device: device, eqType: "SubPolarity")) == 1
            let surroundEnabled = (try? await sonosManager.getEQ(device: device, eqType: "SurroundEnable")) != 0
            let surroundLevel = (try? await sonosManager.getEQ(device: device, eqType: "SurroundLevel")) ?? 0
            let musicSurroundLevel = (try? await sonosManager.getEQ(device: device, eqType: "MusicSurroundLevel")) ?? 0
            let surroundMode = (try? await sonosManager.getEQ(device: device, eqType: "SurroundMode")) ?? 1

            preset.homeTheaterEQ = HomeTheaterEQ(
                nightMode: nightMode, dialogLevel: dialogLevel,
                subEnabled: subEnabled, subGain: subGain, subPolarity: subPolarity,
                surroundEnabled: surroundEnabled, surroundLevel: surroundLevel,
                musicSurroundLevel: musicSurroundLevel, surroundMode: surroundMode
            )
        }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

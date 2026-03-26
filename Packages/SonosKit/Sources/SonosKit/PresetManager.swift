/// PresetManager.swift — Manages group presets with JSON persistence.
import Foundation

@MainActor
public final class PresetManager: ObservableObject {
    @Published public var presets: [GroupPreset] = []
    @Published public var applyingPreset: UUID?

    private let fileURL: URL

    public init() {
        self.fileURL = AppPaths.appSupportDirectory.appendingPathComponent("group_presets.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        presets = (try? JSONDecoder().decode([GroupPreset].self, from: data)) ?? []
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(presets)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            sonosDebugLog("[PRESET] Save failed: \(error)")
        }
    }

    public func addPreset(_ preset: GroupPreset) {
        presets.append(preset)
        save()
    }

    public func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    public func updatePreset(_ preset: GroupPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            save()
        }
    }

    /// Captures the current group topology and volumes as a new preset (no EQ)
    public func saveFromCurrent(name: String, group: SonosGroup, deviceVolumes: [String: Int]) {
        let members = group.members.map { device in
            PresetMember(deviceID: device.id, volume: deviceVolumes[device.id] ?? 30)
        }
        let preset = GroupPreset(
            name: name,
            coordinatorDeviceID: group.coordinatorID,
            members: members
        )
        addPreset(preset)
    }

    /// Captures the current group topology, volumes, and EQ as a new preset
    public func saveFromCurrent(name: String, group: SonosGroup, deviceVolumes: [String: Int],
                                includeEQ: Bool, using manager: SonosManager) async {
        var members: [PresetMember] = []

        for device in group.members {
            var eq: SpeakerEQ?
            if includeEQ {
                eq = await readSpeakerEQ(device: device, using: manager)
            }
            members.append(PresetMember(
                deviceID: device.id,
                volume: deviceVolumes[device.id] ?? 30,
                eq: eq
            ))
        }

        var htEQ: HomeTheaterEQ?
        if includeEQ {
            htEQ = await readHomeTheaterEQ(coordinatorID: group.coordinatorID, using: manager)
        }

        let preset = GroupPreset(
            name: name,
            coordinatorDeviceID: group.coordinatorID,
            members: members,
            includesEQ: includeEQ,
            homeTheaterEQ: htEQ
        )
        addPreset(preset)
    }

    /// Reads standard EQ from a speaker
    private func readSpeakerEQ(device: SonosDevice, using manager: SonosManager) async -> SpeakerEQ? {
        do {
            let bass = try await manager.getBass(device: device)
            let treble = try await manager.getTreble(device: device)
            let loudness = try await manager.getLoudness(device: device)
            return SpeakerEQ(bass: bass, treble: treble, loudness: loudness)
        } catch {
            sonosDebugLog("[PRESET] Failed to read EQ for \(device.roomName): \(error)")
            return nil
        }
    }

    /// Reads home theater EQ from coordinator if it's an HT zone
    private func readHomeTheaterEQ(coordinatorID: String, using manager: SonosManager) async -> HomeTheaterEQ? {
        let isHTZone = manager.homeTheaterZones.contains { $0.coordinatorID == coordinatorID }
        guard isHTZone, let device = manager.devices[coordinatorID] else { return nil }

        let nightMode = (try? await manager.getEQ(device: device, eqType: "NightMode")) == 1
        let dialogLevel = (try? await manager.getEQ(device: device, eqType: "DialogLevel")) == 1
        let subEnabled = (try? await manager.getEQ(device: device, eqType: "SubEnable")) != 0
        let subGain = (try? await manager.getEQ(device: device, eqType: "SubGain")) ?? 0
        let subPolarity = (try? await manager.getEQ(device: device, eqType: "SubPolarity")) == 1
        let surroundEnabled = (try? await manager.getEQ(device: device, eqType: "SurroundEnable")) != 0
        let surroundLevel = (try? await manager.getEQ(device: device, eqType: "SurroundLevel")) ?? 0
        let musicSurroundLevel = (try? await manager.getEQ(device: device, eqType: "MusicSurroundLevel")) ?? 0
        let surroundMode = (try? await manager.getEQ(device: device, eqType: "SurroundMode")) ?? 1

        return HomeTheaterEQ(
            nightMode: nightMode, dialogLevel: dialogLevel,
            subEnabled: subEnabled, subGain: subGain, subPolarity: subPolarity,
            surroundEnabled: surroundEnabled, surroundLevel: surroundLevel,
            musicSurroundLevel: musicSurroundLevel, surroundMode: surroundMode
        )
    }

    /// Applies a preset: groups speakers, sets volumes, and optionally applies EQ
    public func applyPreset(_ preset: GroupPreset, using manager: SonosManager) async {
        applyingPreset = preset.id
        defer { applyingPreset = nil }

        let presetDeviceIDs = Set(preset.members.map(\.deviceID))
        guard let coordinator = manager.devices[preset.coordinatorDeviceID] else { return }

        // Find which group the coordinator is currently in
        let coordinatorGroup = manager.groups.first { group in
            group.members.contains { $0.id == coordinator.id }
        }
        let currentMemberIDs = Set(coordinatorGroup?.members.map(\.id) ?? [coordinator.id])

        var topologyChanged = false

        // Remove speakers not in preset
        let toRemove = currentMemberIDs.subtracting(presetDeviceIDs).subtracting([coordinator.id])
        for deviceID in toRemove {
            if let device = manager.devices[deviceID] {
                try? await manager.ungroupDevice(device)
                topologyChanged = true
            }
        }

        // Add speakers to coordinator's group
        let toAdd = presetDeviceIDs.subtracting(currentMemberIDs).subtracting([coordinator.id])
        for deviceID in toAdd {
            guard let device = manager.devices[deviceID] else { continue }
            let inOtherGroup = manager.groups.contains { group in
                group.coordinatorID != coordinator.id &&
                group.members.contains { $0.id == deviceID } &&
                group.members.count > 1
            }
            if inOtherGroup {
                try? await manager.ungroupDevice(device)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            try? await manager.joinGroup(device: device, toCoordinator: coordinator)
            topologyChanged = true
        }

        if topologyChanged {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await manager.refreshTopology(from: coordinator)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Set volumes
        for member in preset.members {
            guard let device = manager.devices[member.deviceID] else { continue }
            manager.setVolumeGrace(deviceID: device.id, duration: 5)
            manager.deviceVolumes[device.id] = member.volume
            try? await manager.setVolume(device: device, volume: member.volume)
        }

        // Apply EQ if preset includes it
        if preset.includesEQ {
            for member in preset.members {
                guard let eq = member.eq, let device = manager.devices[member.deviceID] else { continue }
                try? await manager.setBass(device: device, bass: eq.bass)
                try? await manager.setTreble(device: device, treble: eq.treble)
                try? await manager.setLoudness(device: device, enabled: eq.loudness)
            }

            if let htEQ = preset.homeTheaterEQ, let device = manager.devices[preset.coordinatorDeviceID] {
                try? await manager.setEQ(device: device, eqType: "NightMode", value: htEQ.nightMode ? 1 : 0)
                try? await manager.setEQ(device: device, eqType: "DialogLevel", value: htEQ.dialogLevel ? 1 : 0)
                try? await manager.setEQ(device: device, eqType: "SubEnable", value: htEQ.subEnabled ? 1 : 0)
                try? await manager.setEQ(device: device, eqType: "SubGain", value: htEQ.subGain)
                try? await manager.setEQ(device: device, eqType: "SubPolarity", value: htEQ.subPolarity ? 1 : 0)
                try? await manager.setEQ(device: device, eqType: "SurroundEnable", value: htEQ.surroundEnabled ? 1 : 0)
                try? await manager.setEQ(device: device, eqType: "SurroundLevel", value: htEQ.surroundLevel)
                try? await manager.setEQ(device: device, eqType: "MusicSurroundLevel", value: htEQ.musicSurroundLevel)
                try? await manager.setEQ(device: device, eqType: "SurroundMode", value: htEQ.surroundMode)
            }
        }
    }
}

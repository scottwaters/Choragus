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
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: fileURL, options: .atomic)
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

    /// Captures the current group topology and volumes as a new preset
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

    /// Applies a preset: groups speakers and sets volumes, only changing what's needed
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

        // Remove speakers from coordinator's group that aren't in the preset
        let toRemove = currentMemberIDs.subtracting(presetDeviceIDs).subtracting([coordinator.id])
        for deviceID in toRemove {
            if let device = manager.devices[deviceID] {
                try? await manager.ungroupDevice(device)
                topologyChanged = true
            }
        }

        // Add speakers to coordinator's group that aren't already in it
        let toAdd = presetDeviceIDs.subtracting(currentMemberIDs).subtracting([coordinator.id])
        for deviceID in toAdd {
            guard let device = manager.devices[deviceID] else { continue }
            // If this speaker is in a different group, ungroup it first
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
        }

        // Refresh topology first if grouping changed, so the view settles
        if topologyChanged {
            await manager.refreshTopology(from: coordinator)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Set volumes for all preset members with grace period to prevent
        // fetchCurrentState from overwriting with stale speaker values
        for member in preset.members {
            guard let device = manager.devices[member.deviceID] else { continue }
            manager.setVolumeGrace(deviceID: device.id, duration: 5)
            manager.deviceVolumes[device.id] = member.volume
            try? await manager.setVolume(device: device, volume: member.volume)
        }
    }
}

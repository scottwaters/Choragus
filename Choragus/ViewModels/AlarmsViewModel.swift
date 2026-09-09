/// AlarmsViewModel.swift — State behind the Alarms window: the alarm
/// list from the speaker that owns it, the alarm being edited, the
/// Sonos favorites a program can be picked from, and the last error.
/// ObservableObject rather than @Observable so the AppKit-hosted window
/// re-renders reliably.
import Foundation
import SonosKit

@MainActor
final class AlarmsViewModel: ObservableObject {
    @Published private(set) var alarms: [SonosAlarm] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?
    @Published var editing: SonosAlarm?
    @Published private(set) var isNew = false
    @Published private(set) var favorites: [BrowseItem] = []
    @Published private(set) var favoritesLoaded = false

    private var manager: SonosManager?

    /// Alarms come from the speaker with each change; the model keeps no
    /// local edits that could drift from it.
    func attach(_ manager: SonosManager) {
        guard self.manager == nil else { return }
        self.manager = manager
        Task { await load() }
    }

    func load() async {
        guard let manager else { return }
        isLoading = true
        do {
            alarms = try await manager.getAlarms().sorted { $0.startTime < $1.startTime }
            errorMessage = nil
        } catch {
            sonosDiagLog(.error, tag: "ALARMS", "List failed", context: ["error": error.localizedDescription])
            errorMessage = L10n.alarmSaveFailed
        }
        isLoading = false
    }

    func setEnabled(_ alarm: SonosAlarm, _ enabled: Bool) {
        var updated = alarm
        updated.enabled = enabled
        // Reflect at once so the switch does not snap back while the
        // speaker answers; the reload afterwards is authoritative.
        if let index = alarms.firstIndex(where: { $0.id == alarm.id }) { alarms[index].enabled = enabled }
        Task { await write { try await $0.updateAlarm(updated) } }
    }

    func delete(_ alarm: SonosAlarm) {
        Task { await write { try await $0.deleteAlarm(alarm) } }
    }

    func save(_ alarm: SonosAlarm) {
        editing = nil
        Task {
            await write { manager in
                if alarm.id == 0 {
                    let id = try await manager.createAlarm(alarm)
                    if id == 0 { throw AlarmWriteError.rejected }
                } else {
                    try await manager.updateAlarm(alarm)
                }
            }
        }
    }

    private enum AlarmWriteError: Error { case rejected }

    private func write(_ change: (SonosManager) async throws -> Void) async {
        guard let manager else { return }
        isSaving = true
        do {
            try await change(manager)
            errorMessage = nil
        } catch {
            sonosDiagLog(.error, tag: "ALARMS", "Write failed", context: ["error": error.localizedDescription])
            errorMessage = L10n.alarmSaveFailed
        }
        isSaving = false
        await load()
    }

    // MARK: - Editing

    func startCreate() {
        let room = rooms.first
        editing = SonosAlarm(id: 0, startTime: "07:00:00", duration: "01:00:00", recurrence: "DAILY",
                             enabled: true, roomUUID: room?.id ?? "", programURI: SonosAlarm.chimeURI,
                             programMetaData: "", volume: 25, includeLinkedZones: false,
                             playMode: "REPEAT_ALL", roomName: room?.name ?? "")
        isNew = true
    }

    func startEdit(_ alarm: SonosAlarm) {
        editing = alarm
        isNew = false
    }

    /// One entry per room (coordinators only, so stereo pairs and
    /// surrounds do not repeat), name-sorted.
    var rooms: [(id: String, name: String)] {
        guard let manager else { return [] }
        var seen = Set<String>()
        var rooms: [(id: String, name: String)] = []
        for group in manager.groups {
            if let coordinator = group.coordinator, seen.insert(coordinator.roomName).inserted {
                rooms.append((coordinator.id, coordinator.roomName))
            }
        }
        return rooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Sonos favorites are the programs an alarm can play besides the
    /// chime; loaded when the picker first opens.
    func loadFavorites() async {
        guard let manager, !favoritesLoaded else { return }
        favorites = ((try? await manager.browse(objectID: BrowseID.favorites, householdID: nil, count: 200))?.items ?? [])
            .filter { !($0.resourceURI ?? "").isEmpty }
        favoritesLoaded = true
    }
}

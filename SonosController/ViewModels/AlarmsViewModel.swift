/// AlarmsViewModel.swift — Business logic for alarm management.
/// Uses ObservableObject (not @Observable) for reliable popover support on macOS.
import Foundation
import SonosKit

@MainActor
final class AlarmsViewModel: ObservableObject {
    let sonosManager: any AlarmServiceProtocol

    @Published var alarms: [SonosAlarm] = []
    @Published var isLoading = false
    @Published var editingAlarm: SonosAlarm?
    @Published var isCreating = false

    init(sonosManager: any AlarmServiceProtocol) {
        self.sonosManager = sonosManager
    }

    func loadAlarms() async {
        isLoading = true
        do {
            let result = try await sonosManager.getAlarms()
            sonosDebugLog("[ALARM] Fetched \(result.count) alarms from speaker")
            for a in result {
                sonosDebugLog("[ALARM]   ID=\(a.id) \(a.startTime) \(a.recurrence) room=\(a.roomName)")
            }
            alarms = result
            alarms.sort { $0.startTime < $1.startTime }
        } catch {
            sonosDebugLog("[ALARM] Load failed: \(error)")
        }
        isLoading = false
        sonosDebugLog("[ALARM] isLoading=\(isLoading) alarms.count=\(alarms.count)")
    }

    func toggleAlarm(_ alarm: SonosAlarm, enabled: Bool) async {
        var updated = alarm
        updated.enabled = enabled
        do {
            try await sonosManager.updateAlarm(updated)
            if let idx = alarms.firstIndex(where: { $0.id == alarm.id }) {
                alarms[idx].enabled = enabled
            }
        } catch {
            sonosDebugLog("[ALARM] Toggle alarm failed: \(error)")
        }
    }

    func deleteAlarm(_ alarm: SonosAlarm) async {
        do {
            try await sonosManager.deleteAlarm(alarm)
        } catch {
            sonosDebugLog("[ALARM] Delete alarm failed: \(error)")
        }
        await loadAlarms()
    }

    func saveAlarm(_ alarm: SonosAlarm) async {
        do {
            if alarm.id == 0 {
                try await sonosManager.createAlarm(alarm)
            } else {
                try await sonosManager.updateAlarm(alarm)
            }
        } catch {
            sonosDebugLog("[ALARM] Save alarm failed: \(error)")
        }
        // Reload from speaker to get authoritative state
        await loadAlarms()
    }

    func startCreate() {
        let defaultRoom = sonosManager.groups.first?.coordinator
        editingAlarm = SonosAlarm(
            id: 0,
            startTime: "07:00:00",
            duration: "01:00:00",
            recurrence: "DAILY",
            enabled: true,
            roomUUID: defaultRoom?.id ?? "",
            volume: 25,
            roomName: defaultRoom?.roomName ?? ""
        )
        isCreating = true
    }

    func startEdit(_ alarm: SonosAlarm) {
        editingAlarm = alarm
        isCreating = false
    }

    var availableRooms: [(id: String, name: String)] {
        // Use group coordinators to avoid duplicates from stereo pairs, subs, surrounds
        var seen = Set<String>()
        var rooms: [(id: String, name: String)] = []
        for group in sonosManager.groups {
            if let coord = group.coordinator, !seen.contains(coord.roomName) {
                seen.insert(coord.roomName)
                rooms.append((id: coord.id, name: coord.roomName))
            }
        }
        return rooms.sorted { $0.name < $1.name }
    }
}

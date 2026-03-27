/// AlarmsViewModel.swift — Business logic for alarm management.
import Foundation
import Observation
import SonosKit

@MainActor
@Observable
final class AlarmsViewModel {
    let sonosManager: any AlarmServiceProtocol

    var alarms: [SonosAlarm] = []
    var isLoading = true
    var editingAlarm: SonosAlarm?
    var isCreating = false

    init(sonosManager: any AlarmServiceProtocol) {
        self.sonosManager = sonosManager
    }

    func loadAlarms() async {
        isLoading = true
        do {
            alarms = try await sonosManager.getAlarms()
            alarms.sort { $0.startTime < $1.startTime }
        } catch {
            sonosDebugLog("[ALARM] Load alarms failed: \(error)")
        }
        isLoading = false
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
            alarms.removeAll { $0.id == alarm.id }
        } catch {
            sonosDebugLog("[ALARM] Delete alarm failed: \(error)")
        }
    }

    func createAlarm(_ alarm: SonosAlarm) async {
        do {
            let newID = try await sonosManager.createAlarm(alarm)
            var created = alarm
            created = SonosAlarm(
                id: newID,
                startTime: alarm.startTime,
                duration: alarm.duration,
                recurrence: alarm.recurrence,
                enabled: alarm.enabled,
                roomUUID: alarm.roomUUID,
                programURI: alarm.programURI,
                programMetaData: alarm.programMetaData,
                volume: alarm.volume,
                includeLinkedZones: alarm.includeLinkedZones,
                roomName: alarm.roomName
            )
            alarms.append(created)
            alarms.sort { $0.startTime < $1.startTime }
        } catch {
            sonosDebugLog("[ALARM] Create alarm failed: \(error)")
        }
    }

    func saveAlarm(_ alarm: SonosAlarm) async {
        if alarm.id == 0 {
            await createAlarm(alarm)
        } else {
            do {
                try await sonosManager.updateAlarm(alarm)
                if let idx = alarms.firstIndex(where: { $0.id == alarm.id }) {
                    alarms[idx] = alarm
                }
                alarms.sort { $0.startTime < $1.startTime }
            } catch {
                sonosDebugLog("[ALARM] Update alarm failed: \(error)")
            }
        }
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
        sonosManager.devices.values
            .filter { !$0.roomName.isEmpty }
            .map { (id: $0.id, name: $0.roomName) }
            .sorted { $0.name < $1.name }
    }
}

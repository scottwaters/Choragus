/// AlarmsViewModel.swift — Business logic for alarm management.
import Foundation
import Observation
import SonosKit

@MainActor
@Observable
final class AlarmsViewModel {
    let sonosManager: SonosManager

    var alarms: [SonosAlarm] = []
    var isLoading = true

    init(sonosManager: SonosManager) {
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
}

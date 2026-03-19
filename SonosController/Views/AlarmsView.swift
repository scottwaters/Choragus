import SwiftUI
import SonosKit

struct AlarmsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @State private var alarms: [SonosAlarm] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Alarms")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await loadAlarms() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if alarms.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "alarm")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No alarms set")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(alarms) { alarm in
                        AlarmRow(alarm: alarm, onToggle: { enabled in
                            Task { await toggleAlarm(alarm, enabled: enabled) }
                        })
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                Task { await deleteAlarm(alarm) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { Task { await loadAlarms() } }
    }

    private func loadAlarms() async {
        isLoading = true
        do {
            alarms = try await sonosManager.getAlarms()
            alarms.sort { $0.startTime < $1.startTime }
        } catch {
            print("Failed to load alarms: \(error)")
        }
        isLoading = false
    }

    private func toggleAlarm(_ alarm: SonosAlarm, enabled: Bool) async {
        var updated = alarm
        updated.enabled = enabled
        do {
            try await sonosManager.updateAlarm(updated)
            if let idx = alarms.firstIndex(where: { $0.id == alarm.id }) {
                alarms[idx].enabled = enabled
            }
        } catch {
            print("Failed to toggle alarm: \(error)")
        }
    }

    private func deleteAlarm(_ alarm: SonosAlarm) async {
        do {
            try await sonosManager.deleteAlarm(alarm)
            alarms.removeAll { $0.id == alarm.id }
        } catch {
            print("Failed to delete alarm: \(error)")
        }
    }
}

struct AlarmRow: View {
    let alarm: SonosAlarm
    let onToggle: (Bool) -> Void

    @State private var isEnabled: Bool

    init(alarm: SonosAlarm, onToggle: @escaping (Bool) -> Void) {
        self.alarm = alarm
        self.onToggle = onToggle
        self._isEnabled = State(initialValue: alarm.enabled)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.displayTime)
                    .font(.title3)
                    .fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(alarm.recurrenceDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !alarm.roomName.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(alarm.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: isEnabled) {
                    onToggle(isEnabled)
                }
        }
        .padding(.vertical, 4)
    }
}

/// AlarmsView.swift — Alarm list with toggle, delete, and refresh.
/// Thin view layer — all business logic lives in AlarmsViewModel.
import SwiftUI
import SonosKit

struct AlarmsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @State private var vm: AlarmsViewModel?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.alarms)
                    .font(.headline)
                Spacer()
                Button {
                    Task { await vm?.loadAlarms() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if let vm {
                if vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.alarms.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "alarm")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text(L10n.noAlarmsSet)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(vm.alarms) { alarm in
                            AlarmRow(alarm: alarm, onToggle: { enabled in
                                Task { await vm.toggleAlarm(alarm, enabled: enabled) }
                            })
                            .contextMenu {
                                Button(L10n.delete, role: .destructive) {
                                    Task { await vm.deleteAlarm(alarm) }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .onAppear {
            if vm == nil { vm = AlarmsViewModel(sonosManager: sonosManager) }
            Task { await vm?.loadAlarms() }
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

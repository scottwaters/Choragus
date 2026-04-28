/// AlarmsView.swift — Alarm list with create, edit, toggle, and delete.
/// Reads alarms directly from SonosManager.cachedAlarms (@Published)
/// to avoid observation issues across popover window boundaries.
import SwiftUI
import SonosKit

struct AlarmsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @State private var editingAlarm: SonosAlarm?
    @State private var isCreating = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.alarms)
                    .font(.headline)
                Spacer()
                Button { startCreate() } label: {
                    Image(systemName: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .tooltip(L10n.newAlarm)

                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain)
                .tooltip(L10n.refresh)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if isLoading && sonosManager.cachedAlarms.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sonosManager.cachedAlarms.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "alarm")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(L10n.noAlarmsSet)
                        .foregroundStyle(.secondary)
                    Button(L10n.createAlarmButton) { startCreate() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sonosManager.cachedAlarms) { alarm in
                        AlarmRow(alarm: alarm, onToggle: { enabled in
                            toggleAlarm(alarm, enabled: enabled)
                        })
                        .contentShape(Rectangle())
                        .onTapGesture { startEdit(alarm) }
                        .contextMenu {
                            Button(L10n.edit) { startEdit(alarm) }
                            Divider()
                            Button(L10n.delete, role: .destructive) {
                                deleteAlarm(alarm)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            refresh()
        }
        .sheet(item: $editingAlarm) { alarm in
            AlarmEditorView(
                alarm: alarm,
                rooms: availableRooms,
                isNew: isCreating
            ) { saved in
                saveAlarm(saved)
                editingAlarm = nil
            } onCancel: {
                editingAlarm = nil
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        isLoading = true
        Task {
            await sonosManager.refreshAlarms()
            isLoading = false
        }
    }

    private func toggleAlarm(_ alarm: SonosAlarm, enabled: Bool) {
        var updated = alarm
        updated.enabled = enabled
        Task {
            try? await sonosManager.updateAlarm(updated)
            await sonosManager.refreshAlarms()
        }
    }

    private func deleteAlarm(_ alarm: SonosAlarm) {
        Task {
            try? await sonosManager.deleteAlarm(alarm)
            await sonosManager.refreshAlarms()
        }
    }

    private func saveAlarm(_ alarm: SonosAlarm) {
        Task {
            if alarm.id == 0 {
                try? await sonosManager.createAlarm(alarm)
            } else {
                try? await sonosManager.updateAlarm(alarm)
            }
            await sonosManager.refreshAlarms()
        }
    }

    private func startCreate() {
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

    private func startEdit(_ alarm: SonosAlarm) {
        editingAlarm = alarm
        isCreating = false
    }

    private var availableRooms: [(id: String, name: String)] {
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

// MARK: - Alarm Row

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
                        Text("·").foregroundStyle(.tertiary)
                        Text(alarm.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Image(systemName: "speaker.wave.2")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                    Text("\(alarm.volume)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Toggle("", isOn: $isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: isEnabled) { onToggle(isEnabled) }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Alarm Editor

struct AlarmEditorView: View {
    let rooms: [(id: String, name: String)]
    let isNew: Bool
    let onSave: (SonosAlarm) -> Void
    let onCancel: () -> Void

    @State private var alarm: SonosAlarm
    @State private var selectedDate: Date
    @State private var recurrence: String
    @State private var selectedRoomID: String
    @State private var volume: Double
    @State private var durationMinutes: Int
    @State private var includeLinked: Bool

    init(alarm: SonosAlarm, rooms: [(id: String, name: String)], isNew: Bool,
         onSave: @escaping (SonosAlarm) -> Void, onCancel: @escaping () -> Void) {
        self.rooms = rooms
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self._alarm = State(initialValue: alarm)

        let parts = alarm.startTime.split(separator: ":").compactMap { Int($0) }
        let h = parts.count >= 1 ? parts[0] : 7
        let m = parts.count >= 2 ? parts[1] : 0
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h; comps.minute = m
        self._selectedDate = State(initialValue: Calendar.current.date(from: comps) ?? Date())
        self._recurrence = State(initialValue: alarm.recurrence)
        self._selectedRoomID = State(initialValue: alarm.roomUUID)
        self._volume = State(initialValue: Double(alarm.volume))
        self._includeLinked = State(initialValue: alarm.includeLinkedZones)

        let dParts = alarm.duration.split(separator: ":").compactMap { Int($0) }
        self._durationMinutes = State(initialValue: (dParts.count >= 1 ? dParts[0] : 1) * 60 + (dParts.count >= 2 ? dParts[1] : 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? L10n.newAlarm : L10n.editAlarm)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { onCancel() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    editorRow(L10n.alarmTime) {
                        DatePicker("", selection: $selectedDate, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .frame(width: 100)
                    }
                    editorRow(L10n.alarmRepeat) {
                        Picker("", selection: $recurrence) {
                            Text(L10n.everyDay).tag("DAILY")
                            Text(L10n.weekdays).tag("WEEKDAYS")
                            Text(L10n.weekends).tag("WEEKENDS")
                            Text(L10n.onceLabel).tag("ONCE")
                        }
                        .labelsHidden().fixedSize()
                    }
                    editorRow(L10n.roomLabel) {
                        Picker("", selection: $selectedRoomID) {
                            ForEach(rooms, id: \.id) { room in
                                Text(room.name).tag(room.id)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    editorRow("") {
                        Toggle(L10n.includeGroupedSpeakers, isOn: $includeLinked)
                            .toggleStyle(.checkbox)
                    }
                    editorRow(L10n.volumeLabel) {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $volume, in: 0...100, step: 1).frame(maxWidth: 180)
                            Text("\(Int(volume))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                    editorRow(L10n.durationLabel) {
                        Picker("", selection: $durationMinutes) {
                            Text(L10n.minutes15).tag(15)
                            Text(L10n.minutes30).tag(30)
                            Text(L10n.hour1).tag(60)
                            Text(L10n.hours2).tag(120)
                            Text(L10n.hours3).tag(180)
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button(L10n.cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? L10n.createAlarmButton : L10n.saveChanges) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 420)
    }

    private func editorRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            if !label.isEmpty {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    .frame(width: 65, alignment: .trailing)
            } else {
                Spacer().frame(width: 65)
            }
            content()
            Spacer(minLength: 0)
        }
    }

    private func save() {
        let cal = Calendar.current
        var saved = alarm
        saved.startTime = String(format: "%02d:%02d:00", cal.component(.hour, from: selectedDate), cal.component(.minute, from: selectedDate))
        saved.recurrence = recurrence
        saved.roomUUID = selectedRoomID
        saved.roomName = rooms.first { $0.id == selectedRoomID }?.name ?? ""
        saved.volume = Int(volume)
        saved.duration = String(format: "%02d:%02d:00", durationMinutes / 60, durationMinutes % 60)
        saved.includeLinkedZones = includeLinked
        onSave(saved)
    }
}

/// AlarmsView.swift — Alarm list with create, edit, toggle, and delete.
import SwiftUI
import SonosKit

struct AlarmsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @State private var vm: AlarmsViewModel

    init(sonosManager: SonosManager) {
        _vm = State(initialValue: AlarmsViewModel(sonosManager: sonosManager))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.alarms)
                    .font(.headline)
                Spacer()
                Button { vm.startCreate() } label: {
                    Image(systemName: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .tooltip("New Alarm")

                Button { Task { await vm.loadAlarms() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.plain)
                .tooltip("Refresh")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

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
                    Button("Create Alarm") { vm.startCreate() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(vm.alarms) { alarm in
                        AlarmRow(alarm: alarm, onToggle: { enabled in
                            Task { await vm.toggleAlarm(alarm, enabled: enabled) }
                        })
                        .contentShape(Rectangle())
                        .onTapGesture { vm.startEdit(alarm) }
                        .contextMenu {
                            Button("Edit") { vm.startEdit(alarm) }
                            Divider()
                            Button(L10n.delete, role: .destructive) {
                                Task { await vm.deleteAlarm(alarm) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task {
            await vm.loadAlarms()
        }
        .sheet(item: $vm.editingAlarm) { alarm in
            AlarmEditorView(
                alarm: alarm,
                rooms: vm.availableRooms,
                isNew: vm.isCreating
            ) { saved in
                Task { await vm.saveAlarm(saved) }
                vm.editingAlarm = nil
            } onCancel: {
                vm.editingAlarm = nil
            }
        }
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
                        .font(.system(size: 9))
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

        // Parse startTime into a Date for DatePicker
        let parts = alarm.startTime.split(separator: ":").compactMap { Int($0) }
        let h = parts.count >= 1 ? parts[0] : 7
        let m = parts.count >= 2 ? parts[1] : 0
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h
        comps.minute = m
        self._selectedDate = State(initialValue: Calendar.current.date(from: comps) ?? Date())
        self._recurrence = State(initialValue: alarm.recurrence)
        self._selectedRoomID = State(initialValue: alarm.roomUUID)
        self._volume = State(initialValue: Double(alarm.volume))
        self._includeLinked = State(initialValue: alarm.includeLinkedZones)

        // Parse duration into minutes
        let dParts = alarm.duration.split(separator: ":").compactMap { Int($0) }
        let mins = (dParts.count >= 1 ? dParts[0] : 1) * 60 + (dParts.count >= 2 ? dParts[1] : 0)
        self._durationMinutes = State(initialValue: mins)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNew ? "New Alarm" : "Edit Alarm")
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
                    // Time
                    editorRow("Time") {
                        DatePicker("", selection: $selectedDate, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .frame(width: 100)
                    }

                    // Repeat
                    editorRow("Repeat") {
                        Picker("", selection: $recurrence) {
                            Text("Every Day").tag("DAILY")
                            Text("Weekdays").tag("WEEKDAYS")
                            Text("Weekends").tag("WEEKENDS")
                            Text("Once").tag("ONCE")
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    // Room
                    editorRow("Room") {
                        Picker("", selection: $selectedRoomID) {
                            ForEach(rooms, id: \.id) { room in
                                Text(room.name).tag(room.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    // Include grouped
                    editorRow("") {
                        Toggle("Include grouped speakers", isOn: $includeLinked)
                            .toggleStyle(.checkbox)
                    }

                    // Volume
                    editorRow("Volume") {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $volume, in: 0...100, step: 1)
                                .frame(maxWidth: 180)
                            Text("\(Int(volume))")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                        }
                    }

                    // Duration
                    editorRow("Duration") {
                        Picker("", selection: $durationMinutes) {
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                            Text("1 hour").tag(60)
                            Text("2 hours").tag(120)
                            Text("3 hours").tag(180)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create Alarm" : "Save Changes") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 420)
    }

    private func editorRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
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
        let h = cal.component(.hour, from: selectedDate)
        let m = cal.component(.minute, from: selectedDate)

        var saved = alarm
        saved.startTime = String(format: "%02d:%02d:00", h, m)
        saved.recurrence = recurrence
        saved.roomUUID = selectedRoomID
        saved.roomName = rooms.first { $0.id == selectedRoomID }?.name ?? ""
        saved.volume = Int(volume)
        saved.duration = String(format: "%02d:%02d:00", durationMinutes / 60, durationMinutes % 60)
        saved.includeLinkedZones = includeLinked
        onSave(saved)
    }
}

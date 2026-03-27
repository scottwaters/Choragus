/// AlarmsView.swift — Alarm list with create, edit, toggle, and delete.
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
                    vm?.startCreate()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .tooltip("New Alarm")

                Button {
                    Task { await vm?.loadAlarms() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .tooltip("Refresh")
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
        }
        .onAppear {
            if vm == nil { vm = AlarmsViewModel(sonosManager: sonosManager) }
            Task { await vm?.loadAlarms() }
        }
        .sheet(item: Binding(
            get: { vm?.editingAlarm },
            set: { vm?.editingAlarm = $0 }
        )) { alarm in
            AlarmEditorView(
                alarm: alarm,
                rooms: vm?.availableRooms ?? [],
                isNew: vm?.isCreating ?? false
            ) { saved in
                Task { await vm?.saveAlarm(saved) }
                vm?.editingAlarm = nil
            } onCancel: {
                vm?.editingAlarm = nil
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
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(alarm.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("·")
                        .foregroundStyle(.tertiary)
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
                .onChange(of: isEnabled) {
                    onToggle(isEnabled)
                }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Alarm Editor

struct AlarmEditorView: View {
    @State var alarm: SonosAlarm
    let rooms: [(id: String, name: String)]
    let isNew: Bool
    let onSave: (SonosAlarm) -> Void
    let onCancel: () -> Void

    @State private var hour: Int
    @State private var minute: Int
    @State private var recurrence: String
    @State private var selectedRoomID: String
    @State private var volume: Double
    @State private var duration: String
    @State private var includeLinked: Bool
    @State private var showDeleteConfirm = false

    init(alarm: SonosAlarm, rooms: [(id: String, name: String)], isNew: Bool,
         onSave: @escaping (SonosAlarm) -> Void, onCancel: @escaping () -> Void) {
        self._alarm = State(initialValue: alarm)
        self.rooms = rooms
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel

        let parts = alarm.startTime.split(separator: ":").compactMap { Int($0) }
        self._hour = State(initialValue: parts.count >= 1 ? parts[0] : 7)
        self._minute = State(initialValue: parts.count >= 2 ? parts[1] : 0)
        self._recurrence = State(initialValue: alarm.recurrence)
        self._selectedRoomID = State(initialValue: alarm.roomUUID)
        self._volume = State(initialValue: Double(alarm.volume))
        self._duration = State(initialValue: alarm.duration)
        self._includeLinked = State(initialValue: alarm.includeLinkedZones)
    }

    private let recurrenceOptions = [
        ("DAILY", "Every Day"),
        ("WEEKDAYS", "Weekdays"),
        ("WEEKENDS", "Weekends"),
        ("ONCE", "Once")
    ]

    private let durationOptions = [
        ("00:15:00", "15 min"),
        ("00:30:00", "30 min"),
        ("01:00:00", "1 hour"),
        ("02:00:00", "2 hours")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Title
            HStack {
                Text(isNew ? "New Alarm" : "Edit Alarm")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            Form {
                // Time picker
                Section("Time") {
                    HStack(spacing: 4) {
                        Picker("Hour", selection: $hour) {
                            ForEach(0..<24, id: \.self) { h in
                                Text(String(format: "%d", h == 0 ? 12 : (h > 12 ? h - 12 : h))).tag(h)
                            }
                        }
                        .frame(width: 70)
                        Text(":")
                        Picker("Minute", selection: $minute) {
                            ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { m in
                                Text(String(format: "%02d", m)).tag(m)
                            }
                        }
                        .frame(width: 70)
                        Text(hour >= 12 ? "PM" : "AM")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                    }
                }

                // Recurrence
                Section("Repeat") {
                    Picker("Repeat", selection: $recurrence) {
                        ForEach(recurrenceOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                }

                // Room
                Section("Room") {
                    Picker("Room", selection: $selectedRoomID) {
                        ForEach(rooms, id: \.id) { room in
                            Text(room.name).tag(room.id)
                        }
                    }
                    .labelsHidden()

                    Toggle("Include grouped speakers", isOn: $includeLinked)
                }

                // Volume
                Section("Volume: \(Int(volume))") {
                    Slider(value: $volume, in: 0...100, step: 1)
                }

                // Duration
                Section("Duration") {
                    Picker("Duration", selection: $duration) {
                        ForEach(durationOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)

            Divider()

            // Buttons
            HStack {
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Create" : "Save") {
                    var saved = alarm
                    saved.startTime = String(format: "%02d:%02d:00", hour, minute)
                    saved.recurrence = recurrence
                    saved.roomUUID = selectedRoomID
                    saved.roomName = rooms.first { $0.id == selectedRoomID }?.name ?? ""
                    saved.volume = Int(volume)
                    saved.duration = duration
                    saved.includeLinkedZones = includeLinked
                    onSave(saved)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 380, height: 480)
    }
}

/// AlarmsView.swift — The Alarms window: every Sonos alarm as a row with
/// its time, week strip, room, music and a switch; an editor sheet for
/// the same fields the Sonos desktop app offers.
import SwiftUI
import SonosKit

struct AlarmsView: View {
    @Environment(SonosManager.self) private var sonosManager
    @Environment(\.controlActiveState) private var activeState
    @StateObject private var vm = AlarmsViewModel()
    @State private var selection: Int?

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 360)
        .task { vm.attach(sonosManager) }
        // The Sonos app may have changed alarms while this window sat
        // behind; re-read whenever it comes to the front.
        .onChange(of: activeState) { _, state in
            if state == .key, vm.editing == nil { Task { await vm.load() } }
        }
        .sheet(item: $vm.editing) { alarm in
            AlarmEditorView(alarm: alarm, isNew: vm.isNew, rooms: vm.rooms, vm: vm)
        }
    }

    private var selectedAlarm: SonosAlarm? { vm.alarms.first { $0.id == selection } }

    @ViewBuilder
    private var content: some View {
        if vm.alarms.isEmpty {
            VStack(spacing: 10) {
                if vm.isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "alarm").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(L10n.noAlarmsSet).foregroundStyle(.secondary)
                    Button(L10n.createAlarmButton) { vm.startCreate() }.controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Selection is our own state so the highlight follows the
            // theme accent (List's built-in selection ignores .tint).
            List {
                ForEach(vm.alarms) { alarm in
                    let selected = selection == alarm.id
                    AlarmRow(alarm: alarm, accent: sonosManager.themeAccent, selected: selected,
                             onToggle: { vm.setEnabled(alarm, $0) })
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { selection = alarm.id; vm.startEdit(alarm) }
                        .onTapGesture { selection = alarm.id }
                        .listRowBackground(RoundedRectangle(cornerRadius: 8)
                            .fill(selected ? sonosManager.themeAccent.opacity(0.18) : Color.clear)
                            .padding(.horizontal, 6))
                        .listRowSeparator(.visible)
                        .contextMenu {
                            Button(L10n.edit) { vm.startEdit(alarm) }
                            Divider()
                            Button(L10n.alarmDeleteAlarm, role: .destructive) { vm.delete(alarm) }
                        }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand { if let alarm = selectedAlarm { vm.delete(alarm) } }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ControlGroup {
                Button { vm.startCreate() } label: { Image(systemName: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help(L10n.newAlarm)
                Button { if let alarm = selectedAlarm { vm.delete(alarm) } } label: { Image(systemName: "minus") }
                    .disabled(selectedAlarm == nil)
                    .help(L10n.alarmDeleteAlarm)
            }
            .fixedSize()
            Button(L10n.edit) { if let alarm = selectedAlarm { vm.startEdit(alarm) } }
                .keyboardShortcut(.defaultAction)
                .tint(sonosManager.themeAccent)
                .disabled(selectedAlarm == nil)
            if vm.isLoading || vm.isSaving {
                ProgressView().controlSize(.small).padding(.leading, 4)
            }
            if let message = vm.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Row

/// Switch, time and repeat, room and music, then the week strip. Nothing
/// appears or moves on hover; edit and delete live in the footer, the
/// context menu, double-click and the Delete key.
private struct AlarmRow: View {
    let alarm: SonosAlarm
    let accent: Color
    let selected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Toggle("", isOn: Binding(get: { alarm.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(AlarmFormat.time(alarm.startTime))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                Text(AlarmFormat.recurrence(alarm))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(alarm.roomName.isEmpty ? "—" : alarm.roomName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: alarm.isChime ? "bell" : "music.note")
                    Text(alarm.isChime ? L10n.alarmChime : alarm.programTitle).lineLimit(1)
                    Text("·")
                    Image(systemName: "speaker.wave.2")
                    Text("\(alarm.volume)").monospacedDigit()
                    Text("·")
                    Text(alarm.hasNoLimit ? L10n.alarmNoLimit : L10n.alarmMinutesFormat(alarm.durationMinutes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            WeekStrip(days: alarm.activeDays, once: alarm.isOnce, accent: accent, enabled: alarm.enabled)
        }
        .padding(.vertical, 6)
        .opacity(alarm.enabled ? 1 : 0.65)
    }
}

/// Seven day dots in the user's week order, filled for active days.
private struct WeekStrip: View {
    let days: Set<Int>
    let once: Bool
    let accent: Color
    let enabled: Bool

    var body: some View {
        HStack(spacing: 3) {
            if once {
                Text(L10n.onceLabel)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            } else {
                ForEach(AlarmFormat.weekOrder, id: \.self) { day in
                    let on = days.contains(day)
                    Text(AlarmFormat.dayLetters[day])
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(on ? accent.opacity(enabled ? 1 : 0.45) : Color.secondary.opacity(0.14)))
                        .foregroundStyle(on ? Color.white : Color.secondary)
                }
            }
        }
        .frame(width: 164, alignment: .trailing)
    }
}

// MARK: - Editor

/// The alarm sheet: the time and on/off switch as the hero, the days
/// under it, then grouped sections for what plays, how loud, and how
/// long — switches and menus, no checkbox grids or stepper fields.
struct AlarmEditorView: View {
    let isNew: Bool
    let rooms: [(id: String, name: String)]
    @ObservedObject var vm: AlarmsViewModel
    @Environment(SonosManager.self) private var sonosManager

    @State private var draft: SonosAlarm
    @State private var time: Date
    @State private var days: Set<Int>
    @State private var once: Bool
    @State private var durationMinutes: Int   // 0 = no limit
    @State private var volume: Double
    @State private var program: String        // programURI; chime = SonosAlarm.chimeURI

    init(alarm: SonosAlarm, isNew: Bool, rooms: [(id: String, name: String)], vm: AlarmsViewModel) {
        self.isNew = isNew
        self.rooms = rooms
        self.vm = vm
        _draft = State(initialValue: alarm)
        _time = State(initialValue: AlarmFormat.date(from: alarm.startTime))
        _days = State(initialValue: alarm.isOnce ? Set(0...6) : alarm.activeDays)
        _once = State(initialValue: alarm.isOnce)
        _durationMinutes = State(initialValue: alarm.hasNoLimit ? 0 : max(1, alarm.durationMinutes))
        _volume = State(initialValue: Double(alarm.volume))
        _program = State(initialValue: alarm.isChime ? SonosAlarm.chimeURI : alarm.programURI)
    }

    private static let durations = [0, 15, 30, 45, 60, 90, 120, 180]
    private var accent: Color { sonosManager.themeAccent }

    var body: some View {
        VStack(spacing: 0) {
            hero
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 8)
            Form {
                Section(L10n.alarmSectionPlay) {
                    Picker(L10n.roomLabel, selection: $draft.roomUUID) {
                        ForEach(rooms, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    Picker(L10n.alarmMusic, selection: $program) {
                        Label(L10n.alarmChime, systemImage: "bell").tag(SonosAlarm.chimeURI)
                        if !vm.favorites.isEmpty {
                            Divider()
                            ForEach(vm.favorites) { item in
                                Label(item.title, systemImage: item.isStation ? "dot.radiowaves.left.and.right" : "music.note.list")
                                    .tag(item.resourceURI ?? "")
                            }
                        }
                    }
                    Toggle(L10n.includeGroupedSpeakers, isOn: $draft.includeLinkedZones)
                    Toggle(L10n.alarmShuffle, isOn: Binding(get: { draft.shuffle }, set: { draft.shuffle = $0 }))
                        .disabled(program == SonosAlarm.chimeURI)
                }
                Section {
                    LabeledContent(L10n.volumeLabel) {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            Slider(value: $volume, in: 0...100).tint(accent)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                            Text("\(Int(volume))").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                        }
                    }
                    Picker(L10n.alarmStopAfter, selection: $durationMinutes) {
                        ForEach(Self.durations, id: \.self) { minutes in
                            Text(minutes == 0 ? L10n.alarmNoLimit : L10n.alarmMinutesFormat(minutes)).tag(minutes)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                if !isNew {
                    Button(L10n.alarmDeleteAlarm, role: .destructive) { vm.delete(draft); vm.editing = nil }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(L10n.cancel) { vm.editing = nil }.keyboardShortcut(.cancelAction)
                Button(isNew ? L10n.createAlarmButton : L10n.saveChanges) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(draft.roomUUID.isEmpty || (!once && days.isEmpty))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 500)
        .task { await vm.loadFavorites() }
        .onChange(of: program) { _, uri in
            if uri == SonosAlarm.chimeURI {
                draft.programURI = SonosAlarm.chimeURI; draft.programMetaData = ""
            } else if let item = vm.favorites.first(where: { $0.resourceURI == uri }) {
                draft.programURI = uri; draft.programMetaData = item.resourceMetadata ?? ""
            }
        }
    }

    /// Big time, the on/off switch beside it, the days under it.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? L10n.newAlarm : L10n.editAlarm)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    BigTimePicker(time: $time, accent: accent, dimmed: !draft.enabled)
                }
                Spacer()
                Toggle(L10n.alarmOn, isOn: $draft.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.large)
                    .tint(accent)
                    .help(L10n.alarmOn)
            }
            HStack(spacing: 8) {
                ForEach(AlarmFormat.weekOrder, id: \.self) { day in
                    let on = !once && days.contains(day)
                    Button {
                        if once { once = false; days = [day] }
                        else if on { days.remove(day) } else { days.insert(day) }
                    } label: {
                        Text(AlarmFormat.dayLetters[day])
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(on ? accent : Color.clear))
                            .overlay(Circle().strokeBorder(on ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1))
                            .foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    once.toggle()
                    if !once, days.isEmpty { days = Set(0...6) }
                } label: {
                    Text(L10n.alarmOnceOnly)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(once ? accent : Color.clear))
                        .overlay(Capsule().strokeBorder(once ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1))
                        .foregroundStyle(once ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Text(once ? L10n.onceLabel : AlarmFormat.recurrence(SonosAlarm(id: 0, recurrence: SonosAlarm.recurrence(days: days))))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func save() {
        var alarm = draft
        let calendar = Calendar.current
        alarm.startTime = String(format: "%02d:%02d:00", calendar.component(.hour, from: time), calendar.component(.minute, from: time))
        alarm.recurrence = once ? "ONCE" : SonosAlarm.recurrence(days: days)
        alarm.duration = durationMinutes == 0 ? "" : String(format: "%02d:%02d:00", durationMinutes / 60, durationMinutes % 60)
        alarm.volume = Int(volume)
        alarm.roomName = rooms.first { $0.id == alarm.roomUUID }?.name ?? alarm.roomName
        if program == SonosAlarm.chimeURI { alarm.programURI = SonosAlarm.chimeURI; alarm.programMetaData = "" }
        vm.save(alarm)
    }
}

// MARK: - Time picker

/// Hour and minute as large digits: type them, nudge with the chevrons,
/// or use the arrow keys; AM/PM as two pills when the locale uses them.
/// No stepper field, no wheel — the digits themselves are the control.
private struct BigTimePicker: View {
    @Binding var time: Date
    let accent: Color
    let dimmed: Bool
    @FocusState private var focused: Part?
    @State private var hourText = ""
    @State private var minuteText = ""

    private enum Part: Hashable { case hour, minute }

    private static let uses24Hour: Bool = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return !format.contains("a")
    }()

    private var components: DateComponents { Calendar.current.dateComponents([.hour, .minute], from: time) }
    private var hour24: Int { components.hour ?? 0 }
    private var minute: Int { components.minute ?? 0 }
    private var isPM: Bool { hour24 >= 12 }
    private var displayHour: Int {
        if Self.uses24Hour { return hour24 }
        let h = hour24 % 12
        return h == 0 ? 12 : h
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            digitChip(text: $hourText, part: .hour, width: 40) { adjustHour($0) }
            Text(":")
                .font(.system(size: 24, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            digitChip(text: $minuteText, part: .minute, width: 44) { adjustMinute($0) }
            if !Self.uses24Hour {
                VStack(spacing: 3) {
                    periodPill("AM", pm: false)
                    periodPill("PM", pm: true)
                }
                .padding(.leading, 4)
            }
        }
        .onAppear(perform: syncText)
        .onChange(of: time) { syncText() }
        .onChange(of: focused) { old, _ in
            // Leaving a field commits what was typed.
            if old == .hour { commitHour() }
            if old == .minute { commitMinute() }
        }
    }

    private func digitChip(text: Binding<String>, part: Part, width: CGFloat, adjust: @escaping (Int) -> Void) -> some View {
        let active = focused == part
        return HStack(spacing: 4) {
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .frame(width: width)
                .focused($focused, equals: part)
                .onSubmit { part == .hour ? commitHour() : commitMinute() }
                .onChange(of: text.wrappedValue) { _, value in
                    // Digits only, two at most; a full hour jumps to minutes.
                    let digits = String(value.filter(\.isNumber).prefix(2))
                    if digits != value { text.wrappedValue = digits }
                    if part == .hour, digits.count == 2, focused == .hour { commitHour(); focused = .minute }
                }
                .onKeyPress(.upArrow) { adjust(1); return .handled }
                .onKeyPress(.downArrow) { adjust(-1); return .handled }
            VStack(spacing: 2) {
                StepButton(symbol: "chevron.up", accent: accent, active: active) { adjust(1) }
                StepButton(symbol: "chevron.down", accent: accent, active: active) { adjust(-1) }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 9).fill(active ? accent.opacity(0.14) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active ? accent : Color.clear, lineWidth: 1))
        .help(L10n.alarmTime)
    }

    /// A chevron with a real target: 20 pt wide, whole area clickable,
    /// tinted on hover so it reads as a button.
    private struct StepButton: View {
        let symbol: String
        let accent: Color
        let active: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hovering || active ? accent : Color.secondary)
                    .frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? accent.opacity(0.18) : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private func periodPill(_ label: String, pm: Bool) -> some View {
        let on = isPM == pm
        return Button {
            guard on == false else { return }
            setTime(hour: (hour24 + 12) % 24, minute: minute)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 30, height: 18)
                .background(Capsule().fill(on ? accent : Color.secondary.opacity(0.12)))
                .foregroundStyle(on ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Typing

    private func syncText() {
        hourText = String(format: Self.uses24Hour ? "%02d" : "%d", displayHour)
        minuteText = String(format: "%02d", minute)
    }

    private func commitHour() {
        guard let typed = Int(hourText) else { syncText(); return }
        if Self.uses24Hour {
            guard (0...23).contains(typed) else { syncText(); return }
            setTime(hour: typed, minute: minute)
        } else {
            guard (1...12).contains(typed) else { syncText(); return }
            setTime(hour: (typed % 12) + (isPM ? 12 : 0), minute: minute)
        }
        syncText()
    }

    private func commitMinute() {
        guard let typed = Int(minuteText), (0...59).contains(typed) else { syncText(); return }
        setTime(hour: hour24, minute: typed)
        syncText()
    }

    // MARK: Stepping

    private func adjustHour(_ delta: Int) { setTime(hour: ((hour24 + delta) % 24 + 24) % 24, minute: minute) }
    private func adjustMinute(_ delta: Int) {
        let total = ((hour24 * 60 + minute + delta) % 1440 + 1440) % 1440
        setTime(hour: total / 60, minute: total % 60)
    }
    private func setTime(hour: Int, minute: Int) {
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: time)
        parts.hour = hour; parts.minute = minute
        if let date = Calendar.current.date(from: parts) { time = date }
    }
}

// MARK: - Formatting

enum AlarmFormat {
    /// Sunday-first letters, indexed by Sonos day number.
    static let dayLetters: [String] = Calendar.current.veryShortStandaloneWeekdaySymbols
    /// Day numbers in the user's week order (locale first weekday).
    static let weekOrder: [Int] = {
        let first = Calendar.current.firstWeekday - 1
        return (0..<7).map { ($0 + first) % 7 }
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static func date(from startTime: String) -> Date {
        let parts = startTime.split(separator: ":").compactMap { Int($0) }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = parts.count > 0 ? parts[0] : 7
        components.minute = parts.count > 1 ? parts[1] : 0
        return Calendar.current.date(from: components) ?? Date()
    }

    static func time(_ startTime: String) -> String {
        timeFormatter.string(from: date(from: startTime))
    }

    static func recurrence(_ alarm: SonosAlarm) -> String {
        switch alarm.recurrence {
        case "DAILY": return L10n.everyDay
        case "WEEKDAYS": return L10n.weekdays
        case "WEEKENDS": return L10n.weekends
        case "ONCE": return L10n.onceLabel
        default:
            let names = Calendar.current.shortStandaloneWeekdaySymbols
            return weekOrder.filter { alarm.activeDays.contains($0) }.map { names[$0] }.joined(separator: " ")
        }
    }
}

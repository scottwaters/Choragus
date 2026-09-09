/// PlaybackIntents.swift — Shortcuts / Spotlight / Siri integration via
/// the App Intents framework (macOS 13+; deployment target is 14).
///
/// Each intent resolves its entity parameter against the live
/// `SonosManager` topology at execution time. If nothing matches, the
/// user gets a localised error that Shortcuts surfaces as a recoverable
/// failure.
import AppIntents
import Foundation
import SonosKit

// MARK: - Room group entity + query
//
// AppIntents requires entity-typed parameters whenever a `phrases`
// placeholder references the parameter — spoken phrases like "Play
// Choragus in \(\.$room)" only resolve against `AppEntity` /
// `AppEnum` parameters. The entity is a thin wrapper around the live
// `SonosGroup`; the query reflects the manager's current topology so
// Shortcuts and Siri see the user's actual room names rather than a
// stale list baked into the binary.

struct RoomGroupEntity: AppEntity {
    /// Stable Sonos coordinator UUID. Used to re-resolve the live
    /// group at intent execution time so topology changes between
    /// shortcut authoring and execution don't strand a stale group.
    var id: String
    /// Display name shown in the Shortcuts picker and Siri responses.
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Sonos Room")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = RoomGroupQuery()
}

struct RoomGroupQuery: EntityQuery {
    /// Single-pass lookup by coordinator ID. Returns whatever still
    /// matches in the live topology; a renamed-then-stranded entity
    /// resolves to nothing and the intent reports a clean error.
    @MainActor
    func entities(for identifiers: [String]) async throws -> [RoomGroupEntity] {
        await IntentResolution.waitForManager()
        guard let manager = SonosManager.current else { return [] }
        return manager.groups
            .filter { identifiers.contains($0.coordinatorID) }
            .map { RoomGroupEntity(id: $0.coordinatorID, name: $0.name) }
    }

    /// Full list of currently-known rooms. Powers the Shortcuts picker
    /// and Siri's "which room?" disambiguation prompt.
    @MainActor
    func suggestedEntities() async throws -> [RoomGroupEntity] {
        await IntentResolution.waitForManager()
        guard let manager = SonosManager.current else { return [] }
        return manager.groups
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { RoomGroupEntity(id: $0.coordinatorID, name: $0.name) }
    }
}

// MARK: - Group preset entity + query

struct GroupPresetEntity: AppEntity {
    /// Stable preset UUID string — survives rename, dies on delete.
    var id: String
    /// Preset name as the user saved it. Drives the Shortcuts picker
    /// label and Siri responses.
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Sonos Group Preset")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = GroupPresetQuery()
}

struct GroupPresetQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [GroupPresetEntity] {
        await IntentResolution.waitForPresetManager()
        guard let manager = PresetManager.current else { return [] }
        return manager.presets
            .filter { identifiers.contains($0.id.uuidString) }
            .map { GroupPresetEntity(id: $0.id.uuidString, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [GroupPresetEntity] {
        await IntentResolution.waitForPresetManager()
        guard let manager = PresetManager.current else { return [] }
        return manager.presets
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { GroupPresetEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

// MARK: - Physical input entity + query

/// A speaker's line-in or TV input, as offered in the Shortcuts picker.
/// Backed by `PhysicalInput` so the intent lists exactly the speakers
/// the Browse "Line-In" list does and plays them the same way.
struct PhysicalInputEntity: AppEntity {
    /// Bare ZonePlayer id of the speaker that owns the input.
    var id: String
    /// "Kitchen · Analog input" / "Lounge · TV (HDMI / Optical)" — room
    /// first so the picker sorts by room. Labels follow the in-app
    /// language (`L10n`); the intent titles around them follow the
    /// system locale (`Localizable.xcstrings`).
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Sonos Input")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery = PhysicalInputQuery()

    init(_ input: PhysicalInput) {
        id = input.deviceID
        name = "\(input.roomName) \u{00B7} \(input.kind == .tv ? L10n.lineInTVInput : L10n.lineInAnalogInput)"
    }
}

struct PhysicalInputQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PhysicalInputEntity] {
        await IntentResolution.waitForManager()
        guard let manager = SonosManager.current else { return [] }
        return PhysicalInput.inputs(in: manager.devices)
            .filter { identifiers.contains($0.deviceID) }
            .map(PhysicalInputEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PhysicalInputEntity] {
        await IntentResolution.waitForManager()
        guard let manager = SonosManager.current else { return [] }
        return PhysicalInput.inputs(in: manager.devices).map(PhysicalInputEntity.init)
    }
}

// MARK: - Shared helpers

private enum IntentResolution {
    /// Up to ~1 s wait for the SonosManager handle to land. Covers the
    /// cold-launch path where Shortcuts fires before ContentView's
    /// `onAppear` sets the static reference.
    @MainActor
    static func waitForManager() async {
        for _ in 0..<10 {
            if SonosManager.current != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Resolves a `RoomGroupEntity` to a live `SonosGroup`. The entity
    /// carries the coordinator UUID — stable across renames; if the
    /// group has dissolved between authoring and execution this
    /// returns nil and the intent reports the loss.
    @MainActor
    static func resolveGroup(_ room: RoomGroupEntity) async -> SonosGroup? {
        await waitForManager()
        guard let manager = SonosManager.current else { return nil }
        return manager.groups.first { $0.coordinatorID == room.id }
    }

    /// Localised "room not found" error for Shortcuts to display
    /// (in-app language, like every other L10n string).
    static func roomNotFoundError(_ room: RoomGroupEntity) -> Error {
        NSError(domain: "ChoragusIntents", code: 404, userInfo: [
            NSLocalizedDescriptionKey: L10n.intentRoomNotFoundFormat(room.name)
        ])
    }

    /// Up to ~1 s wait for the PresetManager handle. Same cold-launch
    /// guard as `waitForManager`.
    @MainActor
    static func waitForPresetManager() async {
        for _ in 0..<10 {
            if PresetManager.current != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Resolves the entity back to the live `GroupPreset`. Returns nil
    /// if the preset was deleted between authoring and execution.
    @MainActor
    static func resolvePreset(_ preset: GroupPresetEntity) async -> GroupPreset? {
        await waitForPresetManager()
        guard let manager = PresetManager.current else { return nil }
        return manager.presets.first { $0.id.uuidString == preset.id }
    }

    static func presetNotFoundError(_ preset: GroupPresetEntity) -> Error {
        NSError(domain: "ChoragusIntents", code: 404, userInfo: [
            NSLocalizedDescriptionKey: L10n.intentPresetNotFoundFormat(preset.name)
        ])
    }

    /// Resolves the entity back to the live input. Returns nil when the
    /// owning speaker has left the system since the shortcut was built.
    @MainActor
    static func resolveInput(_ input: PhysicalInputEntity) async -> PhysicalInput? {
        await waitForManager()
        guard let manager = SonosManager.current else { return nil }
        return PhysicalInput.inputs(in: manager.devices).first { $0.deviceID == input.id }
    }

    static func inputNotFoundError(_ input: PhysicalInputEntity) -> Error {
        NSError(domain: "ChoragusIntents", code: 404, userInfo: [
            NSLocalizedDescriptionKey: L10n.intentInputNotFoundFormat(input.name)
        ])
    }
}

// MARK: - Play

struct ChoragusPlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Play"
    static var description: IntentDescription = IntentDescription(
        "Resume playback on a Sonos room or group.")

    @Parameter(title: "Room", description: "The Sonos room or group to control.")
    var room: RoomGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play on \(\.$room)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let group = await IntentResolution.resolveGroup(room) else {
            throw IntentResolution.roomNotFoundError(room)
        }
        try? await SonosManager.current?.play(group: group)
        return .result()
    }
}

// MARK: - Pause

struct ChoragusPauseIntent: AppIntent {
    static var title: LocalizedStringResource = "Pause"
    static var description: IntentDescription = IntentDescription(
        "Pause playback on a Sonos room or group.")

    @Parameter(title: "Room")
    var room: RoomGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Pause \(\.$room)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let group = await IntentResolution.resolveGroup(room) else {
            throw IntentResolution.roomNotFoundError(room)
        }
        try? await SonosManager.current?.pause(group: group)
        return .result()
    }
}

// MARK: - Toggle Play/Pause

struct ChoragusTogglePlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Play/Pause"
    static var description: IntentDescription = IntentDescription(
        "Plays the room if paused, pauses if playing.")

    @Parameter(title: "Room")
    var room: RoomGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle play/pause on \(\.$room)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let group = await IntentResolution.resolveGroup(room) else {
            throw IntentResolution.roomNotFoundError(room)
        }
        guard let manager = SonosManager.current else { return .result() }
        let isPlaying = (manager.groupTransportStates[group.coordinatorID] ?? .stopped).isPlaying
        if isPlaying {
            try? await manager.pause(group: group)
        } else {
            try? await manager.play(group: group)
        }
        return .result()
    }
}

// MARK: - Next Track

struct ChoragusNextTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Track"
    static var description: IntentDescription = IntentDescription(
        "Skip to the next track in the room's queue.")

    @Parameter(title: "Room")
    var room: RoomGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Next track on \(\.$room)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let group = await IntentResolution.resolveGroup(room) else {
            throw IntentResolution.roomNotFoundError(room)
        }
        try? await SonosManager.current?.next(group: group)
        return .result()
    }
}

// MARK: - Previous Track

struct ChoragusPreviousTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous Track"
    static var description: IntentDescription = IntentDescription(
        "Go to the previous track in the room's queue.")

    @Parameter(title: "Room")
    var room: RoomGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Previous track on \(\.$room)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let group = await IntentResolution.resolveGroup(room) else {
            throw IntentResolution.roomNotFoundError(room)
        }
        try? await SonosManager.current?.previous(group: group)
        return .result()
    }
}

// MARK: - Set Volume

struct ChoragusSetVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Volume"
    static var description: IntentDescription = IntentDescription(
        "Set the volume on every speaker in the room or group. Levels are clamped to the Sonos 0–100 range.")

    @Parameter(title: "Room")
    var room: RoomGroupEntity

    @Parameter(title: "Level",
               description: "Volume level from 0 (silent) to 100 (loudest).",
               inclusiveRange: (0, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$room) volume to \(\.$level)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let group = await IntentResolution.resolveGroup(room) else {
            throw IntentResolution.roomNotFoundError(room)
        }
        guard let manager = SonosManager.current else { return .result() }
        let clamped = max(0, min(100, level))
        // Every member sits at N — "set to N" from Shortcuts means an
        // absolute level, not a proportional spread.
        for member in group.members {
            try? await manager.setVolume(device: member, volume: clamped)
        }
        return .result()
    }
}

// MARK: - Activate Preset

struct ChoragusActivatePresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate Preset"
    static var description: IntentDescription = IntentDescription(
        "Apply a saved group preset — restores the rooms grouped together plus their per-speaker volumes and EQ.")

    @Parameter(title: "Preset", description: "The Sonos group preset to apply.")
    var preset: GroupPresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Activate \(\.$preset)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let resolved = await IntentResolution.resolvePreset(preset) else {
            throw IntentResolution.presetNotFoundError(preset)
        }
        guard let manager = SonosManager.current,
              let presets = PresetManager.current else {
            return .result()
        }
        await presets.applyPreset(resolved, using: manager)
        return .result()
    }
}

// MARK: - Select Input

struct ChoragusSelectInputIntent: AppIntent {
    static var title: LocalizedStringResource = "Select Input"
    static var description: IntentDescription = IntentDescription(
        "Play a speaker's line-in or TV input in a room. Selecting an input that is already playing leaves it playing, so this can run on a schedule.")

    @Parameter(title: "Input", description: "The speaker input to play: analog line-in or TV.")
    var input: PhysicalInputEntity

    @Parameter(title: "Room", description: "The room or group that plays the input.")
    var room: RoomGroupEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$input) in \(\.$room)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let group = await IntentResolution.resolveGroup(room) else {
            throw IntentResolution.roomNotFoundError(room)
        }
        guard let resolved = await IntentResolution.resolveInput(input) else {
            throw IntentResolution.inputNotFoundError(input)
        }
        guard let manager = SonosManager.current else { return .result() }
        try await manager.playInput(resolved, in: group)
        return .result()
    }
}

// MARK: - Shortcut Gallery Provider

/// Tells the system about Choragus's available intents so they appear in
/// the Shortcuts app's gallery and become Siri-callable. Phrases here
/// are the user's spoken/typed invocations; the `applicationName`
/// (Choragus) prefix is implicit.
struct ChoragusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ChoragusPlayIntent(),
            phrases: [
                "Play \(.applicationName) in \(\.$room)",
                "Resume \(.applicationName) in \(\.$room)"
            ],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: ChoragusPauseIntent(),
            phrases: [
                "Pause \(.applicationName) in \(\.$room)",
                "Stop \(.applicationName) in \(\.$room)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ChoragusTogglePlayIntent(),
            phrases: [
                "Toggle \(.applicationName) in \(\.$room)"
            ],
            shortTitle: "Toggle Play/Pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: ChoragusNextTrackIntent(),
            phrases: [
                "Next track on \(.applicationName) in \(\.$room)",
                "Skip on \(.applicationName) in \(\.$room)"
            ],
            shortTitle: "Next Track",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: ChoragusPreviousTrackIntent(),
            phrases: [
                "Previous track on \(.applicationName) in \(\.$room)",
                "Back on \(.applicationName) in \(\.$room)"
            ],
            shortTitle: "Previous Track",
            systemImageName: "backward.fill"
        )
        // App Intents allows at most one parameter placeholder per
        // spoken phrase, so the volume level is collected via Siri's
        // follow-up prompt rather than spoken inline.
        AppShortcut(
            intent: ChoragusSetVolumeIntent(),
            phrases: [
                "Set \(.applicationName) volume in \(\.$room)",
                "Change \(.applicationName) volume in \(\.$room)"
            ],
            shortTitle: "Set Volume",
            systemImageName: "speaker.wave.2.fill"
        )
        AppShortcut(
            intent: ChoragusActivatePresetIntent(),
            phrases: [
                "Activate \(.applicationName) preset \(\.$preset)",
                "Apply \(.applicationName) preset \(\.$preset)"
            ],
            shortTitle: "Activate Preset",
            systemImageName: "rectangle.stack.fill"
        )
        // One placeholder per phrase: the input is spoken, Siri asks
        // for the room as a follow-up.
        AppShortcut(
            intent: ChoragusSelectInputIntent(),
            phrases: [
                "Play \(.applicationName) input \(\.$input)",
                "Select \(.applicationName) input \(\.$input)"
            ],
            shortTitle: "Select Input",
            systemImageName: "cable.connector.horizontal"
        )
    }
}

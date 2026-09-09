/// LibraryStore.swift — Owns the local-music picture: which Sonos system
/// indexes which share, what that means for playability, and the browse
/// sections built from it.
///
/// **A share is per-system, not per-path.** The same network folder configured
/// on an S1 and an S2 system is two shares, not one: each system indexes it
/// separately, must be added separately in that system's Sonos app, and must
/// be reindexed separately (`updateMusicLibrary` therefore triggers one
/// reindex per distinct system). The (S1) / (S2) / (S1/S2) tags name which
/// system a share belongs to; (S1/S2) is the same folder set up twice, with
/// two indexes that can drift apart.
///
/// Takes `TopologyStore` by injection and holds no reference back to the
/// façade. Sections contributed by other features — media servers today —
/// arrive through `additionalSections`.
import Foundation

@MainActor
@Observable
public final class LibraryStore {

    // MARK: - Helpers

    /// Total item count for a container, or nil when the browse fails.
    private func probeContainer(device: SonosDevice, objectID: String) async -> Int? {
        do {
            let (_, total) = try await contentDirectory.browse(device: device, objectID: objectID, start: 0, count: 0)
            return total
        } catch {
            return nil
        }
    }

    // MARK: - State

    /// Per-system local-library availability, keyed by householdID. Drives the
    /// (S1/S2) browse tags and the fail-fast playback gate. Refreshed from a
    /// live `Browse("S:")` per system after topology settles.
    public private(set) var householdCapabilities: [String: HouseholdCapabilities] = [:]

    /// The browse root as presented to the user.
    public internal(set) var browseSections: [BrowseSection] = []

    // MARK: - Collaborators

    @ObservationIgnored private let contentDirectory: ContentDirectoryBrowsing
    /// Injected sibling, not a back-reference to the façade.
    @ObservationIgnored private let topology: TopologyStore
    /// Sections owned by other features, appended after the speaker's own.
    @ObservationIgnored public weak var sectionContributor: BrowseSectionContributing?

    public init(contentDirectory: ContentDirectoryBrowsing,
                topology: TopologyStore) {
        self.contentDirectory = contentDirectory
        self.topology = topology
    }

    /// Seeds capabilities directly. Used by tests and by any caller that
    /// already knows the answer; the live path is `refreshHouseholdCapabilities`.
    func seedCapabilities(_ caps: [String: HouseholdCapabilities]) {
        householdCapabilities = caps
    }

    /// Restores sections from the on-disk cache at startup.
    public func applyCachedSections(_ sections: [BrowseSection]) {
        browseSections = sections
    }



    /// Normalised key for a library share / item objectID so the same folder
    /// path matches whichever system reported it, and a child track matches its
    /// share root. Matching keys means the same path, not a shared index — see
    /// the per-system note in this file's header.
    nonisolated static func normalizedShareKey(_ objectID: String) -> String {
        objectID.lowercased()
    }

    /// Pure availability decision for a local-library item against one system's
    /// share set. `S:` items match the specific share (exact root or a child
    /// path under it); `A:` aggregated-index items need any library.
    /// Returns nil for non-local objectIDs.
    nonisolated static func localLibraryPlayable(objectID: String, shareIDs: Set<String>) -> Bool? {
        if objectID.hasPrefix("S:") {
            let key = normalizedShareKey(objectID)
            return shareIDs.contains { key == $0 || key.hasPrefix($0 + "/") }
        }
        if objectID.hasPrefix("A:") {
            return !shareIDs.isEmpty
        }
        return nil
    }

    /// "(S1)" / "(S2)" / "(S1/S2)" from a set of generations, deduped, ordered,
    /// `.unknown` dropped. nil when nothing meaningful remains.
    nonisolated static func availabilityTag(for generations: [SonosSystemVersion]) -> String? {
        let gens = generations
            .filter { $0 != .unknown }
            .reduce(into: [SonosSystemVersion]()) { acc, g in if !acc.contains(g) { acc.append(g) } }
            .sorted { $0.rawValue < $1.rawValue }
        guard !gens.isEmpty else { return nil }
        return "(" + gens.map(\.displayLabel).joined(separator: "/") + ")"
    }

    /// Probe each detected system for its configured library shares and cache
    /// the result. One `Browse("S:")` per system, probed concurrently so the
    /// wait is the slowest single system, not the sum — an unreachable
    /// coordinator costs one SOAP timeout, never a multiple. Fail-soft: a
    /// system that errors is recorded with no shares rather than dropped, and
    /// the next topology refresh re-probes.
    public func refreshHouseholdCapabilities() async {
        let targets: [(household: String, coordinator: SonosDevice)] =
            topology.coordinatorPerHousehold().compactMap { hh, g in
                g.coordinator.map { (hh, $0) }
            }
        var caps: [String: HouseholdCapabilities] = [:]
        await withTaskGroup(of: HouseholdCapabilities.self) { group in
            for (hh, coord) in targets {
                group.addTask { @MainActor [contentDirectory] in
                    let generation = SonosSystemVersion.classify(swGen: coord.swGen, softwareVersion: coord.softwareVersion)
                    var shareIDs: Set<String> = []
                    if let result = try? await contentDirectory.browse(device: coord, objectID: "S:", start: 0, count: 100) {
                        for item in result.items {
                            shareIDs.insert(Self.normalizedShareKey(item.objectID))
                        }
                    }
                    return HouseholdCapabilities(householdID: hh, generation: generation, shareIDs: shareIDs)
                }
            }
            for await cap in group {
                caps[cap.householdID] = cap
            }
        }
        self.householdCapabilities = caps
    }

    /// True when more than one Sonos system (household) is on the network, i.e.
    /// when generation tags are meaningful at all.
    public var hasMultipleSystems: Bool { Set(householdCapabilities.keys).count > 1 }

    /// The generations whose system has at least one library share configured.
    public var localLibraryGenerations: [SonosSystemVersion] {
        householdCapabilities.values
            .filter(\.hasLocalLibrary)
            .map(\.generation)
            .filter { $0 != .unknown }
            .reduce(into: [SonosSystemVersion]()) { acc, g in if !acc.contains(g) { acc.append(g) } }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// "(S1)" / "(S2)" / "(S1/S2)" for a specific share row, or nil when there's
    /// only one system (nothing to disambiguate) or the share is unknown.
    public func availabilityNote(forShareObjectID objectID: String) -> String? {
        guard hasMultipleSystems else { return nil }
        let key = Self.normalizedShareKey(objectID)
        let gens = householdCapabilities.values
            .filter { $0.shareIDs.contains(key) }
            .map(\.generation)
        return Self.availabilityTag(for: gens)
    }

    /// Section-level note for the aggregated library indexes (Artists/Albums/
    /// Tracks/Folders): only shown when systems disagree about *having* a library
    /// at all (some have one, some don't). When every system has a library the
    /// indexes all exist, so no tag — the per-share notes carry the detail.
    private func librarySectionNote() -> String? {
        guard hasMultipleSystems else { return nil }
        let total = householdCapabilities.count
        let withLibrary = householdCapabilities.values.filter(\.hasLocalLibrary).count
        guard withLibrary > 0, withLibrary < total else { return nil }
        let gens = localLibraryGenerations
        guard !gens.isEmpty else { return nil }
        return "(" + gens.map(\.displayLabel).joined(separator: "/") + ")"
    }

    /// Whether the given local-library item can play on `coordinator`'s system.
    /// Share-scoped objectIDs (`S:`) check the specific share; aggregated index
    /// objectIDs (`A:`) check whether the system has any library. Fail-open:
    /// unknown system / unknown capability returns true (never block on missing
    /// data). Returns nil for non-local items.
    public func localLibraryPlayable(_ item: BrowseItem, on coordinator: SonosDevice) -> Bool? {
        guard item.objectID.hasPrefix("A:") || item.objectID.hasPrefix("S:") else { return nil }
        // Fail-open: unknown system / not-yet-probed capability never blocks.
        guard let hh = coordinator.householdID, let caps = householdCapabilities[hh] else { return true }
        return Self.localLibraryPlayable(objectID: item.objectID, shareIDs: caps.shareIDs) ?? true
    }

    /// Returns false when no device was reachable and sections were left
    /// untouched, so the owner can skip persisting a picture that did not
    /// change.
    @discardableResult
    public func loadBrowseSections() async -> Bool {
        await refreshHouseholdCapabilities()
        guard let anyDevice = topology.preferredDevice else { return false }

        var sections: [BrowseSection] = []

        sections.append(BrowseSection(id: "favorites", title: "Sonos Favorites", objectID: BrowseID.favorites, icon: "star.fill"))

        if let total = await probeContainer(device: anyDevice, objectID: BrowseID.playlists), total > 0 {
            sections.append(BrowseSection(id: "playlists", title: "Sonos Playlists", objectID: BrowseID.playlists, icon: "music.note.list"))
        }

        do {
            let (items, _) = try await contentDirectory.browse(device: anyDevice, objectID: BrowseID.libraryRoot, start: 0, count: 20)
            for item in items {
                let icon = libraryIcon(for: item.objectID)
                sections.append(BrowseSection(id: item.objectID, title: item.title, objectID: item.objectID, icon: icon))
            }
        } catch {
            sections.append(BrowseSection(id: "artists", title: "Artists", objectID: BrowseID.albumArtist, icon: "person.2"))
            sections.append(BrowseSection(id: "albums", title: "Albums", objectID: BrowseID.album, icon: "square.stack"))
            sections.append(BrowseSection(id: "tracks", title: "Tracks", objectID: BrowseID.tracks, icon: "music.note"))
        }

        if let total = await probeContainer(device: anyDevice, objectID: BrowseID.shares), total > 0 {
            sections.append(BrowseSection(id: "shares", title: "Music Library Folders", objectID: BrowseID.shares, icon: "externaldrive.connected.to.line.below"))
        }

        // Radio directory (R:0) hidden — requires TuneIn/service integration not yet enabled
        // if let total = await probeContainer(device: anyDevice, objectID: "R:0"), total > 0 {
        //     sections.append(BrowseSection(id: "radio", title: "Radio", objectID: "R:0", icon: "antenna.radiowaves.left.and.right"))
        // }

        // Tag the aggregated library sections (Artists/Albums/Tracks/Folders)
        // only when systems disagree about having a library at all. Per-share
        // tags inside "Music Library Folders" carry the finer detail.
        if let note = librarySectionNote() {
            sections = sections.map { s in
                guard s.objectID.hasPrefix("A:") || s.objectID.hasPrefix("S:") else { return s }
                var tagged = s
                tagged.availabilityNote = note
                return tagged
            }
        }

        // Sections the owner contributes — media servers today. They sit
        // alongside the speaker's own sources rather than replacing them, and
        // this store deliberately knows nothing about where they come from.
        sections.append(contentsOf: sectionContributor?.contributedBrowseSections() ?? [])

        self.browseSections = sections
        return true
    }

    /// Triggers a local music-library reindex (`RefreshShareIndex`) on every
    /// discovered household that has at least one configured share. Hits S1 and
    /// S2 systems automatically — one coordinator per distinct household — and
    /// silently skips households with no library, so a single-system setup
    /// produces no errors. Returns how many systems a reindex was sent to and
    /// how many had a library at all.
    public func updateMusicLibrary() async -> (triggered: Int, librariesFound: Int) {
        // One reachable coordinator per distinct household (S1 + S2).
        let byHousehold = topology.coordinatorPerHousehold()
        var triggered = 0
        var librariesFound = 0
        for (hh, g) in byHousehold {
            guard let coord = g.coordinator else { continue }
            // Only reindex households that have a music-library share —
            // RefreshShareIndex on a library-less household is pointless and can
            // fault. `S:` is the share-list container.
            let shareCount = (try? await contentDirectory.browse(device: coord, objectID: "S:", start: 0, count: 1).total) ?? 0
            guard shareCount > 0 else {
                sonosDebugLog("[LIBRARY] household \(hh) has no music-library share — skipped")
                continue
            }
            librariesFound += 1
            do {
                try await contentDirectory.refreshShareIndex(device: coord)
                triggered += 1
                sonosDebugLog("[LIBRARY] RefreshShareIndex sent to household \(hh) via \(coord.roomName)")
            } catch {
                sonosDebugLog("[LIBRARY] RefreshShareIndex failed for household \(hh): \(error)")
            }
        }
        return (triggered, librariesFound)
    }

    /// One configured music-library share, per household.
    public struct LibraryShare: Identifiable, Hashable {
        /// Unique per household. The browse id alone is NOT unique: two
        /// systems indexing the same NAS path report the identical
        /// `S://host/share` id, and a `ForEach` over duplicate ids
        /// renders one element twice and can send a removal to the
        /// wrong system.
        public var id: String { "\(householdID)|\(objectID)" }
        /// Browse id, e.g. `S://192.168.1.10/Media/Music`. What
        /// `DestroyObject` takes.
        public let objectID: String
        /// UNC path as the speaker reports it.
        public let path: String
        public let householdID: String
        /// Room of the coordinator the share was read from — the same
        /// device any mutation must be sent to.
        public let coordinatorRoom: String
        /// Which system indexes this share. Households running S1 beside
        /// S2 configure the same path twice, once per system, so the
        /// rows are otherwise indistinguishable.
        public let systemVersion: SonosSystemVersion
    }

    /// Lists every household's configured shares. Fail-soft per system:
    /// an unreachable coordinator contributes nothing rather than
    /// failing the whole listing.
    public func libraryShares() async -> [LibraryShare] {
        var out: [LibraryShare] = []
        for (household, group) in topology.coordinatorPerHousehold() {
            guard let coordinator = group.coordinator else { continue }
            guard let result = try? await contentDirectory.browse(device: coordinator,
                                                                  objectID: BrowseID.shares,
                                                                  start: 0, count: 100) else { continue }
            for item in result.items {
                out.append(LibraryShare(objectID: item.objectID,
                                        path: item.title,
                                        householdID: household,
                                        coordinatorRoom: coordinator.roomName,
                                        systemVersion: group.systemVersion))
            }
        }
        return out.sorted {
            $0.path == $1.path ? $0.systemVersion.displayLabel < $1.systemVersion.displayLabel
                               : $0.path < $1.path
        }
    }

    private func libraryIcon(for objectID: String) -> String {
        switch objectID {
        case "A:ALBUMARTIST", "A:ARTIST": return "person.2"
        case "A:ALBUM": return "square.stack"
        case "A:GENRE": return "guitars"
        case "A:TRACKS": return "music.note"
        case "A:COMPOSER": return "music.quarternote.3"
        case "A:PLAYLISTS": return "list.bullet.rectangle"
        default: return "folder"
        }
    }
}

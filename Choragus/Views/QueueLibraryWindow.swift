/// QueueLibraryWindow.swift — Artwork-forward manager for saved queues and
/// playlists across sources (Choragus-local, Sonos household, smart queues
/// from play history; streaming-service sources are a later pass).
///
/// Visual language borrows from the well-reviewed 2026 artwork-grid managers
/// (Doppler / Marvis / Playlist Mosaic) and the Zune/Metro aesthetic this app
/// already uses for ClubVis: bold oversized typography, content over chrome,
/// mosaic covers auto-built from member-track art. Each saved queue is a tile;
/// opening one reveals an artwork track list with play-to-room / clone /
/// rename / delete / export actions and a target-room picker.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers
import AppKit   // NSEvent.modifierFlags for the move-vs-copy drag modifier

// MARK: - Drag payload

extension UTType {
    /// In-app drag identifier for Queue Library drags (tracks and whole
    /// queues). Internal to the process, so an exported declaration is enough.
    static let choragusQueueDrag = UTType(exportedAs: "com.choragus.queue-drag")
}

/// Payload carried by a Queue Library drag — either a single track lifted out
/// of an open queue, or a whole queue card. Drop targets switch on the case.
enum QueueDragPayload: Codable, Transferable {
    case track(cardID: String, item: QueueItem)
    case card(cardID: String)
    case folder(folderID: Int64)

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .choragusQueueDrag)
    }
}

// MARK: - Model

struct QueueLibraryCard: Identifiable, Equatable {
    enum Kind: Equatable {
        case choragus(Int64)
        case sonos(String)                       // objectID
        case smart(SonosManager.SmartQueueKind)
        case history(Int64)                      // local snapshot row ID

        var sourceLabel: String {
            switch self {
            case .choragus: return "Choragus"
            case .sonos:    return "Sonos"
            case .smart:    return "Smart"
            case .history:  return "History"
            }
        }
        var badgeIcon: String {
            switch self {
            case .choragus:        return "internaldrive.fill"
            case .sonos:           return "hifispeaker.2.fill"
            case .smart(let kind): return kind.icon
            case .history:         return "clock.arrow.circlepath"
            }
        }
        var badgeColor: Color {
            switch self {
            case .choragus: return .accentColor
            case .sonos:    return .teal
            case .smart:    return .orange
            case .history:  return .purple
            }
        }
    }

    let id: String
    let name: String
    let kind: Kind
    let trackCount: Int
    /// Folders this queue belongs to (many-to-many); empty == top level.
    let folderIDs: [Int64]
    var coverURLs: [String]
    /// For history cards: the room the snapshot belongs to (grouping + filter).
    var roomName: String? = nil

    var isChoragus: Bool { if case .choragus = kind { return true }; return false }
    var localID: Int64? { if case .choragus(let id) = kind { return id }; return nil }

    static func == (lhs: QueueLibraryCard, rhs: QueueLibraryCard) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.trackCount == rhs.trackCount
            && lhs.coverURLs == rhs.coverURLs && lhs.folderIDs == rhs.folderIDs
    }
}

// MARK: - View Model

@MainActor
final class QueueLibraryViewModel: ObservableObject {
    let manager: SonosManager

    enum Filter: Equatable {
        case all, choragus, sonos, smart, history, folder(Int64)
    }

    @Published var cards: [QueueLibraryCard] = []
    @Published var folders: [SavedQueueFolder] = []
    @Published var isLoading = false
    @Published var filterText = ""
    @Published var filter: Filter = .all
    @Published var statusMessage: String?
    @Published var targetGroupID: String
    /// Scopes the smart queues by room (token-membership match, like the
    /// play-history view). nil == all rooms.
    @Published var roomFilter: String?

    private var changeObserver: NSObjectProtocol?
    private var queueObserver: NSObjectProtocol?
    private var localRefreshTask: Task<Void, Never>?

    init(manager: SonosManager, group: SonosGroup) {
        self.manager = manager
        self.targetGroupID = group.coordinatorID
        // Reload when the Choragus-local store changes elsewhere (e.g. an
        // "Add to Choragus Queue" from a browse context menu).
        changeObserver = NotificationCenter.default.addObserver(
            forName: .choragusSavedQueuesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.load() }
        }
        // The main-window live queue changing (add / remove / reorder / play)
        // produces new ephemeral History snapshots and can shift smart-queue
        // membership. Refresh the local-derived cards so the manager reflects
        // it without the user reopening — debounced and network-free so a busy
        // queue can't trigger repeated Sonos browses.
        queueObserver = NotificationCenter.default.addObserver(
            forName: .queueChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleLocalRefresh() }
        }
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let queueObserver { NotificationCenter.default.removeObserver(queueObserver) }
        localRefreshTask?.cancel()
    }

    /// Rebuilds only the local-derived cards (smart / Choragus / history),
    /// preserving the already-loaded Sonos cards, after a short debounce.
    private func scheduleLocalRefresh() {
        localRefreshTask?.cancel()
        localRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            let sonosCards = self.cards.filter { if case .sonos = $0.kind { return true }; return false }
            self.cards = self.buildLocalCards() + sonosCards
        }
    }

    var groups: [SonosGroup] { manager.groups }

    /// Room options for the filter dropdown — history rooms when on the
    /// History view, play-history rooms when on Smart.
    var roomOptions: [String] {
        if filter == .history {
            // Both the full grouping ("Office + Float") and each individual
            // room token, like the play-history room filter.
            var set = Set<String>()
            for card in cards {
                guard case .history = card.kind, let room = card.roomName, !room.isEmpty else { continue }
                set.insert(room)
                for token in room.components(separatedBy: " + ") where !token.isEmpty { set.insert(token) }
            }
            return set.sorted()
        }
        return manager.smartQueueRoomOptions()
    }

    /// Token-membership room match (a snapshot from "Office + Float" matches
    /// the filter "Office"), mirroring the play-history view.
    private func roomMatches(_ cardRoom: String?, _ filterRoom: String) -> Bool {
        guard let cardRoom else { return false }
        let tokens = filterRoom.components(separatedBy: " + ")
        let members = cardRoom.components(separatedBy: " + ")
        return tokens.allSatisfy { members.contains($0) }
    }

    /// History cards grouped by room, for the sectioned grid.
    var historyGroups: [(room: String, cards: [QueueLibraryCard])] {
        let history = displayedCards.filter { if case .history = $0.kind { return true }; return false }
        let byRoom = Dictionary(grouping: history) { $0.roomName ?? "?" }
        return byRoom.keys.sorted().map { (room: $0, cards: byRoom[$0] ?? []) }
    }
    var targetGroup: SonosGroup {
        manager.groups.first(where: { $0.coordinatorID == targetGroupID })
            ?? manager.groups.first
            ?? SonosGroup(id: targetGroupID, coordinatorID: targetGroupID, members: [])
    }

    var displayedCards: [QueueLibraryCard] {
        let needle = filterText.trimmingCharacters(in: .whitespaces)
        return cards.filter { card in
            matchesFilter(card) && (needle.isEmpty || card.name.localizedCaseInsensitiveContains(needle))
        }
    }

    private func matchesFilter(_ card: QueueLibraryCard) -> Bool {
        switch filter {
        case .all:      return true
        case .choragus: return card.isChoragus
        case .sonos:    if case .sonos = card.kind { return true }; return false
        case .smart:    if case .smart = card.kind { return true }; return false
        case .history:
            guard case .history = card.kind else { return false }
            if let rf = roomFilter, !rf.isEmpty { return roomMatches(card.roomName, rf) }
            return true
        case .folder(let fid): return card.folderIDs.contains(fid)
        }
    }

    func count(for filter: Filter) -> Int {
        switch filter {
        case .all:      return cards.count
        case .choragus: return cards.filter { $0.isChoragus }.count
        case .sonos:    return cards.filter { if case .sonos = $0.kind { return true }; return false }.count
        case .smart:    return cards.filter { if case .smart = $0.kind { return true }; return false }.count
        case .history:  return cards.filter { if case .history = $0.kind { return true }; return false }.count
        case .folder(let fid): return cards.filter { $0.folderIDs.contains(fid) }.count
        }
    }

    // MARK: Network-card cache (instant-on-open, background refresh)

    private struct CachedSonosCard: Codable {
        let objectID: String
        let name: String
        let coverURLs: [String]
    }
    private var sonosCacheURL: URL {
        AppPaths.appSupportDirectory.appendingPathComponent("queue_library_sonos.json")
    }
    private func loadSonosCache() -> [QueueLibraryCard] {
        guard let data = try? Data(contentsOf: sonosCacheURL),
              let cached = try? JSONDecoder().decode([CachedSonosCard].self, from: data) else { return [] }
        return cached.map {
            QueueLibraryCard(id: $0.objectID, name: $0.name, kind: .sonos($0.objectID),
                             trackCount: 0, folderIDs: [], coverURLs: $0.coverURLs)
        }
    }
    private func persistSonosCache(_ cards: [QueueLibraryCard]) {
        let entries: [CachedSonosCard] = cards.compactMap { card in
            guard case .sonos(let objectID) = card.kind else { return nil }
            return CachedSonosCard(objectID: objectID, name: card.name, coverURLs: card.coverURLs)
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: sonosCacheURL, options: .atomic)
        }
    }

    /// Local-only cards (smart / Choragus / history) — fast to rebuild, so
    /// they're never cached (avoids showing a deleted queue until refresh).
    private func buildLocalCards() -> [QueueLibraryCard] {
        var built: [QueueLibraryCard] = []
        for kind in SonosManager.SmartQueueKind.allCases {
            let count = manager.smartQueueTracks(kind: kind, room: roomFilter, limit: 500).count
            let name = roomFilter.map { "\(kind.title) · \($0)" } ?? kind.title
            built.append(QueueLibraryCard(id: "smart:\(kind.rawValue)", name: name, kind: .smart(kind),
                                          trackCount: count, folderIDs: [],
                                          coverURLs: manager.smartQueueCoverArt(kind: kind, room: roomFilter)))
        }
        for saved in manager.localSavedQueues() {
            built.append(QueueLibraryCard(id: "C:\(saved.id)", name: saved.name, kind: .choragus(saved.id),
                                          trackCount: saved.trackCount, folderIDs: saved.folderIDs,
                                          coverURLs: manager.choragusCoverArt(localID: saved.id)))
        }
        for entry in manager.allQueueSnapshots() {
            for snap in entry.snapshots {
                // Date and time on separate lines — the single-line form was
                // truncated to "… at 5:08…" in the tile and unreadable.
                let date = snap.savedAt.formatted(date: .abbreviated, time: .omitted)
                let time = snap.savedAt.formatted(date: .omitted, time: .shortened)
                let when = "\(date)\n\(time)"
                built.append(QueueLibraryCard(id: "hist:\(snap.localID)", name: when, kind: .history(snap.localID),
                                              trackCount: snap.trackCount, folderIDs: [], coverURLs: [], roomName: entry.room))
            }
        }
        return built
    }

    func load() async {
        // Instant: local cards + cached Sonos cards from disk.
        cards = buildLocalCards() + loadSonosCache()
        // Then refresh the network (Sonos) portion in the background.
        await refreshNetwork()
    }

    private func refreshNetwork() async {
        isLoading = true
        defer { isLoading = false }
        folders = manager.savedQueueFolders()

        // Rebuild local cards fresh, then browse Sonos live.
        var built = buildLocalCards()
        if let (items, _) = try? await manager.browse(objectID: BrowseID.playlists, start: 0, count: 200) {
            for item in items where item.isContainer
                && !QueueHistoryStore.isHistoryTitle(item.title) {
                // Seed Sonos covers from the cache so they don't flash blank.
                let cached = cards.first { $0.id == item.objectID }?.coverURLs ?? []
                built.append(QueueLibraryCard(
                    id: item.objectID, name: item.title, kind: .sonos(item.objectID),
                    trackCount: 0, folderIDs: [], coverURLs: cached))
            }
        }
        cards = built

        // Resolve covers (network) and update in place.
        for card in built {
            switch card.kind {
            case .sonos(let objectID):
                let art = await manager.savedQueueCoverArt(objectID: objectID)
                if let idx = cards.firstIndex(where: { $0.id == card.id }) { cards[idx].coverURLs = art }
            case .choragus(let id), .history(let id):
                let art = await manager.choragusCoverArtResolved(localID: id)
                if let idx = cards.firstIndex(where: { $0.id == card.id }) { cards[idx].coverURLs = art }
            case .smart:
                break
            }
        }
        // Persist the resolved Sonos cards for instant display next open.
        persistSonosCache(cards)
    }

    func tracks(for card: QueueLibraryCard) async -> [QueueItem] {
        let raw: [QueueItem]
        switch card.kind {
        case .choragus(let id), .history(let id):
            raw = manager.savedQueueTracks(localID: id)
        case .smart(let kind):
            raw = manager.smartQueueTracks(kind: kind, room: roomFilter)
        case .sonos(let objectID):
            guard let (items, _) = try? await manager.browse(objectID: objectID, start: 0, count: 500) else { return [] }
            raw = items.enumerated().map { offset, item in
                QueueItem(id: offset + 1, title: item.title, artist: item.artist,
                          album: item.album, albumArtURI: item.albumArtURI,
                          duration: "", uri: item.resourceURI, metadata: item.resourceMetadata)
            }
        }
        // Resolve local-library art (stored/parsed getaa URLs 404).
        return await manager.resolveLocalArt(in: raw)
    }

    func play(_ card: QueueLibraryCard, append: Bool) async {
        let group = targetGroup
        do {
            switch card.kind {
            case .choragus(let id): try await manager.loadLocalSavedQueue(id: id, group: group, append: append)
            case .sonos(let objectID): try await manager.playSavedQueueToRoom(objectID: objectID, group: group, append: append)
            case .smart(let kind): try await manager.playSmartQueue(kind: kind, room: roomFilter, group: group, append: append)
            case .history(let localID):
                // Replace = undo-aware restore (snapshots current first).
                if append {
                    try await manager.loadLocalSavedQueue(id: localID, group: group, append: true)
                } else {
                    try await manager.restoreQueueSnapshot(group: group, localID: localID)
                }
            }
            flash(append ? "Added \u{201C}\(card.name)\u{201D} to \(group.name)" : "Playing \u{201C}\(card.name)\u{201D} on \(group.name)")
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUELIB", userFacing: true)
        }
    }

    func clone(_ card: QueueLibraryCard) async {
        let cloneName = "\(card.name) copy"
        do {
            switch card.kind {
            case .choragus(let id): _ = manager.cloneLocalSavedQueue(id: id, name: cloneName)
            case .sonos(let objectID): _ = try await manager.cloneSonosPlaylistToChoragus(objectID: objectID, name: cloneName)
            case .history(let localID): _ = manager.cloneLocalSavedQueue(id: localID, name: cloneName)
            case .smart(let kind): _ = manager.freezeSmartQueueToChoragus(kind: kind, room: roomFilter, name: card.name)
            }
            await load()
            flash("Saved to Choragus as \u{201C}\(cloneName)\u{201D}")
        } catch {
            ErrorHandler.shared.handle(error, context: "QUEUELIB", userFacing: true)
        }
    }

    func rename(_ card: QueueLibraryCard, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        switch card.kind {
        case .choragus(let id): manager.renameLocalSavedQueue(id: id, to: trimmed)
        case .sonos(let objectID):
            Task { try? await manager.renamePlaylist(playlistID: objectID, oldTitle: card.name, newTitle: trimmed) }
        case .smart, .history: return
        }
        Task { await load() }
    }

    func delete(_ card: QueueLibraryCard) async {
        switch card.kind {
        case .choragus(let id): manager.deleteLocalSavedQueue(id: id)
        case .sonos(let objectID): try? await manager.deletePlaylist(playlistID: objectID)
        case .smart, .history: return
        }
        await load()
    }

    func move(_ card: QueueLibraryCard, toFolder folderID: Int64?) {
        guard let id = card.localID else { return }
        manager.moveSavedQueue(id: id, toFolder: folderID)
        Task { await load() }
    }

    /// Add or remove a single folder membership (many-to-many).
    func toggleFolderMembership(_ card: QueueLibraryCard, folder: Int64, add: Bool) {
        guard let id = card.localID else { return }
        if add { manager.addSavedQueueToFolder(id: id, folderID: folder) }
        else { manager.removeSavedQueueFromFolder(id: id, folderID: folder) }
        Task { await load() }
    }

    /// Replace all of a card's folder memberships.
    func setCardFolders(_ card: QueueLibraryCard, folderIDs: [Int64]) {
        guard let id = card.localID else { return }
        manager.setSavedQueueFolders(id: id, folderIDs: folderIDs)
        Task { await load() }
    }

    func createFolder(name: String, parent: Int64? = nil) {
        _ = manager.createSavedQueueFolder(name: name, parent: parent)
        Task { await load() }
    }
    func renameFolder(_ folder: SavedQueueFolder, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        manager.renameSavedQueueFolder(id: folder.id, to: trimmed)
        Task { await load() }
    }
    func copyFolder(_ folder: SavedQueueFolder) {
        _ = manager.copySavedQueueFolder(id: folder.id)
        flash("Duplicated \u{201C}\(folder.name)\u{201D}")
        Task { await load() }
    }
    func moveFolder(_ folderID: Int64, under parent: Int64?) {
        manager.moveSavedQueueFolder(id: folderID, under: parent)
        Task { await load() }
    }
    func deleteFolder(_ folder: SavedQueueFolder) {
        manager.deleteSavedQueueFolder(id: folder.id)
        if filter == .folder(folder.id) { filter = .all }
        Task { await load() }
    }

    func exportData(for card: QueueLibraryCard, asCSV: Bool) async -> String {
        SonosManager.exportTracks(await tracks(for: card), asCSV: asCSV)
    }

    /// Only Choragus-local queues are editable in place (the others are
    /// derived or live-on-the-speaker).
    func canEdit(_ card: QueueLibraryCard) -> Bool { card.isChoragus }

    func saveEditedTracks(_ tracks: [QueueItem], for card: QueueLibraryCard) {
        guard case .choragus(let id) = card.kind else { return }
        manager.replaceChoragusQueueTracks(id: id, tracks: tracks)
    }

    // MARK: Drag-to-copy / move

    /// True when `card` is a valid drop target (only Choragus-local queues can
    /// be edited in place; Sonos/smart/history are read-only).
    func isDropTarget(_ card: QueueLibraryCard) -> Bool { card.isChoragus }

    /// Handles a drop onto a queue card: a track copies in, another queue's
    /// tracks merge in. Returns false for invalid combinations.
    func handleDrop(_ payload: QueueDragPayload, onto target: QueueLibraryCard) -> Bool {
        guard case .choragus(let targetID) = target.kind else { return false }
        switch payload {
        case .track(_, let item):
            manager.appendTracksToChoragusQueue(id: targetID, tracks: [item])
            flash("Added \u{201C}\(item.title)\u{201D} to \(target.name)")
            return true
        case .card(let srcID):
            guard srcID != target.id, let src = cards.first(where: { $0.id == srcID }) else { return false }
            Task {
                let tracks = await self.tracks(for: src)
                self.manager.appendTracksToChoragusQueue(id: targetID, tracks: tracks)
                self.flash("Copied \u{201C}\(src.name)\u{201D} into \(target.name)")
                await self.load()
            }
            return true
        case .folder:
            return false   // a folder can't drop into a single queue
        }
    }

    /// Handles a queue card dropped onto a folder (or top level): moves the
    /// Choragus queue. Ignores track payloads.
    func handleDrop(_ payload: QueueDragPayload, ontoFolder folderID: Int64?) -> Bool {
        let dest = folderID.flatMap { fid in folders.first(where: { $0.id == fid })?.name } ?? "Top level"
        switch payload {
        case .card(let srcID):
            guard let src = cards.first(where: { $0.id == srcID }), src.isChoragus,
                  let id = src.localID else { return false }
            // Many-to-many: plain drag onto a folder ADDS membership (stays in
            // its other folders); ⌥Option drops an independent copy; dropping on
            // top level (nil) clears all memberships.
            if NSEvent.modifierFlags.contains(.option) {
                manager.copySavedQueue(id: id, toFolder: folderID)
                flash("Copied \u{201C}\(src.name)\u{201D} to \(dest)")
            } else if let folderID {
                manager.addSavedQueueToFolder(id: id, folderID: folderID)
                flash("Added \u{201C}\(src.name)\u{201D} to \(dest)")
            } else {
                manager.setSavedQueueFolders(id: id, folderIDs: [])
                flash("Moved \u{201C}\(src.name)\u{201D} to Top level")
            }
            Task { await load() }
            return true
        case .folder(let fid):
            guard fid != folderID else { return false }   // repo also guards cycles
            guard let f = folders.first(where: { $0.id == fid }) else { return false }
            manager.moveSavedQueueFolder(id: fid, under: folderID)
            flash("Moved \u{201C}\(f.name)\u{201D} to \(dest)")
            Task { await load() }
            return true
        case .track:
            return false
        }
    }

    /// Folders in tree order with depth, for the indented sidebar list.
    var folderTree: [(folder: SavedQueueFolder, depth: Int)] {
        var out: [(SavedQueueFolder, Int)] = []
        func walk(_ parent: Int64?, _ depth: Int) {
            for f in folders.filter({ $0.parentID == parent })
                .sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                out.append((f, depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    private func flash(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusMessage == message { statusMessage = nil }
        }
    }
}

// MARK: - Window

enum QueueLibraryViewMode: String { case icon, table }

struct QueueLibraryWindow: View {
    @StateObject private var vm: QueueLibraryViewModel
    @State private var selected: QueueLibraryCard?
    @State private var renaming: QueueLibraryCard?
    @State private var renamingFolder: SavedQueueFolder?
    @State private var renameText = ""
    @State private var newFolderText = ""
    @State private var showNewFolder = false
    @State private var newFolderParent: Int64?
    @State private var tableSelection: QueueLibraryCard.ID?
    /// Drop-target highlight: the folder (or top-level row) a queue is hovering
    /// over mid-drag. `dropTargetFolder == someID` highlights that folder.
    @State private var dropTargetFolder: Int64?
    @State private var dropTargetTopLevel = false
    /// Window-level layout toggle; defaults to the artwork grid.
    @AppStorage("choragus.queueLibraryView") private var viewModeRaw = QueueLibraryViewMode.icon.rawValue
    private var viewMode: QueueLibraryViewMode { QueueLibraryViewMode(rawValue: viewModeRaw) ?? .icon }

    init(manager: SonosManager, group: SonosGroup) {
        _vm = StateObject(wrappedValue: QueueLibraryViewModel(manager: manager, group: group))
    }

    private let columns = [GridItem(.adaptive(minimum: 172, maximum: 220), spacing: 20)]

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // Non-modal: the open queue lives in a side inspector beside the
            // grid, so tracks can be dragged out of it onto other queues.
            if let card = selected {
                HSplitView {
                    grid
                    QueueLibraryDetail(vm: vm, card: card, onClose: { selected = nil })
                        .id(card.id)   // fresh state + reload when a different queue is selected
                        .frame(minWidth: 380, idealWidth: 440, maxWidth: 620)
                }
            } else {
                grid
            }
        }
        .task { await vm.load() }
        .alert(L10n.rename, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L10n.name, text: $renameText)
            Button(L10n.cancel, role: .cancel) { renaming = nil }
            Button(L10n.save) { if let c = renaming { vm.rename(c, to: renameText) }; renaming = nil }
        }
        .alert(L10n.renameFolder, isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField(L10n.folderName, text: $renameText)
            Button(L10n.cancel, role: .cancel) { renamingFolder = nil }
            Button(L10n.save) { if let f = renamingFolder { vm.renameFolder(f, to: renameText) }; renamingFolder = nil }
        }
        .alert(newFolderParent == nil ? L10n.newFolder : L10n.newSubfolder, isPresented: $showNewFolder) {
            TextField(L10n.folderName, text: $newFolderText)
            Button(L10n.cancel, role: .cancel) { newFolderText = ""; newFolderParent = nil }
            Button(L10n.save) {
                if !newFolderText.trimmingCharacters(in: .whitespaces).isEmpty {
                    vm.createFolder(name: newFolderText, parent: newFolderParent)
                }
                newFolderText = ""; newFolderParent = nil
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List {
            Section {
                row(.all, L10n.allSources, "square.grid.2x2", .secondary)
                row(.smart, "Smart", "sparkles", .orange)
                // Dropping a queue here moves it out to top level.
                plainRow(.choragus, "Choragus", "internaldrive.fill", .accentColor, dropActive: dropTargetTopLevel)
                    .dropDestination(for: QueueDragPayload.self) { payloads, _ in
                        payloads.contains { vm.handleDrop($0, ontoFolder: nil) }
                    } isTargeted: { dropTargetTopLevel = $0 }
                row(.sonos, "Sonos", "hifispeaker.2.fill", .teal)
                row(.history, "History", "clock.arrow.circlepath", .purple)
            }
            Section {
                ForEach(vm.folderTree, id: \.folder.id) { entry in
                    folderRow(entry.folder, depth: entry.depth)
                }
                Button {
                    newFolderParent = nil; showNewFolder = true
                } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                Text(L10n.folders)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
    }

    /// A folder row, indented by nesting depth, draggable (to re-nest) and a
    /// drop target for queues and other folders.
    private func folderRow(_ folder: SavedQueueFolder, depth: Int) -> some View {
        plainRow(.folder(folder.id), folder.name, "folder.fill", .yellow, leading: CGFloat(depth) * 14,
                 dropActive: dropTargetFolder == folder.id)
            .contextMenu {
                Button(L10n.rename) { renameText = folder.name; renamingFolder = folder }
                Button(L10n.duplicate) { vm.copyFolder(folder) }
                Button(L10n.newSubfolder) { newFolderParent = folder.id; showNewFolder = true }
                Menu(L10n.moveToMenu) {
                    Button(L10n.topLevel) { vm.moveFolder(folder.id, under: nil) }
                    ForEach(vm.folders.filter { $0.id != folder.id }) { dest in
                        Button(dest.name) { vm.moveFolder(folder.id, under: dest.id) }
                    }
                }
                Divider()
                Button(L10n.delete, role: .destructive) { vm.deleteFolder(folder) }
            }
            .draggable(QueueDragPayload.folder(folderID: folder.id)) {
                dragChip(icon: "folder.fill", tint: .yellow, text: folder.name)
            }
            .dropDestination(for: QueueDragPayload.self) { payloads, _ in
                payloads.contains { vm.handleDrop($0, ontoFolder: folder.id) }
            } isTargeted: { over in
                dropTargetFolder = over ? folder.id : (dropTargetFolder == folder.id ? nil : dropTargetFolder)
            }
    }

    private func row(_ f: QueueLibraryViewModel.Filter, _ label: String, _ icon: String, _ tint: Color) -> some View {
        Button { vm.filter = f } label: {
            HStack {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
                Text(label).lineLimit(1)
                Spacer()
                Text("\(vm.count(for: f))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(vm.filter == f ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// Row variant WITHOUT a Button for the drop-target rows (Choragus top
    /// level and folders). A `Button` swallows drag-hover events, so
    /// `.dropDestination` on a List row inside one never fires — a plain
    /// tappable HStack receives the drop.
    private func plainRow(_ f: QueueLibraryViewModel.Filter, _ label: String, _ icon: String, _ tint: Color, leading: CGFloat = 0, dropActive: Bool = false) -> some View {
        // ONE listRowBackground covering both drop-hover and selection. Two
        // separate `.listRowBackground` modifiers conflict (the inner wins), so
        // the drop tint never showed — fold both into a single value.
        let bg: Color = dropActive ? Color.accentColor.opacity(0.32)
            : (vm.filter == f ? Color.accentColor.opacity(0.18) : Color.clear)
        return HStack {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            Text(label).lineLimit(1)
            Spacer()
            Text("\(vm.count(for: f))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.leading, leading)
        .contentShape(Rectangle())
        .onTapGesture { vm.filter = f }
        .listRowBackground(bg)
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.filterQueuePlaceholder, text: $vm.filterText).textFieldStyle(.plain)
                if vm.isLoading { ProgressView().controlSize(.small) }
                // Room filter only applies to Smart queues (they're the only
                // room-scoped source), so it's shown only on that view. The
                // playback target room is chosen in the detail sheet, not here.
                if (vm.filter == .smart || vm.filter == .history), !vm.roomOptions.isEmpty {
                    Picker("", selection: $vm.roomFilter) {
                        Text(L10n.allRooms).tag(String?.none)
                        ForEach(vm.roomOptions, id: \.self) { room in
                            Text(room).tag(String?.some(room))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                    .help(L10n.filterByRoomLabel)
                    .onChange(of: vm.roomFilter) { Task { await vm.load() } }
                }
                Picker("", selection: $viewModeRaw) {
                    Image(systemName: "square.grid.2x2").tag(QueueLibraryViewMode.icon.rawValue)
                    Image(systemName: "list.bullet").tag(QueueLibraryViewMode.table.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 80)
                .help(L10n.iconOrTableView)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if vm.displayedCards.isEmpty && !vm.isLoading {
                Spacer(); Text(L10n.emptyQueueLibrary).foregroundStyle(.secondary); Spacer()
            } else if viewMode == .table {
                tableView
            } else if vm.filter == .history {
                // Grouped by room with section headers.
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22, pinnedViews: [.sectionHeaders]) {
                        ForEach(vm.historyGroups, id: \.room) { group in
                            Section {
                                ForEach(group.cards) { card in
                                    tile(card)
                                }
                            } header: {
                                HStack {
                                    Text(group.room).font(.title3.weight(.heavy))
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial)
                            }
                        }
                    }
                    .padding(20)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(vm.displayedCards) { card in
                            tile(card)
                        }
                    }
                    .padding(20)
                }
            }

            if let msg = vm.statusMessage {
                Divider()
                Text(msg).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    /// Grid tile with tap-to-open, context menu, and drag/drop wiring: a tile
    /// can be dragged (as a whole queue) and is a drop target for a track or
    /// another queue when it's a Choragus-local queue.
    @ViewBuilder
    private func tile(_ card: QueueLibraryCard) -> some View {
        QueueLibraryTile(card: card)
            .onTapGesture { selected = card }
            .contextMenu { cardMenu(card) }
            .draggable(QueueDragPayload.card(cardID: card.id)) {
                dragChip(icon: card.kind.badgeIcon, tint: card.kind.badgeColor,
                         text: card.name.replacingOccurrences(of: "\n", with: " "))
            }
            .dropDestination(for: QueueDragPayload.self) { payloads, _ in
                payloads.contains { vm.handleDrop($0, onto: card) }
            }
    }

    /// Small drag image so the pointer and drop target stay visible (the
    /// default full-tile snapshot covered the cursor).
    private func dragChip(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: 220)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: Table view (flat list of queues; single-click opens the detail)

    private var tableView: some View {
        Table(vm.displayedCards, selection: $tableSelection) {
            TableColumn(L10n.name) { card in
                HStack(spacing: 8) {
                    // Mixed-album mosaic, thumbnail size.
                    MosaicCover(urls: card.coverURLs)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Image(systemName: card.kind.badgeIcon)
                        .foregroundStyle(card.kind.badgeColor).font(.caption2)
                    // History names carry a newline (date / time); flatten to
                    // one line for the table cell.
                    Text(card.name.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
                }
                .draggable(QueueDragPayload.card(cardID: card.id)) {
                    dragChip(icon: card.kind.badgeIcon, tint: card.kind.badgeColor,
                             text: card.name.replacingOccurrences(of: "\n", with: " "))
                }
            }
            TableColumn(L10n.sourceLabel) { card in
                Text(card.kind.sourceLabel).foregroundStyle(.secondary)
            }.width(90)
            TableColumn(L10n.roomLabel) { card in
                Text(card.roomName ?? "").foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn(L10n.tracks) { card in
                Text(card.trackCount > 0 ? "\(card.trackCount)" : "—")
                    .foregroundStyle(.secondary).monospacedDigit()
            }.width(60)
        }
        .contextMenu(forSelectionType: QueueLibraryCard.ID.self) { ids in
            if let id = ids.first, let card = vm.displayedCards.first(where: { $0.id == id }) {
                cardMenu(card)
            }
        }
        .onChange(of: tableSelection) {
            guard let id = tableSelection,
                  let card = vm.displayedCards.first(where: { $0.id == id }) else { return }
            selected = card
            tableSelection = nil
        }
    }

    @ViewBuilder
    private func cardMenu(_ card: QueueLibraryCard) -> some View {
        Button(L10n.queueReplace) { Task { await vm.play(card, append: false) } }
        Button(L10n.queueAppend) { Task { await vm.play(card, append: true) } }
        Divider()
        Button(L10n.cloneToChoragus) { Task { await vm.clone(card) } }
        if card.isChoragus {
            Button(L10n.rename) { renameText = card.name; renaming = card }
            // Many-to-many: toggle membership in any folder (checkmark = in it).
            Menu(L10n.folders) {
                ForEach(vm.folders) { folder in
                    let inFolder = card.folderIDs.contains(folder.id)
                    Button {
                        vm.toggleFolderMembership(card, folder: folder.id, add: !inFolder)
                    } label: {
                        Label(folder.name, systemImage: inFolder ? "checkmark" : "")
                    }
                }
                Divider()
                Button(L10n.removeFromAllFolders) { vm.setCardFolders(card, folderIDs: []) }
            }
            // Quick remove when viewing a single folder.
            if case .folder(let fid) = vm.filter, card.folderIDs.contains(fid) {
                Button(L10n.removeFromThisFolder) { vm.toggleFolderMembership(card, folder: fid, add: false) }
            }
        }
        if case .sonos = card.kind {
            Button(L10n.rename) { renameText = card.name; renaming = card }
        }
        // Delete only the user-owned saved queues; Smart and History are
        // derived/auto-managed.
        if card.isChoragus || { if case .sonos = card.kind { return true }; return false }() {
            Divider()
            Button(L10n.delete, role: .destructive) { Task { await vm.delete(card) } }
        }
    }
}

// MARK: - Add to Choragus Queue (reusable context-menu item)

/// Submenu for adding an album/track to a Choragus-local saved queue from any
/// context menu. Lists existing queues plus "New Queue". Pass the manager
/// explicitly — SwiftUI context menus don't reliably inherit the environment.
struct AddToChoragusQueueMenu: View {
    let item: BrowseItem
    let manager: SonosManager

    var body: some View {
        Menu {
            Button(L10n.newQueueEllipsis) {
                let name = item.title.isEmpty ? "New Queue" : item.title
                Task { _ = await manager.createChoragusQueue(item: item, name: name) }
            }
            let queues = manager.localSavedQueues()
            if !queues.isEmpty {
                Divider()
                ForEach(queues) { q in
                    Button(q.name) { Task { _ = await manager.addToChoragusQueue(item: item, queueID: q.id) } }
                }
            }
        } label: {
            Label("Add to Choragus Queue", systemImage: "internaldrive.fill")
        }
    }
}

// MARK: - Tile (Zune-styled: bold type, content over chrome)

struct QueueLibraryTile: View {
    let card: QueueLibraryCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MosaicCover(urls: card.coverURLs)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: card.kind.badgeIcon)
                        .font(.caption2.weight(.bold))
                        .padding(5)
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundStyle(card.kind.badgeColor)
                        .padding(6)
                }
            // Zune: bold, oversized, content-forward name. Two lines so the
            // history cards' date / time both show (was truncated at one line).
            Text(card.name)
                .font(.system(size: 16, weight: .heavy))
                .lineLimit(2)
                .truncationMode(.tail)
            Text(card.trackCount > 0 ? "\(card.kind.sourceLabel.uppercased()) · \(card.trackCount)" : card.kind.sourceLabel.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Mosaic built from up to four DISTINCT-album art URLs. Layout adapts to the
/// count so same-album queues never show a repeated tile: 1 fills, 2 split,
/// 3 is one tall + two stacked, 4 is a 2×2 grid. Image bytes are memory/disk
/// cached by `CachedAsyncImage`; a miss fetches and caches.
struct MosaicCover: View {
    let urls: [String]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            switch min(urls.count, 4) {
            case 0:
                placeholder
            case 1:
                cell(urls[0], w, h)
            case 2:
                HStack(spacing: 1) { cell(urls[0], w/2, h); cell(urls[1], w/2, h) }
            case 3:
                HStack(spacing: 1) {
                    cell(urls[0], w/2, h)
                    VStack(spacing: 1) { cell(urls[1], w/2, h/2); cell(urls[2], w/2, h/2) }
                }
            default:
                VStack(spacing: 1) {
                    HStack(spacing: 1) { cell(urls[0], w/2, h/2); cell(urls[1], w/2, h/2) }
                    HStack(spacing: 1) { cell(urls[2], w/2, h/2); cell(urls[3], w/2, h/2) }
                }
            }
        }
    }

    private func cell(_ url: String, _ w: CGFloat, _ h: CGFloat) -> some View {
        CachedAsyncImage(url: URL(string: url), cornerRadius: 0, priority: .interactive)
            .frame(width: w, height: h)
            .clipped()
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.15))
            Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.secondary)
        }
    }
}

/// Ambient hero artwork that crossfades between a queue's track covers in
/// random order. No data is faked — each frame is a real cover of a track in
/// this queue. Stops when it leaves the screen.
struct RandomArtworkView: View {
    let urls: [String]
    @State private var index = 0

    var body: some View {
        ZStack {
            if urls.indices.contains(index) {
                CachedAsyncImage(url: URL(string: urls[index]), cornerRadius: 0, priority: .interactive)
                    .id(index)
                    .transition(.opacity)
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .animation(.easeInOut(duration: 1.2), value: index)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "play.circle.fill")
                .font(.caption2).padding(4)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white).padding(5)
        }
        .task(id: urls) {
            guard urls.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if Task.isCancelled { break }
                var next = index
                while next == index { next = Int.random(in: 0..<urls.count) }
                index = next
            }
        }
    }
}

// MARK: - Detail sheet (Zune watermark header + room picker + export)

enum QueueDetailViewMode: String { case list, table }

struct QueueLibraryDetail: View {
    @ObservedObject var vm: QueueLibraryViewModel
    let card: QueueLibraryCard
    /// Inline (non-modal) close — clears the window's selection.
    var onClose: () -> Void = {}
    @State private var tracks: [QueueItem] = []
    @State private var loading = true
    @State private var animateArt = false
    @AppStorage("choragus.queueDetailView") private var viewModeRaw = QueueDetailViewMode.list.rawValue

    private var viewMode: QueueDetailViewMode { QueueDetailViewMode(rawValue: viewModeRaw) ?? .list }
    private var editable: Bool { vm.canEdit(card) }

    /// Distinct per-track artwork for the random hero animation; falls back to
    /// the card's mosaic covers if no per-track art resolved.
    private var animationURLs: [String] {
        var seen = Set<String>(); var out: [String] = []
        for t in tracks {
            if let a = t.albumArtURI, !a.isEmpty, seen.insert(a).inserted { out.append(a) }
        }
        return out.isEmpty ? card.coverURLs : out
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                Spacer(); ProgressView(); Spacer()
            } else if tracks.isEmpty {
                Spacer(); Text(L10n.queueIsEmpty).foregroundStyle(.secondary); Spacer()
            } else if viewMode == .table {
                tableView
            } else {
                listView
            }
        }
        .task { tracks = await vm.tracks(for: card); loading = false }
        .onReceive(NotificationCenter.default.publisher(for: .choragusSavedQueuesChanged)) { _ in
            // A copy/merge landed in this (or another) queue — reload so the
            // open panel reflects the appended tracks.
            Task { tracks = await vm.tracks(for: card) }
        }
    }

    // MARK: Artwork list (drag-reorder + context menu when editable)

    private var listView: some View {
        List {
            ForEach(tracks) { track in
                HStack(spacing: 10) {
                    CachedAsyncImage(url: track.albumArtURI.flatMap { URL(string: $0) },
                                     cornerRadius: 4, priority: .interactive)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.body.weight(.medium)).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(ServiceName.resolve(uri: track.uri))
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).lineLimit(1)
                }
                .contentShape(Rectangle())
                .draggable(QueueDragPayload.track(cardID: card.id, item: track)) {
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                        Text(track.title).lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: 220)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .contextMenu { if editable { rowMenu(track) } }
            }
            .onMove(perform: editable ? move : nil)
            .onDelete(perform: editable ? delete : nil)
        }
        .listStyle(.inset)
    }

    // MARK: Classic table

    private var tableView: some View {
        Table(tracks) {
            TableColumn("#") { t in Text("\(rowIndex(t) + 1)").foregroundStyle(.secondary) }.width(36)
            TableColumn(L10n.titleFieldLabel) { t in Text(t.title).lineLimit(1) }
            TableColumn(L10n.artistLabel) { t in Text(t.artist).foregroundStyle(.secondary).lineLimit(1) }
            TableColumn(L10n.albumLabel) { t in Text(t.album).foregroundStyle(.secondary).lineLimit(1) }
            TableColumn(L10n.sourceLabel) { t in Text(ServiceName.resolve(uri: t.uri)).foregroundStyle(.tertiary).lineLimit(1) }
            TableColumn("") { t in
                if editable { Menu { rowMenu(t) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize() }
            }.width(34)
        }
    }

    // MARK: Edit operations (Choragus-local only)

    private func rowIndex(_ track: QueueItem) -> Int { tracks.firstIndex { $0.id == track.id } ?? 0 }

    @ViewBuilder
    private func rowMenu(_ track: QueueItem) -> some View {
        Button(L10n.moveToTop) { moveTo(track, 0) }
        Button(L10n.moveUp) { moveTo(track, rowIndex(track) - 1) }
        Button(L10n.moveDown) { moveTo(track, rowIndex(track) + 1) }
        Button(L10n.moveToBottom) { moveTo(track, tracks.count - 1) }
        Divider()
        Button(L10n.removeFromQueue, role: .destructive) {
            tracks.removeAll { $0.id == track.id }; persist()
        }
    }

    private func moveTo(_ track: QueueItem, _ dest: Int) {
        guard let from = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let clamped = max(0, min(dest, tracks.count - 1))
        guard clamped != from else { return }
        let item = tracks.remove(at: from)
        tracks.insert(item, at: clamped)
        persist()
    }

    private func move(from: IndexSet, to: Int) { tracks.move(fromOffsets: from, toOffset: to); persist() }
    private func delete(at offsets: IndexSet) { tracks.remove(atOffsets: offsets); persist() }
    private func persist() { vm.saveEditedTracks(tracks, for: card) }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if animateArt {
                    RandomArtworkView(urls: animationURLs)
                } else {
                    MosaicCover(urls: card.coverURLs)
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture { animateArt.toggle() }
            .help(L10n.tapToAnimateArtwork)
            VStack(alignment: .leading, spacing: 8) {
                // Zune: heavy oversized title as the hero element.
                Text(card.name)
                    .font(.system(size: 30, weight: .heavy))
                    .lineLimit(2).minimumScaleFactor(0.6)
                Label(card.kind.sourceLabel.uppercased(), systemImage: card.kind.badgeIcon)
                    .font(.caption2.weight(.bold)).tracking(0.5)
                    .foregroundStyle(card.kind.badgeColor)
                HStack(spacing: 8) {
                    Text(L10n.roomLabel).font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $vm.targetGroupID) {
                        ForEach(vm.groups, id: \.coordinatorID) { g in Text(g.name).tag(g.coordinatorID) }
                    }
                    .labelsHidden().frame(maxWidth: 160)
                }
                HStack(spacing: 8) {
                    Button { Task { await vm.play(card, append: false); onClose() } } label: {
                        Label(L10n.queueReplace, systemImage: "play.fill")
                    }
                    Button { Task { await vm.play(card, append: true) } } label: {
                        Label(L10n.queueAppend, systemImage: "text.append")
                    }
                    Button { Task { await vm.clone(card) } } label: {
                        Label(L10n.cloneToChoragus, systemImage: "doc.on.doc")
                    }
                    Button { animateArt.toggle() } label: {
                        Image(systemName: animateArt ? "pause.circle.fill" : "play.circle")
                    }
                    .tint(animateArt ? .accentColor : .primary)
                    .help(L10n.animateArtworkRandomly)
                    Menu {
                        Button(L10n.exportM3U) { exportFile(asCSV: false) }
                        Button(L10n.exportCSV) { exportFile(asCSV: true) }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .frame(width: 40)
                    Picker("", selection: $viewModeRaw) {
                        Image(systemName: "list.bullet").tag(QueueDetailViewMode.list.rawValue)
                        Image(systemName: "tablecells").tag(QueueDetailViewMode.table.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 80)
                    .help(L10n.listOrTableView)
                }
                .controlSize(.small)
                .padding(.top, 2)
                if editable {
                    Text(L10n.dragToReorderQueueHint)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .padding(18)
    }

    private func exportFile(asCSV: Bool) {
        Task {
            let data = await vm.exportData(for: card, asCSV: asCSV)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = card.name + (asCSV ? ".csv" : ".m3u")
            if panel.runModal() == .OK, let url = panel.url {
                try? data.data(using: .utf8)?.write(to: url)
            }
        }
    }
}

/// PlaylistBuilderView.swift — "Build Playlist" window (Choragus
/// Sources). Top-to-bottom flow matches the order of work:
///
///   1. Describe the playlist (AI provider + brief) or paste a list.
///   2. Songs land in a table as they stream in; resolving fills each
///      row with per-row status and artwork as lookups complete.
///   3. Pick the service to match on, name it, Build.
///
/// Non-modal (see `WindowManager.openPlaylistBuilder`); generation and
/// resolution keep running while the rest of the app is used.
import SwiftUI
import SonosKit

// MARK: - Row model

struct PlaylistBuilderRow: Identifiable, Equatable {
    enum Status: Equatable {
        case pending          // listed, not yet looked up
        case searching        // lookup in flight
        case resolved         // matched; artURL/resolvedTitle populated
        case missing          // no artist-matching result
    }

    let id = UUID()
    var spec: SongSpec
    var status: Status = .pending
    var artURL: String?
    var resolvedTitle: String?
    var resolvedArtist: String?
    /// The matched track, kept per row so a later delivery sends
    /// exactly the rows still listed — removing a row after Build
    /// drops its track without a re-resolve.
    var resolvedItem: QueueItem?
}

// MARK: - View model

@MainActor @Observable
final class PlaylistBuilderViewModel {
    var rows: [PlaylistBuilderRow] = []
    var name = ""
    /// Playlist names are library card titles — long ones truncate there.
    static let maxNameLength = 60
    var aiBrief = ""
    var isGenerating = false
    var isRunning = false
    var progressDone = 0
    var progressTotal = 0
    var savedMessage: String?
    var generateError: String?
    /// Raw reply text of the last completed generation, for the "AI
    /// response" viewer.
    var lastRawResponse: String?
    /// A sample brief shown as the field's placeholder, drawn once per
    /// view model, so each opening of the window shows a different one.
    let samplePrompt = L10n.playlistSamplePrompts.randomElement() ?? ""
    /// Transient confirmation after Copy prompt.
    var promptCopied = false
    /// Set when a SMAPI service was selected but its credentials were
    /// gone at Build, so matching silently used Apple Music.
    var serviceFellBack = false
    private var task: Task<Void, Never>?
    /// Run identity: bumped by every generate/build/cancel. Task
    /// closures compare their captured value before mutating state, so
    /// a cancelled run cannot overwrite the run that replaced it.
    private var runID = 0

    /// Where the resolved tracks go on Build.
    enum BuildDestination: Hashable {
        case savePlaylist
        case queueEnd
        case playNext
        case playNow
    }
    var destination: BuildDestination = .savePlaylist
    /// Folder the saved playlist lands in; nil = top level.
    var folderID: Int64?
    /// Room or group a queue delivery goes to; nil = the room selected in
    /// the main window. The picker lists the current groups.
    var targetGroupID: String?
    /// What the last delivery did, so the follow-up (the Playlist Manager
    /// link after a save) matches it rather than trailing every send.
    var deliveredDestination: BuildDestination?

    /// Matching-catalog choices offered by the service picker.
    enum ServiceChoice: Hashable {
        case appleMusic
        case smapi(Int)
        case localLibrary
        case mediaServer(String)   // MediaServer.id
    }
    var serviceChoice: ServiceChoice = .appleMusic
    /// The service the current rows were matched against. Build is
    /// idle while this equals `serviceChoice` and every row has an
    /// outcome — there is nothing new to look up.
    private(set) var resolvedService: ServiceChoice?

    // MARK: AI provider settings — READ-ONLY here; Settings → AI owns
    // every write (provider, models, endpoint, key).

    /// Manual mode: the user copies the prompt into an external AI and
    /// pastes its reply back — no key, no in-app request. Forced on
    /// when the AI source is not usable (disabled, or no stored key).
    var useManual = false

    /// Configured services in menu order (Settings → AI).
    var profiles: [AIServiceProfile] {
        _ = settingsRevision
        return AIServiceProfileStore.load()
    }

    var selectedProfile: AIServiceProfile? {
        _ = settingsRevision
        return AIServiceProfileStore.selected()
    }

    func selectProfile(_ id: UUID) {
        AIServiceProfileStore.selectedID = id
        refreshSettings()
    }
    /// Observation ticket for the UserDefaults-backed settings reads —
    /// computed properties are invisible to @Observable, so writes bump
    /// this stored counter to re-render the window.
    private(set) var settingsRevision = 0

    /// A service that can be called: keyed, or a custom endpoint
    /// (those may run keyless).
    func isUsable(_ profile: AIServiceProfile) -> Bool {
        profile.provider == .custom
            || !(SecretsStore.shared.get(profile.apiKeySecretName) ?? "").isEmpty
    }

    var usableProfiles: [AIServiceProfile] { profiles.filter(isUsable) }

    var hasUsableAI: Bool { selectedProfile.map(isUsable) ?? false }

    var isVerified: Bool { selectedProfile?.verified ?? false }

    /// Re-evaluates the UserDefaults/keychain-backed settings reads
    /// (they are invisible to Observation) — called when the window
    /// regains focus after a trip to Settings.
    func refreshSettings() {
        settingsRevision &+= 1
    }

    /// Every listed row has been looked up against the selected service.
    var isResolutionCurrent: Bool {
        guard !rows.isEmpty, resolvedService == serviceChoice else { return false }
        return rows.allSatisfy { $0.status == .resolved || $0.status == .missing }
    }

    /// Build looks the rows up; it has nothing to do once the list is
    /// resolved against the selected service.
    var canBuild: Bool {
        !isRunning && !isGenerating && !rows.isEmpty && !isResolutionCurrent
    }

    /// Matched tracks in row order — what a delivery sends.
    var resolvedTracks: [QueueItem] { rows.compactMap(\.resolvedItem) }

    var canDeliver: Bool {
        guard !isRunning, !isGenerating, !resolvedTracks.isEmpty else { return false }
        // Only the saved-playlist destination needs a name.
        if destination == .savePlaylist {
            return !name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var resolvedCount: Int { rows.filter { $0.status == .resolved }.count }
    var missingCount: Int { rows.filter { $0.status == .missing }.count }

    // MARK: Generation

    func generate(catalogHint: String?) {
        let brief = aiBrief.trimmingCharacters(in: .whitespaces)
        guard !brief.isEmpty, !isGenerating, !isRunning else { return }
        guard let config = SongListAIConfig.stored() else {
            generateError = L10n.aiNoServiceSelected
            return
        }
        isGenerating = true
        generateError = nil
        savedMessage = nil
        rows = []
        runID &+= 1
        let myRun = runID
        lastRawResponse = nil
        task = Task { [weak self] in
            do {
                let (specs, raw) = try await SongListAIService.generateWithRaw(brief: brief, config: config,
                                                                               catalogHint: catalogHint) { partial in
                    await MainActor.run {
                        guard let self, self.runID == myRun else { return }
                        self.streamIn(partial)
                    }
                }
                guard let self, self.runID == myRun else { return }
                self.lastRawResponse = raw
                self.streamIn(specs)
                if self.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.name = String(brief.prefix(60))
                }
            } catch {
                if let self, self.runID == myRun, !Task.isCancelled {
                    self.generateError = error.localizedDescription
                }
            }
            if let self, self.runID == myRun { self.isGenerating = false }
        }
    }

    /// Extends/updates `rows` from a streamed prefix without resetting
    /// the rows already shown (keeps the table stable as it grows).
    private func streamIn(_ specs: [SongSpec]) {
        if specs.count >= rows.count {
            for (index, spec) in specs.enumerated() {
                if index < rows.count {
                    if rows[index].spec != spec { rows[index].spec = spec }
                } else {
                    rows.append(PlaylistBuilderRow(spec: spec))
                }
            }
        } else {
            rows = specs.map { PlaylistBuilderRow(spec: $0) }
        }
    }

    func copyPromptTemplate(catalogHint: String?) {
        let template = SongListAIService.externalPromptTemplate(
            brief: aiBrief.trimmingCharacters(in: .whitespaces), catalogHint: catalogHint)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(template, forType: .string)
        promptCopied = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.promptCopied = false
        }
    }

    func pasteList() {
        guard !isGenerating, !isRunning else { return }
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        let specs = SongSpec.parseList(text)
        guard !specs.isEmpty else {
            generateError = L10n.playlistBuilderClipboardEmpty
            return
        }
        savedMessage = nil
        generateError = nil
        rows = specs.map { PlaylistBuilderRow(spec: $0) }
    }

    func removeRow(_ id: UUID) {
        // Deletes during generation would be resurrected by the next
        // streamed prefix (streamIn rewrites by index); during a build
        // they would shift the done-index mapping.
        guard !isRunning, !isGenerating else { return }
        rows.removeAll { $0.id == id }
    }

    // MARK: Build

    /// Resolves the picker selection to a resolver service. SMAPI
    /// selection falls back to Apple Music when its credentials are
    /// gone (token expired between opening the window and pressing
    /// Build) — mirrors `serviceCredentials()` in BrowseView.
    private func resolveService(sonosManager: SonosManager,
                                smapiManager: SMAPIAuthManager) -> (PlaylistResolveService, fellBack: Bool) {
        func apple(fellBack: Bool) -> (PlaylistResolveService, Bool) {
            let sid = MusicServiceCatalog.shared.sid(forName: ServiceName.appleMusic) ?? ServiceID.appleMusic
            return (.appleMusic(sn: smapiManager.serialNumber(for: sid)), fellBack)
        }
        switch serviceChoice {
        case .appleMusic:
            return apple(fellBack: false)
        case .smapi(let sid):
            if let token = smapiManager.tokenStore.getToken(for: sid),
               let svc = smapiManager.availableServices.first(where: { $0.id == sid }) {
                return (.smapi(serviceID: sid, serviceURI: svc.secureUri,
                               token: token, sn: smapiManager.serialNumber(for: sid)), false)
            }
            return apple(fellBack: true)
        case .localLibrary:
            return (.localLibrary(search: { [weak sonosManager] term in
                (try? await sonosManager?.search(query: term, householdID: nil, count: 15))?.items ?? []
            }), false)
        case .mediaServer(let serverID):
            guard let server = sonosManager.mediaServers.first(where: { $0.id == serverID }) else {
                return apple(fellBack: true)
            }
            return (.mediaServer(search: { term in
                await MediaServerService.search(server: server, term: term)
            }), false)
        }
    }

    /// Looks every row up against the selected service. Delivery is a
    /// separate step (`deliver(via:)`) so the same resolution can be
    /// saved, queued, or played without re-resolving.
    func build(sonosManager: SonosManager, smapiManager: SMAPIAuthManager) {
        guard canBuild else { return }
        let (service, fellBack) = resolveService(sonosManager: sonosManager, smapiManager: smapiManager)
        serviceFellBack = fellBack
        resolvedService = serviceChoice
        let specs = rows.map(\.spec)

        isRunning = true
        savedMessage = nil
        generateError = nil
        progressDone = 0
        progressTotal = specs.count
        for index in rows.indices {
            rows[index].status = .pending
            rows[index].artURL = nil
            rows[index].resolvedTitle = nil
            rows[index].resolvedArtist = nil
            rows[index].resolvedItem = nil
        }
        if let first = rows.indices.first { rows[first].status = .searching }
        runID &+= 1
        let myRun = runID

        task = Task { [weak self, weak sonosManager] in
            let result = await PlaylistResolver.resolve(specs, via: service,
                                                        pacing: service.defaultPacing) { done, _, _, item in
                await MainActor.run {
                    guard let self, self.runID == myRun else { return }
                    self.recordResolution(done: done, item: item)
                }
            }
            guard let self, self.runID == myRun else { return }
            guard !Task.isCancelled else {
                self.isRunning = false
                return
            }
            if result.resolved.isEmpty {
                self.generateError = L10n.playlistBuilderNothingMatched
            }
            self.isRunning = false
        }
    }

    /// Sends the resolved rows to the chosen destination.
    func deliver(via sonosManager: SonosManager) {
        guard canDeliver else { return }
        let tracks = resolvedTracks
        // isRunning holds through delivery — the SOAP adds take
        // seconds, and a second click mid-delivery would start a run
        // whose state the first one then overwrites.
        isRunning = true
        savedMessage = nil
        deliveredDestination = nil
        generateError = nil
        runID &+= 1
        let myRun = runID
        task = Task { [weak self, weak sonosManager] in
            guard let self, let sonosManager else { return }
            await self.deliver(tracks, via: sonosManager, run: myRun)
            if self.runID == myRun { self.isRunning = false }
        }
    }

    /// Routes the resolved tracks to the chosen destination.
    private func deliver(_ tracks: [QueueItem], via sonosManager: SonosManager, run: Int) async {
        switch destination {
        case .savePlaylist:
            // Read the name at save time — the field stays editable
            // while a long resolve runs. Empty falls back to the brief,
            // then a default: a nameless playlist is unfindable.
            var playlistName = name.trimmingCharacters(in: .whitespaces)
            if playlistName.isEmpty {
                let briefName = String(aiBrief.trimmingCharacters(in: .whitespaces).prefix(60))
                playlistName = briefName.isEmpty ? L10n.playlistBuilderTitle : briefName
            }
            if let queueID = sonosManager.saveChoragusPlaylist(name: playlistName, tracks: tracks) {
                if let folderID { sonosManager.moveSavedQueue(id: queueID, toFolder: folderID) }
                savedMessage = L10n.playlistBuilderSaved(playlistName, tracks.count)
                deliveredDestination = .savePlaylist
            } else {
                generateError = L10n.playlistBuilderSaveFailed
            }
        case .queueEnd, .playNext, .playNow:
            let chosenID = targetGroupID ?? UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
            guard let group = sonosManager.groups.first(where: { $0.id == chosenID })
                    ?? sonosManager.groups.first else {
                generateError = L10n.playlistBuilderSaveFailed
                return
            }
            let items = tracks.compactMap { $0.browseItem(id: "PLBUILD:\($0.id)") }
            guard !items.isEmpty else {
                generateError = L10n.playlistBuilderNothingMatched
                return
            }
            do {
                if destination == .playNow {
                    try await sonosManager.playItemsReplacingQueue(items, in: group)
                } else {
                    _ = try await sonosManager.addBrowseItemsToQueue(items, in: group,
                                                                     playNext: destination == .playNext)
                }
                // A newer run owns the message fields now; a stale
                // delivery must not stamp them.
                guard runID == run else { return }
                savedMessage = L10n.playlistBuilderAddedToQueue(items.count, group.name)
                deliveredDestination = destination
            } catch {
                guard runID == run else { return }
                generateError = error.localizedDescription
            }
        }
    }

    /// `done` is 1-based and specs were submitted in row order, so the
    /// finished row is `done - 1`; the next pending row becomes the
    /// visible "searching" row.
    private func recordResolution(done: Int, item: QueueItem?) {
        // A cancelled run's in-flight lookup still fires once; rows may
        // have changed by then, so the stamp would land on the wrong row.
        guard isRunning else { return }
        progressDone = done
        let index = done - 1
        guard rows.indices.contains(index) else { return }
        if let item {
            rows[index].status = .resolved
            rows[index].artURL = item.albumArtURI
            rows[index].resolvedTitle = item.title
            rows[index].resolvedArtist = item.artist
            rows[index].resolvedItem = item
        } else {
            rows[index].status = .missing
        }
        if rows.indices.contains(index + 1), isRunning {
            rows[index + 1].status = .searching
        }
    }

    func cancel() {
        runID &+= 1
        task?.cancel()
        isRunning = false
        isGenerating = false
        progressDone = 0
        for index in rows.indices where rows[index].status == .searching {
            rows[index].status = .pending
        }
    }
}

// MARK: - View

struct PlaylistBuilderView: View {
    @Environment(SonosManager.self) private var sonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @State private var vm = PlaylistBuilderViewModel()
    @State private var showRawResponse = false
    @AppStorage(UDKey.playlistAIEnabled) private var aiEnabled = false
    @Environment(\.openSettings) private var openSettings

    /// Authenticated SMAPI services offered by the picker, Apple Music
    /// excluded (it is the built-in first option via the iTunes path).
    private var searchableServices: [SMAPIServiceDescriptor] {
        let appleSid = MusicServiceCatalog.shared.sid(forName: ServiceName.appleMusic) ?? ServiceID.appleMusic
        return smapiManager.authenticatedServiceList.filter { $0.id != appleSid }
    }

    /// The selected matching service, for the Match button label.
    private var matchServiceName: String {
        switch vm.serviceChoice {
        case .appleMusic: return ServiceName.appleMusic
        case .smapi(let sid): return searchableServices.first(where: { $0.id == sid })?.name ?? ""
        case .localLibrary: return L10n.localLibrary
        case .mediaServer(let id): return sonosManager.mediaServers.first(where: { $0.id == id })?.name ?? ""
        }
    }

    /// Catalog name for the AI availability clause. Local sources give
    /// nil — the AI cannot know a local library's or DLNA server's
    /// holdings, so no verification clause is added for them.
    private var catalogHint: String? {
        switch vm.serviceChoice {
        case .appleMusic: return ServiceName.appleMusic
        case .smapi(let sid): return searchableServices.first(where: { $0.id == sid })?.name
        case .localLibrary, .mediaServer: return nil
        }
    }

    /// Source-menu binding: one entry per configured service (by
    /// profile id), "manual", plus the "settings" action entry, which
    /// opens Settings instead of changing the selection.
    private var sourceSelection: Binding<String> {
        Binding(
            get: {
                if vm.useManual { return "manual" }
                return vm.selectedProfile.map { "profile:\($0.id.uuidString)" } ?? "manual"
            },
            set: { value in
                if value == "settings" {
                    // The menu adopts the tag it was handed; a revision
                    // bump re-reads the binding so the selection stays put.
                    openAISettings()
                    vm.refreshSettings()
                } else if value.hasPrefix("profile:"), let id = UUID(uuidString: String(value.dropFirst(8))) {
                    vm.selectProfile(id)
                    vm.useManual = false
                } else {
                    vm.useManual = true
                }
            })
    }

    /// The AI source is selectable only when enabled and keyed; any
    /// other state forces manual so the source menu never holds an
    /// unmatched selection (which renders blank).
    private func syncSource() {
        if !(aiEnabled && vm.hasUsableAI) { vm.useManual = true }
    }

    /// Opens the Settings scene on the AI tab: the tag is staged for a
    /// fresh window, and posted for one that is already open. Uses the
    /// SwiftUI environment action — the responder-chain selector does
    /// not resolve from this WindowManager-hosted window.
    private func openAISettings() {
        UserDefaults.standard.set(6, forKey: UDKey.settingsPendingTab)
        NotificationCenter.default.post(name: .settingsSelectTab, object: 6)
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    private var servicePicker: some View {
        Picker(L10n.playlistBuilderService, selection: $vm.serviceChoice) {
            Text(ServiceName.appleMusic).tag(PlaylistBuilderViewModel.ServiceChoice.appleMusic)
            ForEach(searchableServices, id: \.id) { svc in
                Text(svc.name).tag(PlaylistBuilderViewModel.ServiceChoice.smapi(svc.id))
            }
            Text(L10n.localLibrary).tag(PlaylistBuilderViewModel.ServiceChoice.localLibrary)
            ForEach(sonosManager.mediaServers, id: \.id) { server in
                Text(server.name).tag(PlaylistBuilderViewModel.ServiceChoice.mediaServer(server.id))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            describeSection
            Divider()
            songsSection
            Divider()
            saveSection
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 560)
        // Closing the window mid-run: stop the work instead of letting
        // a detached resolve burn 2 s per song into a discarded result.
        .onDisappear { vm.cancel() }
        .onAppear { syncSource() }
        .onChange(of: aiEnabled) { _, _ in syncSource() }
        // Settings changed while this window is open (key saved or
        // removed): re-read on window focus. Filtered to this window —
        // the notification fires for every window in the app.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard (note.object as? NSWindow)?.identifier?.rawValue == "ChoragusPlaylistBuilder" else { return }
            vm.refreshSettings()
            syncSource()
        }
        .sheet(isPresented: $showRawResponse) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.playlistBuilderShowResponse).font(.headline)
                ScrollView {
                    Text(vm.lastRawResponse ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(L10n.cancel) { showRawResponse = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .frame(minWidth: 460, minHeight: 380)
        }
    }

    // MARK: Step 1 — describe or paste

    private var describeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(L10n.playlistBuilderIntro)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.howDoesThisWork) {
                    WindowManager.shared.openHelp(topic: .aiPlaylists)
                }
                .buttonStyle(.link)
                .font(.caption)
                .fixedSize()
            }

            // Service first: it scopes what the AI is asked for and what
            // Build matches against.
            HStack(spacing: 12) {
                servicePicker

                // Source: the configured AI service (Settings → AI) or the
                // manual copy-prompt round trip. Until a service is
                // configured and its connection test has passed, the menu
                // carries an Open Settings entry that jumps to the AI tab.
                Picker(L10n.playlistBuilderGenerateWith, selection: sourceSelection) {
                    if aiEnabled {
                        ForEach(vm.usableProfiles) { profile in
                            Text(profile.name).tag("profile:\(profile.id.uuidString)")
                        }
                    }
                    Text(L10n.aiSourceManual).tag("manual")
                    if !(aiEnabled && vm.hasUsableAI && vm.isVerified) {
                        Divider()
                        Text("\(L10n.openSettings)\u{2026}").tag("settings")
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    LimitedTextEditor(placeholder: L10n.playlistBuilderExampleFormat(vm.samplePrompt),
                                      text: $vm.aiBrief,
                                      limit: SongListAIService.maxBriefLength)
                    // Sample prompts live in Help, one page for all twelve.
                    Button(L10n.playlistBuilderSamplesLink) {
                        WindowManager.shared.openHelp(topic: .aiPlaylists)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                if vm.useManual {
                    Button(L10n.playlistBuilderCopyPrompt) { vm.copyPromptTemplate(catalogHint: catalogHint) }
                } else {
                    Button(L10n.playlistBuilderGenerate) { vm.generate(catalogHint: catalogHint) }
                        .disabled(vm.aiBrief.trimmingCharacters(in: .whitespaces).isEmpty || vm.isGenerating || vm.isRunning)
                }
                Button(L10n.playlistBuilderPaste) { vm.pasteList() }
                    .disabled(vm.isGenerating || vm.isRunning)
            }

            HStack(spacing: 12) {
                if !vm.useManual {
                    Button(L10n.playlistBuilderCopyPrompt) { vm.copyPromptTemplate(catalogHint: catalogHint) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                if vm.lastRawResponse != nil {
                    Button(L10n.playlistBuilderShowResponse) { showRawResponse = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            if vm.promptCopied {
                Text(L10n.playlistBuilderPromptCopied)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if vm.isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.playlistBuilderGenerating)
                        .font(.caption).foregroundStyle(.secondary)
                    Text(L10n.playlistBuilderParsedCount(vm.rows.count))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let generateError = vm.generateError {
                Text(generateError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Step 2 — songs table

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.playlistBuilderSongsHeader).font(.headline)
                Text(L10n.playlistBuilderParsedCount(vm.rows.count))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if vm.isRunning {
                    ProgressView(value: Double(vm.progressDone), total: Double(max(vm.progressTotal, 1)))
                        .frame(width: 140)
                    Text(L10n.playlistBuilderProgress(vm.progressDone, vm.progressTotal))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(vm.rows) { row in
                            PlaylistBuilderRowView(row: row) { vm.removeRow(row.id) }
                                .id(row.id)
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.3)))
                .onChange(of: vm.rows.count) { _, _ in
                    // Follow the tail while the AI streams songs in.
                    if vm.isGenerating, let last = vm.rows.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: vm.progressDone) { _, done in
                    // Keep the row being resolved in view during Build.
                    let index = min(done, vm.rows.count - 1)
                    if vm.isRunning, vm.rows.indices.contains(index) {
                        proxy.scrollTo(vm.rows[index].id, anchor: .center)
                    }
                }
            }
            HStack(spacing: 8) {
                if vm.serviceFellBack {
                    Text(L10n.playlistBuilderServiceFallback)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if vm.isRunning || vm.isGenerating {
                    Button(L10n.playlistBuilderStop) { vm.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                // Idle once the list is resolved against the selected
                // service; a service change or a new list re-arms it.
                Button(L10n.playlistBuilderMatchTo(matchServiceName)) {
                    vm.build(sonosManager: sonosManager, smapiManager: smapiManager)
                }
                .disabled(!vm.canBuild)
            }
        }
    }

    /// Folders flattened depth-first for the save picker.
    private var folderChoices: [(id: Int64, name: String, depth: Int)] {
        SavedQueueTree(folders: sonosManager.savedQueueFolders(), queues: [])
            .flattenedFolders.map { ($0.folder.id, $0.folder.name, $0.depth) }
    }

    private var deliverLabel: String {
        switch vm.destination {
        case .savePlaylist: return L10n.save
        case .queueEnd: return L10n.addToQueue
        case .playNext: return L10n.playNext
        case .playNow: return L10n.playNow
        }
    }

    // MARK: Step 3 — send

    private var targetGroupChoices: [SonosGroup] {
        sonosManager.groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The picked room, else the one selected in the main window, else
    /// the first group — the same order the delivery resolves.
    private var effectiveTargetGroupID: Binding<String?> {
        Binding(
            get: {
                vm.targetGroupID
                    ?? UserDefaults.standard.string(forKey: UDKey.lastSelectedGroupID)
                    ?? targetGroupChoices.first?.id
            },
            set: { vm.targetGroupID = $0 })
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.playlistBuilderSendTo).font(.headline)
            HStack(spacing: 8) {
                Picker("", selection: $vm.destination) {
                    Text(L10n.playlistBuilderDestinationPlaylist).tag(PlaylistBuilderViewModel.BuildDestination.savePlaylist)
                    Text(L10n.addToQueue).tag(PlaylistBuilderViewModel.BuildDestination.queueEnd)
                    Text(L10n.playNext).tag(PlaylistBuilderViewModel.BuildDestination.playNext)
                    Text(L10n.playNow).tag(PlaylistBuilderViewModel.BuildDestination.playNow)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                if vm.destination == .savePlaylist {
                    LimitedTextField(placeholder: L10n.playlistBuilderNamePlaceholder,
                                     text: $vm.name,
                                     limit: PlaylistBuilderViewModel.maxNameLength)
                    // Folder in the Queue Library; nested folders are
                    // indented by depth.
                    Text(L10n.playlistBuilderChoragusFolder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $vm.folderID) {
                        Text(L10n.topLevel).tag(Int64?.none)
                        ForEach(folderChoices, id: \.id) { choice in
                            Text(String(repeating: "    ", count: choice.depth) + choice.name).tag(Int64?.some(choice.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .help(L10n.folders)
                } else {
                    // Queue deliveries name their room: the current rooms
                    // and groups, defaulting to the one selected in the
                    // main window.
                    Text(L10n.roomLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Picker("", selection: effectiveTargetGroupID) {
                        ForEach(targetGroupChoices) { group in
                            Text(group.name).tag(Optional(group.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
                // Explicit prominent style: the default-action button
                // alone kept its full accent colour while disabled, so
                // Save read as live with no songs, no name, or a match
                // still running.
                Button(deliverLabel) { vm.deliver(via: sonosManager) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!vm.canDeliver)
            }
            if let saved = vm.savedMessage {
                HStack(spacing: 10) {
                    Label(saved, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                    if vm.missingCount > 0 {
                        Text("\(L10n.playlistBuilderMisses) \(vm.missingCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // Only a saved playlist has somewhere to open; a queue
                    // delivery is already playing or queued.
                    if vm.deliveredDestination == .savePlaylist {
                        Button(L10n.playlistManager) {
                            _ = WindowManager.shared.openQueueLibraryForActiveGroup()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Row view

private struct PlaylistBuilderRowView: View {
    let row: PlaylistBuilderRow
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let art = row.artURL, let url = URL(string: art) {
                    CachedAsyncImage(url: url, cornerRadius: 4)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .overlay(Image(systemName: "music.note").font(.caption).foregroundStyle(.secondary))
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.resolvedTitle ?? row.spec.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(row.resolvedArtist ?? row.spec.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            switch row.status {
            case .pending:
                EmptyView()
            case .searching:
                ProgressView().controlSize(.small)
            case .resolved:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }

            if hovering {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}

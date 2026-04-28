/// SettingsScrobblingTab.swift — Scrobbling configuration UI.
///
/// Layout:
///   1. Last.fm enable + credential entry + Test + Connect / Disconnect
///   2. Double-scrobble warning
///   3. Room (source) multi-select — powered by history's distinct group names
///   4. Music-service multi-select — predefined list of known sources
///   5. Auto-scrobble toggle + manual "Scrobble Pending Now" button
///
/// Sections 3-5 are disabled until Last.fm is connected.
import SwiftUI
import SonosKit

struct SettingsScrobblingTab: View {
    @EnvironmentObject var scrobbleManager: ScrobbleManager
    @EnvironmentObject var playHistoryManager: PlayHistoryManager
    @EnvironmentObject var sonosManager: SonosManager
    @ObservedObject var lastfm: LastFMScrobbler

    // Local state for credential entry / test / connect flow.
    @State private var apiKeyInput: String = ""
    @State private var sharedSecretInput: String = ""
    @State private var testStatus: TestStatus = .notRun
    @State private var isTesting = false
    @State private var isConnecting = false
    @State private var connectError: String?

    // Selection state — mirrored into UserDefaults via ScrobbleManager.
    @State private var selectedRooms: Set<String> = []
    @State private var selectedMusicServices: Set<String> = []

    // Last.fm section expanded by default only until connected; afterwards
    // the per-user setup is done and it collapses out of the way.
    @State private var lastFMExpanded: Bool = true

    // Sonos Playlists / Favorites are NOT sources — they are saved
    // collections of tracks that already come from one of these actual
    // sources. Including them here would just mis-label what the filter
    // is actually matching against.
    //
    // The list is derived from `ServiceID.knownNames` so it stays in
    // sync with the services the rest of the app supports. Plus
    // "Local Library" which isn't a streaming service but is a
    // legitimate source. TuneIn (254) and TuneIn (New) (333) collapse
    // to a single "TuneIn" string in `knownNames`, so the dedupe is
    // automatic.
    private var knownMusicServices: [String] {
        var seen: Set<String> = []
        var out: [String] = ["Local Library"]
        seen.insert("Local Library")
        // Sort by name for predictable UI ordering.
        let services = ServiceID.knownNames.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        for name in services where seen.insert(name).inserted {
            out.append(name)
        }
        return out
    }

    enum TestStatus: Equatable {
        case notRun
        case passed
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.scrobblingIntro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            lastFMSection

            Divider()

            sourcesSection
                .disabled(!lastfm.isConnected)
                .opacity(lastfm.isConnected ? 1 : 0.4)

            Divider()

            musicServicesSection
                .disabled(!lastfm.isConnected)
                .opacity(lastfm.isConnected ? 1 : 0.4)

            Divider()

            actionsSection
                .disabled(!lastfm.isConnected)
                .opacity(lastfm.isConnected ? 1 : 0.4)
        }
        .onAppear {
            apiKeyInput = lastfm.tokenStore.apiKey ?? ""
            sharedSecretInput = lastfm.tokenStore.sharedSecret ?? ""
            selectedRooms = scrobbleManager.enabledRooms
            selectedMusicServices = scrobbleManager.enabledMusicServices
        }
    }

    // MARK: - Last.fm section

    private var lastFMSection: some View {
        let enabled = scrobbleManager.isServiceEnabled(lastfm)
        return DisclosureGroup(isExpanded: $lastFMExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L10n.enableLastFM, isOn: Binding(
                    get: { enabled },
                    set: { scrobbleManager.setServiceEnabled(lastfm, $0) }
                ))

                if enabled {
                    VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.lastFMCredentialsIntro)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link(L10n.openLastFMRegistration,
                         destination: URL(string: "https://www.last.fm/api/account/create")!)
                        .font(.callout)

                    HStack {
                        Text(L10n.apiKey).frame(width: 110, alignment: .trailing)
                        TextField(L10n.apiKeyPlaceholder, text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(lastfm.isConnected)
                    }
                    HStack {
                        Text(L10n.sharedSecret).frame(width: 110, alignment: .trailing)
                        SecureField(L10n.sharedSecretPlaceholder, text: $sharedSecretInput)
                            .textFieldStyle(.roundedBorder)
                            .disabled(lastfm.isConnected)
                    }

                    HStack(spacing: 12) {
                        Button(action: runTest) {
                            if isTesting {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(L10n.testCredentials)
                            }
                        }
                        .disabled(apiKeyInput.isEmpty || sharedSecretInput.isEmpty || isTesting || lastfm.isConnected)

                        testStatusIcon
                    }

                    HStack(spacing: 12) {
                        if lastfm.isConnected {
                            Button(L10n.disconnect, role: .destructive) {
                                lastfm.disconnect()
                                testStatus = .notRun
                            }
                        } else {
                            Button(action: runConnect) {
                                if isConnecting {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text(L10n.waitingForBrowser)
                                    }
                                } else {
                                    Text(L10n.connectToLastFM)
                                }
                            }
                            .disabled(testStatus != .passed || isConnecting)
                        }
                        if let err = connectError {
                            Text(err).font(.callout).foregroundStyle(.red).lineLimit(2)
                        }
                    }

                    // Double-scrobble warning
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                        Text(L10n.doubleScrobbleWarning)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.leading, 24)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                Text("Last.fm").fontWeight(.semibold)
                if lastfm.isConnected, let name = lastfm.connectedUsername {
                    Text("· \(name)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var testStatusIcon: some View {
        switch testStatus {
        case .notRun: EmptyView()
        case .passed:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L10n.credentialsValid).font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func runTest() {
        lastfm.tokenStore.apiKey = apiKeyInput
        lastfm.tokenStore.sharedSecret = sharedSecretInput
        isTesting = true
        testStatus = .notRun
        Task {
            do {
                try await lastfm.testCredentials()
                testStatus = .passed
            } catch {
                testStatus = .failed(error.localizedDescription)
            }
            isTesting = false
        }
    }

    private func runConnect() {
        isConnecting = true
        connectError = nil
        Task {
            do {
                try await lastfm.connect()
            } catch {
                connectError = error.localizedDescription
            }
            isConnecting = false
        }
    }

    // MARK: - Sources (rooms)

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.sources).font(.headline)
            Text(L10n.sourcesDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            let rooms = distinctRooms()
            if rooms.isEmpty {
                Text(L10n.noRoomsInHistory)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                FlowingChecklist(items: rooms, selected: $selectedRooms) { updated in
                    scrobbleManager.saveRoomSet(updated)
                }
            }
        }
    }

    private func distinctRooms() -> [String] {
        // Union of historical group names (decomposed from "A + B + C"
        // composites) and currently-discovered speakers. History alone
        // hides newly-added rooms that haven't played anything yet;
        // live-only would hide rooms that have played in the past but
        // are offline right now. Showing both lets the user pre-select
        // rooms they expect to scrobble even before any plays land.
        let historyRaw = playHistoryManager.repo.distinctGroupNames()
        var seen: Set<String> = []
        var out: [String] = []
        for name in historyRaw {
            for part in name.components(separatedBy: " + ") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                    out.append(trimmed)
                }
            }
        }
        for group in sonosManager.groups {
            for member in group.members {
                let trimmed = member.roomName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && seen.insert(trimmed).inserted {
                    out.append(trimmed)
                }
            }
        }
        return out.sorted()
    }

    // MARK: - Music services

    private var musicServicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.musicServicesToScrobble).font(.headline)
            Text(L10n.musicServicesDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            FlowingChecklist(items: knownMusicServices, selected: $selectedMusicServices) { updated in
                scrobbleManager.saveMusicServiceSet(updated)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L10n.autoScrobbleEveryFiveMinutes, isOn: Binding(
                get: { scrobbleManager.autoScrobbleEnabled },
                set: { scrobbleManager.autoScrobbleEnabled = $0 }
            ))

            let pending = scrobbleManager.pendingCount(for: lastfm)
            let preview = scrobbleManager.previewPending(for: lastfm)
            let stats = scrobbleManager.stats(for: lastfm)
            // The "pending" count from the repository is the raw row
            // count — it includes rows that current filters will skip.
            // Show eligible (will-actually-submit) primarily and the
            // filtered-out delta in parens so the user understands why
            // the number won't drop after a manual scrobble.
            let filteredOut = preview.filteredByRoom + preview.filteredByMusicService

            HStack(spacing: 16) {
                Button(action: { Task { await scrobbleManager.scrobblePending() } }) {
                    if scrobbleManager.isScrobbling {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L10n.scrobblingProgress) }
                    } else {
                        Text(L10n.scrobblePendingNow)
                    }
                }
                .disabled(scrobbleManager.isScrobbling || preview.eligible == 0)

                if filteredOut > 0 {
                    Text(L10n.pendingWithFilteredFormat(pending: preview.eligible, filtered: filteredOut))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(pending) \(L10n.pending)").font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 18) {
                Label("\(stats.sent) \(L10n.sent)", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Label("\(stats.ignored) \(L10n.ignored)", systemImage: "slash.circle")
                    .foregroundStyle(.secondary)
                Label("\(stats.failed) \(L10n.failed)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)

                if stats.ignored > 0 {
                    Button(L10n.resetIgnored) {
                        let cleared = scrobbleManager.resetIgnored(for: lastfm)
                        sonosDebugLog("[SCROBBLE] Reset \(cleared) ignored rows")
                    }
                    .buttonStyle(.link)
                    .help(L10n.resetIgnoredTooltip)
                }
            }
            .font(.callout)

            if let err = scrobbleManager.lastRunError {
                Text("\(L10n.lastRunLabel) \(err)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            pendingPreview
            diagnosticsDisclosure
        }
    }

    /// Shows what *would* happen on the next scrobble run against the
    /// current filters. Filter-driven rejections don't get persisted
    /// (correct — they must re-qualify when filters change) but that
    /// leaves the user with no clue why pending counts aren't dropping.
    /// Listing the buckets + a sample row per bucket tells them exactly
    /// which filter is blocking which song.
    @ViewBuilder
    private var pendingPreview: some View {
        let preview = scrobbleManager.previewPending(for: lastfm)
        if preview.examined > 0 && preview.eligible < preview.examined {
            DisclosureGroup("\(L10n.filterPreviewTitle) (\(preview.examined))") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Label("\(preview.eligible) \(L10n.wouldSend)", systemImage: "arrow.up.circle")
                            .foregroundStyle(.green)
                        Label("\(preview.filteredByRoom) \(L10n.roomBlocked)", systemImage: "house.slash")
                            .foregroundStyle(.orange)
                        Label("\(preview.filteredByMusicService) \(L10n.serviceBlocked)",
                              systemImage: "music.note.list")
                            .foregroundStyle(.orange)
                        Label("\(preview.permanentlyIneligible) \(L10n.structuralIneligible)",
                              systemImage: "slash.circle")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)

                    if !preview.sampleFilteredByRoom.isEmpty {
                        let rooms = scrobbleManager.enabledRooms.sorted().joined(separator: ", ")
                        previewBucket(
                            title: "\(L10n.roomBlockedExamples) (\(L10n.currentFilterPrefix): \(rooms))",
                            entries: preview.sampleFilteredByRoom,
                            detail: { "group: \($0.groupName)" }
                        )
                    }
                    if !preview.sampleFilteredByMusicService.isEmpty {
                        previewBucket(
                            title: L10n.serviceBlockedExamples,
                            entries: preview.sampleFilteredByMusicService,
                            detail: { "source: \($0.sourceURI ?? "(none)")" }
                        )
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private func previewBucket(
        title: String,
        entries: [PlayHistoryEntry],
        detail: @escaping (PlayHistoryEntry) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(e.artist) — \(e.title)").font(.callout).lineLimit(1)
                    Text(detail(e)).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
    }

    // MARK: - Diagnostics

    /// Answers "why didn't my tracks go?" by listing the most recent
    /// ignored/failed entries alongside the recorded reason. `ignored`
    /// conflates two cases in the stats row — our eligibility filter
    /// (< 30 s, missing artist, > 14 d, room/service filter) and Last.fm's
    /// server-side rejection (duplicate, blocklisted artist, timestamp
    /// drift). The reason string tells the user which bucket each one fell
    /// into.
    @ViewBuilder
    private var diagnosticsDisclosure: some View {
        let rows = scrobbleManager.recentNonSent(for: lastfm, limit: 50)
        if !rows.isEmpty {
            DisclosureGroup("\(L10n.recentNonScrobbled) (\(rows.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: row.state == .failedRetryable
                                  ? "exclamationmark.triangle"
                                  : "slash.circle")
                                .foregroundStyle(row.state == .failedRetryable ? .orange : .secondary)
                                .font(.callout)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(row.artist) — \(row.title)")
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(row.reason ?? L10n.noReasonRecorded)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(row.timestamp, style: .date)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }
}

// MARK: - FlowingChecklist helper

/// Simple wrap-around grid of checkbox-tagged items. Shared between the
/// Sources (rooms) and Music Services sections.
private struct FlowingChecklist: View {
    let items: [String]
    @Binding var selected: Set<String>
    let onChange: (Set<String>) -> Void

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 4)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                Toggle(isOn: Binding(
                    get: { selected.contains(item) },
                    set: { newValue in
                        if newValue { selected.insert(item) } else { selected.remove(item) }
                        onChange(selected)
                    }
                )) {
                    Text(item).font(.callout)
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

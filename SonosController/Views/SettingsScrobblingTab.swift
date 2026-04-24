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
    private let knownMusicServices: [String] = [
        "Local Library",
        "TuneIn", "Sonos Radio", "Calm Radio",
        "Apple Music", "Amazon Music", "Spotify", "SoundCloud", "YouTube Music"
    ]

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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Link(L10n.openLastFMRegistration,
                         destination: URL(string: "https://www.last.fm/api/account/create")!)
                        .font(.caption)

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
                            Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }

                    // Double-scrobble warning
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(L10n.doubleScrobbleWarning)
                            .font(.caption)
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
                        .font(.caption)
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
                Text(L10n.credentialsValid).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                .font(.caption)
                .foregroundStyle(.secondary)

            let rooms = distinctRooms()
            if rooms.isEmpty {
                Text(L10n.noRoomsInHistory)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                FlowingChecklist(items: rooms, selected: $selectedRooms) { updated in
                    scrobbleManager.saveRoomSet(updated)
                }
            }
        }
    }

    private func distinctRooms() -> [String] {
        // Each room name may be a composite "A + B + C"; decompose and dedupe.
        let raw = playHistoryManager.repo.distinctGroupNames()
        var seen: Set<String> = []
        var out: [String] = []
        for name in raw {
            for part in name.components(separatedBy: " + ") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
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
                .font(.caption)
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
            let stats = scrobbleManager.stats(for: lastfm)

            HStack(spacing: 16) {
                Button(action: { Task { await scrobbleManager.scrobblePending() } }) {
                    if scrobbleManager.isScrobbling {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L10n.scrobblingProgress) }
                    } else {
                        Text(L10n.scrobblePendingNow)
                    }
                }
                .disabled(scrobbleManager.isScrobbling || pending == 0)

                Text("\(pending) \(L10n.pending)").font(.caption).foregroundStyle(.secondary)
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
            .font(.caption)

            if let err = scrobbleManager.lastRunError {
                Text("\(L10n.lastRunLabel) \(err)")
                    .font(.caption)
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
            DisclosureGroup("Filter preview (next \(preview.examined) pending)") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Label("\(preview.eligible) would send", systemImage: "arrow.up.circle")
                            .foregroundStyle(.green)
                        Label("\(preview.filteredByRoom) room-blocked", systemImage: "house.slash")
                            .foregroundStyle(.orange)
                        Label("\(preview.filteredByMusicService) service-blocked",
                              systemImage: "music.note.list")
                            .foregroundStyle(.orange)
                        Label("\(preview.permanentlyIneligible) structural",
                              systemImage: "slash.circle")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    if !preview.sampleFilteredByRoom.isEmpty {
                        previewBucket(
                            title: "Room-blocked examples (current filter: \(scrobbleManager.enabledRooms.sorted().joined(separator: ", ")))",
                            entries: preview.sampleFilteredByRoom,
                            detail: { "group: \($0.groupName)" }
                        )
                    }
                    if !preview.sampleFilteredByMusicService.isEmpty {
                        previewBucket(
                            title: "Service-blocked examples",
                            entries: preview.sampleFilteredByMusicService,
                            detail: { "source: \($0.sourceURI ?? "(none)")" }
                        )
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func previewBucket(
        title: String,
        entries: [PlayHistoryEntry],
        detail: @escaping (PlayHistoryEntry) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(e.artist) — \(e.title)").font(.caption2).lineLimit(1)
                    Text(detail(e)).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
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
                                .font(.caption)
                                .frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(row.artist) — \(row.title)")
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(row.reason ?? L10n.noReasonRecorded)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(row.timestamp, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
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

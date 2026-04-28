/// PlayHistoryView.swift — Dedicated window for play history and statistics.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct PlayHistoryView: View {
    @EnvironmentObject var historyManager: PlayHistoryManager

    @State private var searchText = ""
    @State private var filterRoom: String?
    @State private var filterSource: String?
    @State private var filterStarred = false
    @State private var filterDateRange: DateRange = .all
    @State private var sortNewestFirst = true
    @State private var showClearConfirm = false
    @State private var showDeleteFilteredConfirm = false
    @State private var selectedTab = 1
    @State private var expandedArtEntry: PlayHistoryEntry?
    @State private var customDateFrom: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customDateTo: Date = Date()

    // Cached query results — updated via refreshFilteredEntries(), not computed per body eval
    @State private var cachedFilteredEntries: [PlayHistoryEntry] = []
    @State private var cachedFilteredCount: Int = 0
    @State private var searchDebounceTask: Task<Void, Never>?

    enum DateRange: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case week = "This Week"
        case month = "This Month"
        case quarter = "3 Months"
        case custom = "Custom Range"

        var displayName: String {
            switch self {
            case .all:    return L10n.allTime
            case .today:  return L10n.today
            case .week:   return L10n.thisWeek
            case .month:  return L10n.thisMonth
            case .quarter: return L10n.threeMonths
            case .custom: return L10n.customRange
            }
        }
    }

    private var hasActiveFilter: Bool {
        filterRoom != nil || filterSource != nil || filterStarred ||
        filterDateRange != .all || !searchText.isEmpty
    }

    private func sourceLabel(for entry: PlayHistoryEntry) -> String {
        historyManager.sourceServiceName(for: entry)
    }

    private var uniqueSources: [String] {
        Array(Set(historyManager.entries.map { sourceLabel(for: $0) })).sorted()
    }

    /// Cached filtered entries for display (updated by refreshFilteredEntries)
    private var filteredEntries: [PlayHistoryEntry] { cachedFilteredEntries }
    private var filteredEntriesUnsorted: [PlayHistoryEntry] { cachedFilteredEntries }

    private var hasActiveFilters: Bool {
        filterRoom != nil || filterSource != nil || filterDateRange != .all || !searchText.isEmpty || filterStarred
    }

    /// Compute date range bounds from filter selection
    private var dateBounds: (since: Date?, until: Date?) {
        switch filterDateRange {
        case .all: return (nil, nil)
        case .today: return (Calendar.current.startOfDay(for: Date()), nil)
        case .week: return (Calendar.current.date(byAdding: .day, value: -7, to: Date()), nil)
        case .month: return (Calendar.current.date(byAdding: .month, value: -1, to: Date()), nil)
        case .quarter: return (Calendar.current.date(byAdding: .month, value: -3, to: Date()), nil)
        case .custom:
            let from = Calendar.current.startOfDay(for: customDateFrom)
            let to = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: customDateTo))
            return (from, to)
        }
    }

    /// Refresh cached results from SQLite query
    private func refreshFilteredEntries() {
        let bounds = dateBounds
        var results = historyManager.queryFiltered(
            since: bounds.since, until: bounds.until,
            room: filterRoom, source: filterSource,
            searchText: searchText.isEmpty ? nil : searchText,
            sortNewestFirst: sortNewestFirst
        )
        if filterStarred {
            results = results.filter(\.starred)
        }
        cachedFilteredEntries = results
        cachedFilteredCount = results.count
    }

    /// Debounced refresh for search text changes
    private func debouncedRefresh() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: Timing.searchDebounce)
            guard !Task.isCancelled else { return }
            refreshFilteredEntries()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Info banner
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text(L10n.historyIntroBody)
                    .font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))

            // Shared filter bar
            filterBar
            activeFilterChips

            Divider()

            // Tab picker
            Picker("", selection: $selectedTab) {
                Text(L10n.dashboard).tag(1)
                Text(L10n.historyTab).tag(0)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)

            switch selectedTab {
            case 0:
                PlayHistoryView2(entries: filteredEntries, expandedArtEntry: $expandedArtEntry, sourceLabel: sourceLabel, onFilter: { action in
                    switch action {
                    case .search(let text): searchText = text
                    case .room(let room): filterRoom = room
                    case .source(let source): filterSource = source
                    }
                }, onStar: { entry in
                    historyManager.toggleStar(id: entry.id)
                    refreshFilteredEntries()
                })
            default:
                PlayHistoryDashboard(entries: filteredEntriesUnsorted, expandedArtEntry: $expandedArtEntry)
                    .environmentObject(historyManager)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    exportCSV()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(historyManager.entries.isEmpty)

                if hasActiveFilter {
                    Button {
                        showDeleteFilteredConfirm = true
                    } label: {
                        Label("Delete \(cachedFilteredEntries.count) Shown", systemImage: "xmark.bin")
                    }
                    .disabled(cachedFilteredEntries.isEmpty)
                }

                Button {
                    showClearConfirm = true
                } label: {
                    Label(L10n.clearHistory, systemImage: "trash")
                }
                .disabled(historyManager.entries.isEmpty)
            }
        }
        .alert("Delete \(cachedFilteredEntries.count) Filtered Entries?", isPresented: $showDeleteFilteredConfirm) {
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.delete, role: .destructive) {
                let ids = Set(cachedFilteredEntries.map(\.id))
                historyManager.deleteEntries(ids)
                refreshFilteredEntries()
            }
        } message: {
            Text(L10n.deleteFilteredWarning(cachedFilteredEntries.count))
        }
        .alert("Clear Play History?", isPresented: $showClearConfirm) {
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.clearHistory, role: .destructive) {
                historyManager.clearHistory()
            }
        } message: {
            Text(L10n.deleteAllWarning(historyManager.totalEntries))
        }
        .onDisappear {
            NSColorPanel.shared.close()
        }
        .sheet(item: $expandedArtEntry) { entry in
            ExpandedArtView(
                artURL: entry.albumArtURI.flatMap { URL(string: $0) },
                title: entry.title,
                artist: entry.artist,
                album: entry.album,
                stationName: entry.stationName
            )
        }
        .onAppear {
            refreshFilteredEntries()
            // Kick off an iTunes backfill pass for entries with
            // missing or ephemeral art. The task in PlayHistoryManager
            // is throttled and remembers attempted keys, so opening
            // the view repeatedly doesn't re-search the same tracks.
            Task { await historyManager.backfillMissingArtwork() }
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            // Periodic refresh to catch new entries from background logging
            let currentTotal = historyManager.totalEntries
            if currentTotal != cachedFilteredCount || (cachedFilteredEntries.isEmpty && currentTotal > 0) {
                refreshFilteredEntries()
            }
        }
        .onChange(of: filterDateRange) { refreshFilteredEntries() }
        .onChange(of: filterRoom) { refreshFilteredEntries() }
        .onChange(of: filterSource) { refreshFilteredEntries() }
        .onChange(of: sortNewestFirst) { refreshFilteredEntries() }
        .onChange(of: customDateFrom) { refreshFilteredEntries() }
        .onChange(of: customDateTo) { refreshFilteredEntries() }
        .onChange(of: searchText) { debouncedRefresh() }
        .onReceive(historyManager.$entries) { _ in
            refreshFilteredEntries()
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField(L10n.searchTracksPlaceholder, text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { searchText = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 280)

            // Date range
            Picker("", selection: $filterDateRange) {
                ForEach(DateRange.allCases, id: \.self) { range in
                    Text(range.displayName).tag(range)
                }
            }
            .fixedSize()

            // Custom date range pickers
            if filterDateRange == .custom {
                DatePicker("", selection: $customDateFrom, displayedComponents: [.date])
                    .labelsHidden()
                    .frame(width: 100)
                Text("to")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $customDateTo, displayedComponents: [.date])
                    .labelsHidden()
                    .frame(width: 100)
            }

            // Room
            Picker("", selection: $filterRoom) {
                Label(L10n.allRooms, systemImage: "hifispeaker.2").tag(String?.none)
                Divider()
                ForEach(historyManager.uniqueRooms, id: \.self) { room in
                    Text(room).tag(Optional(room))
                }
            }
            .fixedSize()

            // Source
            Picker("", selection: $filterSource) {
                Label(L10n.allSources, systemImage: "dot.radiowaves.left.and.right").tag(String?.none)
                Divider()
                ForEach(uniqueSources, id: \.self) { source in
                    HStack {
                        Circle().fill(ServiceColor.color(for: source)).frame(width: 6, height: 6)
                        Text(source)
                    }
                    .tag(Optional(source))
                }
            }
            .fixedSize()

            // Starred filter
            Button {
                filterStarred.toggle()
                refreshFilteredEntries()
            } label: {
                Image(systemName: filterStarred ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(filterStarred ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .tooltip(filterStarred ? "Show all tracks" : "Show starred only")

            Spacer()

            // Count
            Text("\(cachedFilteredCount)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            + Text(" tracks")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Active Filter Chips

    @ViewBuilder
    private var activeFilterChips: some View {
        if hasActiveFilters {
            HStack(spacing: 6) {
                if filterDateRange != .all {
                    filterChip(label: filterDateRange.displayName, icon: "calendar") {
                        withAnimation { filterDateRange = .all }
                    }
                }
                if let room = filterRoom {
                    filterChip(label: room, icon: "hifispeaker") {
                        withAnimation { filterRoom = nil }
                    }
                }
                if let source = filterSource {
                    filterChip(label: source, icon: "music.note", color: ServiceColor.color(for: source)) {
                        withAnimation { filterSource = nil }
                    }
                }
                if filterStarred {
                    filterChip(label: L10n.statStarred, icon: "star.fill", color: .yellow) {
                        withAnimation { filterStarred = false; refreshFilteredEntries() }
                    }
                }
                if !searchText.isEmpty {
                    filterChip(label: "\"\(searchText)\"", icon: "magnifyingglass") {
                        withAnimation { searchText = "" }
                    }
                }

                Spacer()

                Button(L10n.clearAll) {
                    withAnimation {
                        filterDateRange = .all
                        filterRoom = nil
                        filterSource = nil
                        filterStarred = false
                        searchText = ""
                    }
                    refreshFilteredEntries()
                }
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func filterChip(label: String, icon: String, color: Color = .accentColor, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.85), in: Capsule())
    }

    // MARK: - History Content


    // MARK: - Copy

    @ViewBuilder
    private func copyEntryMenu(_ entry: PlayHistoryEntry) -> some View {
        Button(L10n.copyTrackDetails) {
            var lines: [String] = []
            if !entry.stationName.isEmpty { lines.append("\(L10n.sourceLabel): \(entry.stationName)") }
            if !entry.artist.isEmpty { lines.append("\(L10n.artistLabel): \(entry.artist)") }
            if !entry.album.isEmpty { lines.append("\(L10n.albumLabel): \(entry.album)") }
            if !entry.title.isEmpty { lines.append("\(L10n.trackLabel): \(entry.title)") }
            copyToClipboard(lines.joined(separator: "\n"))
        }
        if !entry.title.isEmpty {
            Button(L10n.copyTitle) { copyToClipboard(entry.title) }
        }
        if !entry.artist.isEmpty {
            Button(L10n.copyArtist) { copyToClipboard(entry.artist) }
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Export

    private func exportCSV() {
        let csv = historyManager.exportCSV()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "SonosPlayHistory.csv"
        panel.begin { result in
            if result == .OK, let url = panel.url {
                try? csv.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

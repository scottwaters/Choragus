/// PlayHistoryView.swift — Dedicated window for play history and statistics.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct PlayHistoryView: View {
    @EnvironmentObject var historyManager: PlayHistoryManager

    @State private var searchText = ""
    @State private var filterRoom: String?
    @State private var filterSource: String?
    @State private var filterDateRange: DateRange = .all
    @State private var sortNewestFirst = true
    @State private var showClearConfirm = false
    @State private var selectedTab = 1
    @State private var selectedEntryID: UUID?
    @State private var hoveredEntryID: UUID?
    @State private var expandedArtEntry: PlayHistoryEntry?

    enum DateRange: String, CaseIterable {
        case all = "All Time"
        case today = "Today"
        case week = "This Week"
        case month = "This Month"
        case quarter = "3 Months"
    }

    private func sourceLabel(for entry: PlayHistoryEntry) -> String {
        historyManager.sourceServiceName(for: entry)
    }

    private var uniqueSources: [String] {
        Array(Set(historyManager.entries.map { sourceLabel(for: $0) })).sorted()
    }

    /// Entries filtered by date/room/source/search but NOT sorted (for dashboard)
    private var filteredEntriesUnsorted: [PlayHistoryEntry] {
        var result = historyManager.entries

        if filterDateRange != .all {
            let calendar = Calendar.current
            let now = Date()
            let cutoff: Date
            switch filterDateRange {
            case .today: cutoff = calendar.startOfDay(for: now)
            case .week: cutoff = calendar.date(byAdding: .day, value: -7, to: now)!
            case .month: cutoff = calendar.date(byAdding: .month, value: -1, to: now)!
            case .quarter: cutoff = calendar.date(byAdding: .month, value: -3, to: now)!
            case .all: cutoff = .distantPast
            }
            result = result.filter { $0.timestamp >= cutoff }
        }

        if let room = filterRoom {
            result = result.filter { $0.groupName == room }
        }
        if let source = filterSource {
            result = result.filter { sourceLabel(for: $0) == source }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.artist.lowercased().contains(query) ||
                $0.title.lowercased().contains(query) ||
                $0.album.lowercased().contains(query) ||
                $0.stationName.lowercased().contains(query) ||
                $0.groupName.lowercased().contains(query)
            }
        }
        return result
    }

    /// Sorted for history list display
    private var filteredEntries: [PlayHistoryEntry] {
        sortNewestFirst ? filteredEntriesUnsorted.sorted { $0.timestamp > $1.timestamp }
                        : filteredEntriesUnsorted.sorted { $0.timestamp < $1.timestamp }
    }

    private var hasActiveFilters: Bool {
        filterRoom != nil || filterSource != nil || filterDateRange != .all || !searchText.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Info banner
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                Text("Listening activity is tracked across all speakers and zones while SonosController is running.")
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
                Text("Dashboard").tag(1)
                Text("History").tag(0)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 8)

            if selectedTab == 0 {
                historyContent
            } else {
                PlayHistoryDashboard(entries: filteredEntriesUnsorted, expandedArtEntry: $expandedArtEntry)
                    .environmentObject(historyManager)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    exportCSV()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(historyManager.entries.isEmpty)

                Button {
                    showClearConfirm = true
                } label: {
                    Label(L10n.clearHistory, systemImage: "trash")
                }
                .disabled(historyManager.entries.isEmpty)
            }
        }
        .alert("Clear Play History?", isPresented: $showClearConfirm) {
            Button(L10n.cancel, role: .cancel) {}
            Button(L10n.clearHistory, role: .destructive) {
                historyManager.clearHistory()
            }
        } message: {
            Text("This will permanently remove all \(historyManager.totalEntries) entries.")
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
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 10) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                TextField("Search tracks, artists, albums...", text: $searchText)
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
                    Text(range.rawValue).tag(range)
                }
            }
            .fixedSize()

            // Room
            Picker("", selection: $filterRoom) {
                Label("All Rooms", systemImage: "hifispeaker.2").tag(String?.none)
                Divider()
                ForEach(historyManager.uniqueRooms, id: \.self) { room in
                    Text(room).tag(Optional(room))
                }
            }
            .fixedSize()

            // Source
            Picker("", selection: $filterSource) {
                Label("All Sources", systemImage: "dot.radiowaves.left.and.right").tag(String?.none)
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

            Spacer()

            // Count
            Text("\(filteredEntriesUnsorted.count)")
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
                    filterChip(label: filterDateRange.rawValue, icon: "calendar") {
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
                if !searchText.isEmpty {
                    filterChip(label: "\"\(searchText)\"", icon: "magnifyingglass") {
                        withAnimation { searchText = "" }
                    }
                }

                Spacer()

                Button("Clear All") {
                    withAnimation {
                        filterDateRange = .all
                        filterRoom = nil
                        filterSource = nil
                        searchText = ""
                    }
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

    @ViewBuilder
    private var historyContent: some View {
        if filteredEntries.isEmpty {
            emptyState
        } else {
            // Sort toggle row
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { sortNewestFirst.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: sortNewestFirst ? "arrow.down" : "arrow.up")
                            .font(.system(size: 9, weight: .bold))
                        Text(sortNewestFirst ? "Newest First" : "Oldest First")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)

            historyList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle" : "clock")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(hasActiveFilters ? "No matching entries" : "No play history yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            if hasActiveFilters {
                Text("Try adjusting your filters")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Button("Clear Filters") {
                    withAnimation {
                        filterDateRange = .all
                        filterRoom = nil
                        filterSource = nil
                        searchText = ""
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Text("Play some music and your history will appear here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History List

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredEntries) { entry in
                    historyRow(entry)
                        .id(entry.id)
                }
            }
        }
    }

    private func historyRow(_ entry: PlayHistoryEntry) -> some View {
        let isSelected = selectedEntryID == entry.id
        let isHovered = hoveredEntryID == entry.id
        let source = sourceLabel(for: entry)

        return HStack(spacing: 12) {
            // Album art
            CachedAsyncImage(url: entry.albumArtURI.flatMap { URL(string: $0) }, cornerRadius: 6)
                .frame(width: 40, height: 40)
                .onTapGesture { expandedArtEntry = entry }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !entry.artist.isEmpty {
                        Text(entry.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !entry.album.isEmpty {
                        Text("—")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                        Text(entry.album)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if !entry.stationName.isEmpty {
                        Text("—")
                            .font(.system(size: 11))
                            .foregroundStyle(.quaternary)
                        Text(entry.stationName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange.opacity(0.8))
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Source badge
            Text(source)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(ServiceColor.color(for: source), in: Capsule())

            // Room
            if !entry.groupName.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "hifispeaker")
                        .font(.system(size: 9))
                    Text(entry.groupName)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .leading)
            }

            // Duration
            if entry.duration > 0 {
                Text(formatDuration(entry.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 40, alignment: .trailing)
            }

            // Timestamp
            Text(entry.timestamp, format: .relative(presentation: .named))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15)
                      : isHovered ? Color.primary.opacity(0.04)
                      : Color.clear)
                .padding(.horizontal, 8)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedEntryID = selectedEntryID == entry.id ? nil : entry.id
            }
        }
        .onHover { hovering in
            hoveredEntryID = hovering ? entry.id : nil
        }
        .contextMenu {
            copyEntryMenu(entry)
            Divider()
            if !entry.artist.isEmpty {
                Button("Filter by \"\(entry.artist)\"") {
                    searchText = entry.artist
                }
            }
            if !entry.groupName.isEmpty {
                Button("Filter by Room: \(entry.groupName)") {
                    filterRoom = entry.groupName
                }
            }
            Button("Filter by Source: \(source)") {
                filterSource = source
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Copy

    @ViewBuilder
    private func copyEntryMenu(_ entry: PlayHistoryEntry) -> some View {
        Button("Copy Track Details") {
            var lines: [String] = []
            if !entry.stationName.isEmpty { lines.append("\(L10n.sourceLabel): \(entry.stationName)") }
            if !entry.artist.isEmpty { lines.append("\(L10n.artistLabel): \(entry.artist)") }
            if !entry.album.isEmpty { lines.append("\(L10n.albumLabel): \(entry.album)") }
            if !entry.title.isEmpty { lines.append("\(L10n.trackLabel): \(entry.title)") }
            copyToClipboard(lines.joined(separator: "\n"))
        }
        if !entry.title.isEmpty {
            Button("Copy Title") { copyToClipboard(entry.title) }
        }
        if !entry.artist.isEmpty {
            Button("Copy Artist") { copyToClipboard(entry.artist) }
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

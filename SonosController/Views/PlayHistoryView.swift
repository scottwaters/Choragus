/// PlayHistoryView.swift — Dedicated window for play history and statistics.
import SwiftUI
import SonosKit
import UniformTypeIdentifiers

struct PlayHistoryView: View {
    @EnvironmentObject var historyManager: PlayHistoryManager

    @State private var filterRoom: String?
    @State private var filterSource: String?
    @State private var filterArtist = ""
    @State private var sortOrder = [KeyPathComparator(\PlayHistoryEntry.timestamp, order: .reverse)]
    @State private var showClearConfirm = false
    @State private var showExporter = false
    @State private var selectedTab = 0

    private func sourceLabel(for entry: PlayHistoryEntry) -> String {
        if !entry.stationName.isEmpty { return entry.stationName }
        if let uri = entry.sourceURI {
            if URIPrefix.isLocal(uri) { return ServiceName.localLibrary }
            if URIPrefix.isRadio(uri) { return ServiceName.radio }
            // Try SID extraction
            let decoded = (uri.removingPercentEncoding ?? uri).replacingOccurrences(of: "&amp;", with: "&")
            if let range = decoded.range(of: "sid=") {
                let numStr = String(decoded[range.upperBound...].prefix(while: { $0.isNumber }))
                if let sid = Int(numStr), let name = ServiceID.knownNames[sid] {
                    return name
                }
            }
            if decoded.contains("spotify") { return ServiceName.spotify }
            if decoded.hasPrefix(URIPrefix.sonosHTTP) { return ServiceName.streaming }
        }
        return ServiceName.local
    }

    private var uniqueSources: [String] {
        Array(Set(historyManager.entries.map { sourceLabel(for: $0) })).sorted()
    }

    private var filteredEntries: [PlayHistoryEntry] {
        var result = historyManager.entries
        if let room = filterRoom {
            result = result.filter { $0.groupName == room }
        }
        if let source = filterSource {
            result = result.filter { sourceLabel(for: $0) == source }
        }
        if !filterArtist.isEmpty {
            let query = filterArtist.lowercased()
            result = result.filter {
                $0.artist.lowercased().contains(query) ||
                $0.title.lowercased().contains(query) ||
                sourceLabel(for: $0).lowercased().contains(query)
            }
        }
        return result.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                Text("History").tag(0)
                Text("Stats").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if selectedTab == 0 {
                historyTab
            } else {
                statsTab
            }
        }
        .frame(minWidth: 600, minHeight: 400)
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
    }

    // MARK: - History Tab

    private var historyTab: some View {
        VStack(spacing: 0) {
            // Filters
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter by artist or track...", text: $filterArtist)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 250)

                Picker("Room", selection: $filterRoom) {
                    Text("All Rooms").tag(String?.none)
                    ForEach(historyManager.uniqueRooms, id: \.self) { room in
                        Text(room).tag(Optional(room))
                    }
                }
                .frame(maxWidth: 150)

                Picker("Source", selection: $filterSource) {
                    Text("All Sources").tag(String?.none)
                    ForEach(uniqueSources, id: \.self) { source in
                        Text(source).tag(Optional(source))
                    }
                }
                .frame(maxWidth: 150)

                Spacer()

                Text("\(filteredEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            // Table
            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(historyManager.entries.isEmpty ? "No play history yet" : "No matching entries")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredEntries, sortOrder: $sortOrder) {
                    TableColumn("Date", value: \.timestamp) { entry in
                        Text(entry.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                    }
                    .width(min: 100, ideal: 140)

                    TableColumn("Title", value: \.title) { entry in
                        Text(entry.title).font(.caption).lineLimit(1)
                            .contextMenu { copyEntryMenu(entry) }
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Artist", value: \.artist) { entry in
                        Text(entry.artist).font(.caption).lineLimit(1)
                            .contextMenu { copyEntryMenu(entry) }
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("Album", value: \.album) { entry in
                        Text(entry.album).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                            .contextMenu { copyEntryMenu(entry) }
                    }
                    .width(min: 80, ideal: 130)

                    TableColumn("Source") { entry in
                        Text(sourceLabel(for: entry)).font(.caption).lineLimit(1)
                            .contextMenu { copyEntryMenu(entry) }
                    }
                    .width(min: 60, ideal: 100)

                    TableColumn("Room", value: \.groupName) { entry in
                        Text(entry.groupName).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 100)
                }
            }
        }
    }

    // MARK: - Stats Tab

    private var statsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Summary
                HStack(spacing: 40) {
                    statBox(title: "Total Plays", value: "\(historyManager.totalEntries)")
                    statBox(title: "Listening Hours", value: String(format: "%.1f", historyManager.totalListeningHours))
                    statBox(title: "Unique Artists", value: "\(historyManager.uniqueArtists.count)")
                    statBox(title: "Rooms Used", value: "\(historyManager.uniqueRooms.count)")
                }
                .padding(.horizontal)

                Divider()

                HStack(alignment: .top, spacing: 40) {
                    // Most played artists
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Artists")
                            .font(.headline)
                        ForEach(Array(historyManager.mostPlayedArtists.prefix(10).enumerated()), id: \.offset) { idx, item in
                            HStack {
                                Text("\(idx + 1).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(item.0)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(item.1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contextMenu {
                                Button("Copy Artist") { copyToClipboard(item.0) }
                            }
                        }
                        if historyManager.mostPlayedArtists.isEmpty {
                            Text("No data yet").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Most played tracks
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Tracks")
                            .font(.headline)
                        ForEach(Array(historyManager.mostPlayedTracks.prefix(10).enumerated()), id: \.offset) { idx, item in
                            HStack {
                                Text("\(idx + 1).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading) {
                                    Text(item.0).font(.caption).lineLimit(1)
                                    Text(item.1).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(item.2)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contextMenu {
                                Button("Copy Track") { copyToClipboard("\(item.0) — \(item.1)") }
                            }
                        }
                        if historyManager.mostPlayedTracks.isEmpty {
                            Text("No data yet").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Most played stations
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Sources")
                            .font(.headline)
                        ForEach(Array(historyManager.mostPlayedStations.prefix(10).enumerated()), id: \.offset) { idx, item in
                            HStack {
                                Text("\(idx + 1).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                Text(item.0)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(item.1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contextMenu {
                                Button("Copy Source") { copyToClipboard(item.0) }
                            }
                        }
                        if historyManager.mostPlayedStations.isEmpty {
                            Text("No data yet").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    private func statBox(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

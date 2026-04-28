/// PlayHistoryView2.swift — Reimagined history layout for comparison.
///
/// Card-based timeline grouped by day, with larger art, richer metadata display,
/// and a visual timeline spine. Designed for a more immersive browsing experience.
import SwiftUI
import SonosKit

enum HistoryFilterAction {
    case search(String)
    case room(String)
    case source(String)
}

struct PlayHistoryView2: View {
    let entries: [PlayHistoryEntry]
    @Binding var expandedArtEntry: PlayHistoryEntry?
    var sourceLabel: (PlayHistoryEntry) -> String
    var onFilter: ((HistoryFilterAction) -> Void)?
    var onStar: ((PlayHistoryEntry) -> Void)?

    private var groupedByDay: [(String, [PlayHistoryEntry])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = L10n.currentLocale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .full
        formatter.timeStyle = .none

        var groups: [(String, [PlayHistoryEntry])] = []
        var currentDay = ""
        var currentEntries: [PlayHistoryEntry] = []

        for entry in entries {
            let day = formatter.string(from: entry.timestamp)
            if day != currentDay {
                if !currentEntries.isEmpty {
                    groups.append((currentDay, currentEntries))
                }
                currentDay = day
                currentEntries = [entry]
            } else {
                currentEntries.append(entry)
            }
        }
        if !currentEntries.isEmpty {
            groups.append((currentDay, currentEntries))
        }
        return groups
    }

    var body: some View {
        if entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(groupedByDay, id: \.0) { day, dayEntries in
                        Section {
                            ForEach(dayEntries) { entry in
                                cardRow(entry)
                            }
                        } header: {
                            dayStickyHeader(day, count: dayEntries.count)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Day Header

    private func dayStickyHeader(_ day: String, count: Int) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(.tertiary)
                .frame(width: 24, height: 2)
            Text(day)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.tertiary, in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: - Card Row

    private func cardRow(_ entry: PlayHistoryEntry) -> some View {
        let source = sourceLabel(entry)
        let timeStr = entry.timestamp.formatted(date: .omitted, time: .shortened)

        return HStack(alignment: .top, spacing: 0) {
            // Card content
            HStack(spacing: 14) {
                // Art — larger for visual impact
                CachedAsyncImage(url: entry.albumArtURI.flatMap { URL(string: $0) }, cornerRadius: 8)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
                    .onTapGesture { expandedArtEntry = entry }

                // Metadata — structured grid layout
                VStack(alignment: .leading, spacing: 4) {
                    // Title row
                    HStack(spacing: 4) {
                        if entry.starred {
                            Image(systemName: "star.fill")
                                .font(.footnote)
                                .foregroundStyle(.yellow)
                        }
                        Text(entry.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(timeStr)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    // Artist / Album row
                    HStack(spacing: 0) {
                        if !entry.artist.isEmpty {
                            Text(entry.artist)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if !entry.album.isEmpty {
                            if !entry.artist.isEmpty {
                                Text("  /  ")
                                    .font(.subheadline)
                                    .foregroundStyle(.quaternary)
                            }
                            Text(entry.album)
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }

                    // Metadata pills row
                    HStack(spacing: 6) {
                        // Source pill
                        Text(source)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ServiceColor.color(for: source), in: Capsule())

                        // Station name
                        if !entry.stationName.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 8))
                                Text(entry.stationName)
                                    .font(.footnote)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.orange.opacity(0.9))
                        }

                        Spacer(minLength: 0)

                        // Room
                        if !entry.groupName.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "hifispeaker")
                                    .font(.system(size: 8))
                                Text(entry.groupName)
                                    .font(.footnote)
                            }
                            .foregroundStyle(.tertiary)
                        }

                        // Duration
                        if entry.duration > 0 {
                            Text(formatDuration(entry.duration))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary.opacity(0.5), lineWidth: 0.5)
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .contextMenu {
            Button {
                onStar?(entry)
            } label: {
                Label(entry.starred ? L10n.unstarVerb : L10n.starVerb, systemImage: entry.starred ? "star.fill" : "star")
            }
            Divider()
            Button(L10n.copyTrackDetails) {
                var lines: [String] = []
                if !entry.stationName.isEmpty { lines.append("\(L10n.station): \(entry.stationName)") }
                if !entry.artist.isEmpty { lines.append("\(L10n.artistFieldLabel): \(entry.artist)") }
                if !entry.album.isEmpty { lines.append("\(L10n.albumFieldLabel): \(entry.album)") }
                if !entry.title.isEmpty { lines.append("\(L10n.track): \(entry.title)") }
                copyToClipboard(lines.joined(separator: "\n"))
            }
            if !entry.title.isEmpty {
                Button(L10n.copyTitle) { copyToClipboard(entry.title) }
            }
            if !entry.artist.isEmpty {
                Button(L10n.copyArtist) { copyToClipboard(entry.artist) }
            }
            Divider()
            if !entry.artist.isEmpty {
                Button(L10n.filterByArtist(entry.artist)) { onFilter?(.search(entry.artist)) }
            }
            if !entry.groupName.isEmpty {
                Button(L10n.filterByRoom(entry.groupName)) { onFilter?(.room(entry.groupName)) }
            }
            Button(L10n.filterBySource(source)) { onFilter?(.source(source)) }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(L10n.noListeningHistory)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(L10n.historyTracksAppear)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

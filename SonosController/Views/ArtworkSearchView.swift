/// ArtworkSearchView.swift — Manual artwork search via iTunes API.
///
/// Prepopulated with current track metadata. User can edit fields and search,
/// then pick from a grid of results. Selected artwork is persisted as an override.
import SwiftUI
import SonosKit

struct ArtworkSearchView: View {
    @State var artist: String
    @State var title: String
    @State var album: String
    let onSelect: (String) -> Void

    @State private var results: [ArtResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var selectedResult: ArtResult?
    @State private var throttleSnapshot: ITunesRateLimiter.Snapshot?
    @Environment(\.dismiss) private var dismiss

    private static let cooldownTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// Strips parenthetical/bracket content for cleaner searches
    private static func cleanForSearch(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    init(artist: String, title: String, album: String, onSelect: @escaping (String) -> Void) {
        let cleanedTitle = Self.cleanForSearch(title)
        _artist = State(initialValue: artist)
        _title = State(initialValue: cleanedTitle.isEmpty ? title : cleanedTitle)
        _album = State(initialValue: album)
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.searchArtworkTitle)
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 8) {
                searchField(L10n.artistFieldLabel, text: $artist)
                searchField(L10n.titleFieldLabel, text: $title)
                searchField(L10n.albumFieldLabel, text: $album)
            }

            HStack {
                Button(L10n.search) {
                    performSearch()
                }
                .controlSize(.small)
                .disabled(artist.isEmpty && title.isEmpty && album.isEmpty)
                .keyboardShortcut(.return, modifiers: [])

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button(L10n.cancel) { dismiss() }
                    .controlSize(.small)
            }

            if let snap = throttleSnapshot, !snap.isAvailable, let until = snap.cooldownUntil {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.appleMusicSearchUnavailable)
                            .font(.caption)
                        Text(L10n.appleMusicResumesAt(Self.cooldownTimeFormatter.string(from: until)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if hasSearched && results.isEmpty && !isSearching {
                Text(L10n.artworkNoResults)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            if !results.isEmpty {
                Divider()
                Text(L10n.selectArtworkHeader(results.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let columns = Array(repeating: GridItem(.fixed(80), spacing: 8), count: 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results) { result in
                        VStack(spacing: 4) {
                            // Use the shared image cache so re-renders /
                            // scroll recycling don't re-fetch from iTunes.
                            CachedAsyncImage(
                                url: URL(string: result.artURL),
                                cornerRadius: 6,
                                priority: .interactive
                            )
                            .frame(width: 80, height: 80)
                            .onTapGesture {
                                selectedResult = result
                            }
                            Text(result.label)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 80)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            Task { throttleSnapshot = await ITunesRateLimiter.shared.snapshot() }
            if !artist.isEmpty || !title.isEmpty || !album.isEmpty {
                performSearch()
            }
        }
        .sheet(item: $selectedResult) { result in
            VStack(spacing: 16) {
                CachedAsyncImage(
                    url: URL(string: result.artURL),
                    cornerRadius: 8,
                    priority: .interactive
                )
                .frame(width: 300, height: 300)

                Text(result.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 16) {
                    Button(L10n.useThisArtwork) {
                        let url = result.artURL
                        selectedResult = nil
                        onSelect(url)
                    }
                    .controlSize(.regular)
                    .keyboardShortcut(.return)

                    Button(L10n.cancel) {
                        selectedResult = nil
                    }
                    .controlSize(.regular)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
    }

    private func searchField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { performSearch() }
        }
    }

    private func performSearch() {
        guard !isSearching else { return }
        isSearching = true
        hasSearched = true
        results = []

        Task {
            var found: [ArtResult] = []

            // Strategy 1: artist + title (most specific)
            if !artist.isEmpty && !title.isEmpty {
                found.append(contentsOf: await iTunesSearch(query: "\(artist) \(title)", entity: "song", limit: 5))
            }
            // Strategy 2: artist + album
            if !artist.isEmpty && !album.isEmpty && found.count < 4 {
                found.append(contentsOf: await iTunesSearch(query: "\(artist) \(album)", entity: "album", limit: 5))
            }
            // Strategy 3: title only
            if found.count < 4 && !title.isEmpty {
                found.append(contentsOf: await iTunesSearch(query: title, entity: "song", limit: 5))
            }
            // Strategy 4: artist only
            if found.count < 4 && !artist.isEmpty {
                found.append(contentsOf: await iTunesSearch(query: artist, entity: "album", limit: 5))
            }
            // Strategy 5: album only
            if found.count < 4 && !album.isEmpty {
                found.append(contentsOf: await iTunesSearch(query: album, entity: "album", limit: 5))
            }

            // Deduplicate by art URL
            var seen = Set<String>()
            results = found.filter { seen.insert($0.artURL).inserted }
            isSearching = false
            throttleSnapshot = await ITunesRateLimiter.shared.snapshot()
        }
    }

    private func iTunesSearch(query: String, entity: String, limit: Int) async -> [ArtResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=\(entity)&limit=\(limit)") else {
            return []
        }

        // User-initiated search — bypass the self-throttle so background art
        // enrichment can't starve it. Apple-side 403/429 still respected.
        guard let (data, _) = await ITunesRateLimiter.shared.performUnthrottled(url: url, session: URLSession.shared) else {
            return []
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["results"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let artSmall = item["artworkUrl100"] as? String else { return nil }
            let artLarge = artSmall
                .replacingOccurrences(of: "100x100", with: "600x600")
                .replacingOccurrences(of: "60x60", with: "600x600")
                .replacingOccurrences(of: "30x30", with: "600x600")
            let name = item["collectionName"] as? String
                ?? item["trackName"] as? String
                ?? item["artistName"] as? String
                ?? ""
            return ArtResult(artURL: artLarge, label: name)
        }
    }
}

private struct ArtResult: Identifiable, Hashable {
    let artURL: String
    let label: String
    var id: String { artURL }
}

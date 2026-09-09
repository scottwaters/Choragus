#if DEBUG
import Foundation
import AppKit
import SonosKit

struct TestFixtureEntry: Codable, Equatable {
    let id: String
    let kind: String
    let objectID: String
    let resourceURIPrefix: String?
    let expectedStrategy: String?
    let action: String
    let displayTitle: String
    let displayArtist: String?
    var maxAddLatencyMs: Int?
}

enum TestFixtureCapture {
    private static let bookmarkKey = "testFixtureBookmark"

    static var isEnabled: Bool {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "TestFixturePath") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        return !raw.isEmpty && !raw.hasPrefix("$(")
    }

    private static var hintedPath: String? {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "TestFixturePath") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        if raw.isEmpty || raw.hasPrefix("$(") { return nil }
        return raw
    }

    enum WriteResult {
        case appended
        case replaced
        case failed(String)
    }

    @MainActor
    static func write(entry: TestFixtureEntry, service: String) -> WriteResult {
        guard let dir = ensureBookmarkedDirectoryURL() else { return .failed("no fixtures directory granted") }
        let didStart = dir.startAccessingSecurityScopedResource()
        defer { if didStart { dir.stopAccessingSecurityScopedResource() } }
        let fileURL = dir.appendingPathComponent("\(service).json")
        var entries: [TestFixtureEntry] = []
        if let data = try? Data(contentsOf: fileURL) {
            entries = (try? JSONDecoder().decode([TestFixtureEntry].self, from: data)) ?? []
        }
        let result: WriteResult
        if let idx = entries.firstIndex(where: { $0.objectID == entry.objectID && $0.action == entry.action }) {
            entries[idx] = entry
            result = .replaced
        } else {
            entries.append(entry)
            result = .appended
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
            sonosDebugLog("[FIXTURE] \(result) \(entry.id) → \(fileURL.lastPathComponent)")
            return result
        } catch {
            let msg = "encode/write failed: \(error)"
            sonosDebugLog("[FIXTURE] \(msg)")
            return .failed(msg)
        }
    }

    @MainActor
    private static func ensureBookmarkedDirectoryURL() -> URL? {
        if let url = resolveStoredBookmark() { return url }
        return promptForFixturesDirectory()
    }

    @MainActor
    private static func resolveStoredBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: data,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if isStale {
                UserDefaults.standard.removeObject(forKey: bookmarkKey)
                return nil
            }
            return url
        } catch {
            sonosDebugLog("[FIXTURE] bookmark resolve failed: \(error)")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
    }

    @MainActor
    private static func promptForFixturesDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Test Fixtures Directory"
        panel.message = "Grant Choragus write access to the test fixtures directory."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let hint = hintedPath {
            panel.directoryURL = URL(fileURLWithPath: hint, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            UserDefaults.standard.set(data, forKey: bookmarkKey)
            sonosDebugLog("[FIXTURE] bookmark granted for \(url.path)")
            return url
        } catch {
            sonosDebugLog("[FIXTURE] bookmark create failed: \(error)")
            return nil
        }
    }

    static func kind(for item: BrowseItem) -> String? {
        switch item.itemClass {
        case .musicTrack: return "track"
        case .musicAlbum: return "album"
        case .playlist: return "playlist"
        case .favorite: return "favourite"
        case .radioStation: return "station"
        case .radioShow: return "podcast-episode"
        case .musicArtist, .genre, .unknown: return nil
        case .container:
            let oid = item.objectID
            if oid.contains(":playlist:") || oid.contains("/playlist/") || oid.hasPrefix("SQ:") { return "playlist" }
            if oid.contains(":album:") || oid.contains("/album/") { return "album" }
            if oid.contains(":station:") || oid.contains("/station/") { return "station" }
            return nil
        }
    }

    static func resourceURIPrefix(from uri: String) -> String? {
        guard let colonIdx = uri.firstIndex(of: ":") else { return nil }
        let prefix = String(uri[...colonIdx])
        if prefix.contains("/") { return nil }
        return prefix
    }

    static func serviceStem(for item: BrowseItem) -> String? {
        if item.objectID.hasPrefix("FV:2/") { return "favourites" }
        if let sid = smapiSid(from: item.objectID), let stem = serviceStem(sid: sid) {
            return stem
        }
        if let desc = item.serviceDescriptor, let num = rinconNumber(from: desc),
           let name = RINCONService.knownNames[num] {
            return slug(name)
        }
        if let uri = item.resourceURI, !uri.isEmpty {
            if URIPrefix.isLocal(uri) { return "local-library" }
            if uri.hasPrefix("x-sonos-spotify:") { return "spotify" }
            if uri.hasPrefix("x-sonos-http:song:") || uri.hasPrefix("x-sonos-http:track:") { return "apple-music" }
            if URIPrefix.isRadio(uri), let sid = sidQueryParam(in: uri), let stem = serviceStem(sid: sid) {
                return stem
            }
        }
        return nil
    }

    private static func smapiSid(from objectID: String) -> Int? {
        let lower = SMAPIPrefix.lower
        let upper = SMAPIPrefix.upper
        let body: Substring
        if objectID.hasPrefix(lower) { body = objectID.dropFirst(lower.count) }
        else if objectID.hasPrefix(upper) { body = objectID.dropFirst(upper.count) }
        else { return nil }
        let digits = body.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func serviceStem(sid: Int) -> String? {
        switch sid {
        case ServiceID.spotify: return "spotify"
        case ServiceID.appleMusic: return "apple-music"
        case ServiceID.calmRadio: return "calm-radio"
        case ServiceID.tuneIn, ServiceID.tuneInNew: return "tunein"
        case ServiceID.sonosRadio: return "sonos-radio"
        case ServiceID.plex: return "plex"
        case 308: return "radio-paradise"
        default:
            if let name = ServiceID.knownNames[sid] { return slug(name) }
            return nil
        }
    }

    private static func rinconNumber(from descriptor: String) -> Int? {
        guard descriptor.hasPrefix("SA_RINCON") else { return nil }
        let after = descriptor.dropFirst("SA_RINCON".count)
        let digits = after.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func sidQueryParam(in uri: String) -> Int? {
        guard let qIdx = uri.firstIndex(of: "?") else { return nil }
        let query = uri[uri.index(after: qIdx)...]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2, parts[0] == "sid" { return Int(parts[1]) }
        }
        return nil
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
        let ascii = lowered.unicodeScalars.map { scalar -> Character in
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return "-"
        }
        let collapsed = String(ascii)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "untitled" : collapsed
    }
}

import SwiftUI

struct AddToTestFixturesMenuItem: View {
    private let explicitService: String?
    private let explicitAction: String?
    private let provider: () async -> BrowseItem?

    init(item: BrowseItem, action: String? = nil) {
        self.explicitService = nil
        self.explicitAction = action
        self.provider = { item }
    }

    init(service: String, action: String? = nil, provider: @escaping () async -> BrowseItem?) {
        self.explicitService = service
        self.explicitAction = action
        self.provider = provider
    }

    private static func defaultAction(for kind: String) -> String {
        switch kind {
        case "album", "playlist", "station": return "playAll"
        default: return "playNow"
        }
    }

    var body: some View {
        if TestFixtureCapture.isEnabled {
            Button("Add to test fixtures") {
                let explicitAction = self.explicitAction
                let explicitService = self.explicitService
                Task { @MainActor in
                    guard let item = await provider() else {
                        sonosDebugLog("[FIXTURE] capture skipped: provider returned nil")
                        return
                    }
                    guard !item.objectID.isEmpty else {
                        sonosDebugLog("[FIXTURE] capture skipped: empty objectID")
                        return
                    }
                    guard let stem = explicitService ?? TestFixtureCapture.serviceStem(for: item) else {
                        sonosDebugLog("[FIXTURE] capture skipped: \(item.objectID) — service stem nil")
                        return
                    }
                    guard let kind = TestFixtureCapture.kind(for: item) else {
                        sonosDebugLog("[FIXTURE] capture skipped: \(item.objectID) — kind nil (class=\(item.itemClass))")
                        return
                    }
                    let action = explicitAction ?? Self.defaultAction(for: kind)
                    let prefix = item.resourceURI.flatMap { uri in
                        uri.isEmpty ? nil : TestFixtureCapture.resourceURIPrefix(from: uri)
                    }
                    let strategy = item.resourceURI.flatMap { $0.isEmpty ? nil : item.playbackStrategy.rawValue }
                    let entry = TestFixtureEntry(
                        id: "\(stem)-\(kind)-\(TestFixtureCapture.slug(item.title))",
                        kind: kind,
                        objectID: item.objectID,
                        resourceURIPrefix: prefix,
                        expectedStrategy: strategy,
                        action: action,
                        displayTitle: item.title,
                        displayArtist: item.artist.isEmpty ? nil : item.artist,
                        maxAddLatencyMs: nil
                    )
                    _ = TestFixtureCapture.write(entry: entry, service: stem)
                }
            }
        }
    }
}

extension TestFixtureCapture.WriteResult: Equatable {
    static func == (lhs: TestFixtureCapture.WriteResult, rhs: TestFixtureCapture.WriteResult) -> Bool {
        switch (lhs, rhs) {
        case (.appended, .appended), (.replaced, .replaced): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}
#endif

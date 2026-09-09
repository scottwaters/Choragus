/// MediaServerService.swift — Browse third-party UPnP/DLNA media servers.
///
/// Sonos cannot browse UPnP media servers. A speaker's browse root offers
/// `A:` (its own index), `S:` (SMB shares), `SQ:`, `R:`, `FV:` and `Q:` —
/// there is no node for a DLNA server, and no way to add one. SMB is its only
/// local source.
///
/// It will, however, play an ordinary HTTP URL. So a media server on the
/// network — Synology's Media Server, MinimServer, Asset, Plex, Jellyfin —
/// can supply both the browse tree and the audio, with the server doing the
/// indexing, tag reading and artwork. Browse the tree, hand the speaker the
/// `res` URL, and it plays.
///
/// Two failure modes matter more than the happy path, because UPnP reports
/// neither and both look identical to the user — a track that never starts:
///
/// - **The server advertises an address the speakers cannot route to.** A
///   server can answer SSDP from one subnet while every URL it hands out
///   points at a VLAN the speakers have no route to.
/// - **A firewall permits some speakers and not others.** Reachability is
///   therefore a per-speaker property, never a per-server one.
///
/// Both are why `MediaServerService` records the answering address alongside
/// the advertised one, and why callers must verify per speaker before
/// presenting a server as usable.
import Foundation

public struct MediaServer: Identifiable, Equatable, Sendable {
    /// UDN from the device description, stable across restarts.
    public let id: String
    /// The name shown everywhere: the user's title for this server when
    /// one is set (`CustomTitles`), otherwise the advertised one.
    public let name: String
    /// The name the server advertises in its device description. Kept
    /// so a rename can be shown against it and cleared back to it.
    public let advertisedName: String
    public let modelName: String
    /// Base URL built from the address that ANSWERED, not the one advertised.
    public let baseURL: URL
    /// Path of the ContentDirectory control endpoint, relative to `baseURL`.
    public let controlPath: String
    /// Set when the server advertised a host different from the one that
    /// answered. Speakers are given URLs on the advertised host, so a value
    /// here is the most likely explanation for "it browses but won't play".
    public let advertisedHostMismatch: String?

    public init(id: String, name: String, modelName: String, baseURL: URL,
                controlPath: String, advertisedHostMismatch: String? = nil,
                advertisedName: String? = nil) {
        self.id = id
        self.name = name
        self.advertisedName = advertisedName ?? name
        self.modelName = modelName
        self.baseURL = baseURL
        self.controlPath = controlPath
        self.advertisedHostMismatch = advertisedHostMismatch
    }

    public var isRenamed: Bool { name != advertisedName }

    /// The same server under a different display name. An empty or
    /// whitespace title reverts to the advertised name.
    public func renamed(to title: String?) -> MediaServer {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return MediaServer(id: id, name: trimmed.isEmpty ? advertisedName : trimmed,
                           modelName: modelName, baseURL: baseURL, controlPath: controlPath,
                           advertisedHostMismatch: advertisedHostMismatch,
                           advertisedName: advertisedName)
    }
}

public enum MediaServerService {

    /// Art a media server published for a track, keyed by the track's play
    /// URL.
    ///
    /// Needed because the speaker does not carry it. Playing a media-server
    /// track, Sonos reports `artURL=<none>` on most updates, and when it does
    /// report art it is its own `/getaa?` proxy wrapping the server's URL,
    /// which returns 404. The art published at browse time is the only
    /// reliable source and has to survive from browse to playback.
    public enum PublishedArt {
        private static let key = "mediaServers.trackArt"     // [playURL: artURL]
        private static let capacity = 5000
        /// Serializes read-modify-write — `UserDefaults` is atomic per call,
        /// not across a read and a write, so concurrent enqueues could lose
        /// entries. Same hazard `ResolvedPlaybackRegistry` locks against.
        /// Doubles as the guard for the in-memory snapshot below.
        private static let storeLock = NSLock()
        /// Lookups run per queue row per refresh and per Now Playing render;
        /// bridging the defaults dictionary on each would be a hot-path tax.
        nonisolated(unsafe) private static var snapshot: [String: String]?

        static func remember(playURL: String, art: String?) {
            guard let art, !art.isEmpty, !playURL.isEmpty else { return }
            storeLock.lock()
            defer { storeLock.unlock() }
            // Unchanged-check against the in-memory snapshot BEFORE the
            // defaults bridge: browse/search call this once per result
            // item, and bridging a 5000-entry dictionary per item is
            // the hot-path tax the snapshot exists to avoid.
            if let cached = snapshot, cached[playURL] == art { return }
            var store = snapshot ?? (UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:])
            guard store[playURL] != art else {
                snapshot = store
                return
            }
            if store.count >= capacity {
                for surplus in store.keys.prefix(store.count - capacity + 1) where surplus != playURL {
                    store.removeValue(forKey: surplus)
                }
            }
            store[playURL] = art
            UserDefaults.standard.set(store, forKey: key)
            snapshot = store
        }

        public static func art(forPlayURL playURL: String) -> URL? {
            storeLock.lock()
            if snapshot == nil {
                snapshot = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            }
            let stored = snapshot?[playURL]
            storeLock.unlock()
            guard let stored else { return nil }
            return URL(string: stored)
        }
    }

    /// Hosts a server has served content or art from.
    public enum ContentHosts {
        private static let key = "mediaServers.contentHosts"   // [host: serverID]
        /// Same read-modify-write hazard and hot-path reads as `PublishedArt`.
        private static let storeLock = NSLock()
        nonisolated(unsafe) private static var snapshot: [String: String]?

        static func remember(host: String, serverID: String) {
            storeLock.lock()
            defer { storeLock.unlock() }
            var store = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            guard store[host] != serverID else { return }
            store[host] = serverID
            UserDefaults.standard.set(store, forKey: key)
            snapshot = store
        }

        public static func serverID(servingHost host: String) -> String? {
            storeLock.lock()
            defer { storeLock.unlock() }
            if snapshot == nil {
                snapshot = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            }
            return snapshot?[host]
        }
    }


    /// Name of the server serving this host, when one is known. Used by
    /// `ServiceName.resolve` so a queue row names the server rather than
    /// "Streaming". Reads the same persisted stores the browse path fills,
    /// so it answers before discovery has run this session.
    public static func serverName(servingHost host: String) -> String? {
        guard let id = ContentHosts.serverID(servingHost: host) else { return nil }
        return Remembered.name(forID: id)
    }

    /// Servers seen before, so a section does not vanish because a server
    /// declined to answer a broadcast. `libupnp` servers (Synology DMS)
    /// announce on their own schedule and go quiet between times; discovery
    /// that trusts SSDP alone shows a library that appears and disappears.
    /// Servers the user added by hand. In manual-only mode these are the only
    /// servers surfaced; in discovery mode they are shown alongside whatever
    /// SSDP finds. Distinct from `Remembered`, which any discovered server
    /// enters automatically.
    public enum Pinned {
        private static let key = "mediaServers.pinned"      // [id]

        public static func ids() -> Set<String> {
            Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        }

        public static func pin(id: String) {
            var all = ids(); all.insert(id)
            UserDefaults.standard.set(Array(all).sorted(), forKey: key)
        }

        public static func unpin(id: String) {
            var all = ids(); all.remove(id)
            UserDefaults.standard.set(Array(all).sorted(), forKey: key)
        }
    }

    /// Display names the user chose, keyed by server UDN. Applied when
    /// the manager publishes its list, so the sidebar, Browse, the queue
    /// and the agent server all show the same name; the advertised name
    /// stays on the struct for reverting and for matching.
    public enum CustomTitles {
        private static let key = "mediaServers.titles"      // [id: title]
        public static let maxLength = 60

        public static func all() -> [String: String] {
            UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        }

        public static func title(for id: String) -> String? {
            all()[id]
        }

        /// Stores a title, or removes the entry when the title is blank so
        /// the server reverts to its advertised name.
        public static func set(_ title: String?, for id: String) {
            var store = all()
            let trimmed = String((title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            if trimmed.isEmpty { store.removeValue(forKey: id) } else { store[id] = trimmed }
            UserDefaults.standard.set(store, forKey: key)
        }

        public static func forget(id: String) { set(nil, for: id) }

        /// The list with every stored title applied.
        public static func applying(to servers: [MediaServer]) -> [MediaServer] {
            let titles = all()
            guard !titles.isEmpty else { return servers }
            return servers.map { server in
                guard let title = titles[server.id] else { return server }
                return server.renamed(to: title)
            }
        }
    }

    public enum Remembered {
        private static let key = "mediaServers.known"   // [id: "name\tdescriptionURL"]

        public static func remember(_ server: MediaServer, descriptionURL: URL) {
            var store = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            store[server.id] = "\(server.name)\t\(descriptionURL.absoluteString)"
            UserDefaults.standard.set(store, forKey: key)
            nameLock.lock()
            nameSnapshot = nil
            nameLock.unlock()
        }

        /// Description URLs to re-probe directly, newest knowledge last.
        public static func descriptionURLs() -> [(id: String, name: String, url: URL)] {
            let store = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            return store.compactMap { id, packed in
                let parts = packed.components(separatedBy: "\t")
                guard parts.count == 2, let url = URL(string: parts[1]) else { return nil }
                return (id, parts[0], url)
            }
        }

        public static func forget(id: String) {
            var store = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
            store.removeValue(forKey: id)
            UserDefaults.standard.set(store, forKey: key)
            nameLock.lock()
            nameSnapshot = nil
            nameLock.unlock()
        }

        /// Display name for a remembered server. Per-row render path — the
        /// same snapshot treatment as the other stores.
        nonisolated(unsafe) private static var nameSnapshot: [String: String]?
        private static let nameLock = NSLock()

        public static func name(forID id: String) -> String? {
            nameLock.lock()
            defer { nameLock.unlock() }
            if nameSnapshot == nil {
                let store = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
                nameSnapshot = store.compactMapValues { $0.components(separatedBy: "\t").first }
            }
            return nameSnapshot?[id]
        }

        public static func removeAll() {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Builds a server from an address a user typed, or one remembered from a
    /// previous session. Accepts a bare host, `host:port`, or a full
    /// description URL; a bare host is tried against the ports the common
    /// servers use.
    /// A remembered server that is powered off answers nothing; the default
    /// URLSession timeout would hold discovery for a minute per address.
    static let probeTimeout: TimeInterval = 5

    public static func probe(address: String) async -> MediaServer? {
        for url in candidateDescriptionURLs(for: address) {
            var request = URLRequest(url: url)
            request.timeoutInterval = probeTimeout
            guard let fetched = try? await MediaServerDiscovery.cappedFetch(request),
                  (fetched.response as? HTTPURLResponse)?.statusCode == 200,
                  let xml = String(data: fetched.data, encoding: .utf8),
                  let server = makeServer(descriptionXML: xml, locationURL: url,
                                          answeringHost: url.host)
            else { continue }
            Remembered.remember(server, descriptionURL: url)
            return server
        }
        return nil
    }

    /// Description URLs worth trying for a typed address. Ports and paths are
    /// the defaults of common servers: Synology (50001),
    /// MinimServer and friends (9790, 8200), Plex (32469).
    static func candidateDescriptionURLs(for address: String) -> [URL] {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if text.contains("://") {
            // Explicit-URL form: web schemes only — this string can come
            // from a remembered LOCATION, which was network-supplied.
            guard let direct = URL(string: text),
                  let scheme = direct.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return []
            }
            return [direct]
        }
        if text.contains("/") {
            if let direct = URL(string: "http://\(text)") { return [direct] }
            return []
        }
        // host:port — one guess at the path per known server family.
        if text.contains(":") {
            return ["/desc/device.xml", "/rootDesc.xml", "/description.xml", "/DeviceDescription.xml"]
                .compactMap { URL(string: "http://\(text)\($0)") }
        }
        let host = text
        var out: [URL] = []
        for (port, path) in [(50001, "/desc/device.xml"), (9790, "/DeviceDescription.xml"),
                             (8200, "/rootDesc.xml"), (32469, "/DeviceDescription.xml")] {
            if let url = URL(string: "http://\(host):\(port)\(path)") { out.append(url) }
        }
        return out
    }


    /// Builds a `MediaServer` from a description document.
    ///
    /// `answeringHost` is the address the SSDP response came from; the
    /// description's own `URLBase`/LOCATION host is what the server believes
    /// it is. When they differ, the server's own URLs — the ones speakers are
    /// handed — point at the advertised host, so the difference is recorded
    /// rather than quietly normalised away.
    public static func makeServer(descriptionXML: String,
                                  locationURL: URL,
                                  answeringHost: String?) -> MediaServer? {
        func tag(_ name: String) -> String? {
            guard let open = descriptionXML.range(of: "<\(name)>"),
                  let close = descriptionXML.range(of: "</\(name)>", range: open.upperBound..<descriptionXML.endIndex)
            else { return nil }
            let value = String(descriptionXML[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        // A media server must expose ContentDirectory; anything else on the
        // network answering MediaServer:1 is not usable here.
        guard descriptionXML.contains("urn:schemas-upnp-org:service:ContentDirectory:1"),
              let controlPath = contentDirectoryControlPath(in: descriptionXML),
              let host = locationURL.host
        else { return nil }

        let port = locationURL.port ?? 80
        guard let base = URL(string: "http://\(host):\(port)/") else { return nil }
        // The control URL is resolved against the description host; an
        // absolute URL naming another host would send every Browse there.
        guard let control = URL(string: controlPath, relativeTo: base),
              control.host?.lowercased() == host.lowercased()
        else { return nil }
        let mismatch = (answeringHost.map { $0 != host } ?? false) ? answeringHost : nil

        return MediaServer(
            id: tag("UDN") ?? "\(host):\(port)",
            name: tag("friendlyName") ?? host,
            modelName: tag("modelName") ?? "",
            baseURL: base,
            controlPath: controlPath,
            advertisedHostMismatch: mismatch)
    }

    /// The `controlURL` belonging to the ContentDirectory service block.
    ///
    /// A description lists several services; taking the first `controlURL` in
    /// the document returns ConnectionManager's on most servers, which then
    /// faults on every Browse.
    static func contentDirectoryControlPath(in xml: String) -> String? {
        guard let marker = xml.range(of: "urn:schemas-upnp-org:service:ContentDirectory:1") else { return nil }
        let rest = xml[marker.upperBound...]
        guard let open = rest.range(of: "<controlURL>"),
              let close = rest.range(of: "</controlURL>", range: open.upperBound..<rest.endIndex)
        else { return nil }
        let path = String(rest[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// Browses one container, returning its children.
    ///
    /// `RequestedCount` is bounded per call and the caller pages: servers cap
    /// results silently, and a library of tens of thousands of tracks must not
    /// be requested in one go.
    public static func browse(server: MediaServer,
                              objectID: String,
                              start: Int = 0,
                              count: Int = 200,
                              soap: SOAPClient = SOAPClient()) async throws -> [BrowseItem] {
        // Log the request as sent. A 400 from the server is otherwise
        // indistinguishable from a malformed object id, and the SOAP layer
        // records only the URL.
        sonosDiagLog(.info, tag: "MEDIASERVER", "Browsing media server",
                     context: ["server": server.name, "objectID": objectID,
                               "start": String(start), "count": String(count)])
        let response = try await soap.send(
            to: server.baseURL,
            path: server.controlPath,
            service: "ContentDirectory",
            action: "Browse",
            arguments: [
                ("ObjectID", objectID),
                ("BrowseFlag", "BrowseDirectChildren"),
                ("Filter", "*"),
                ("StartingIndex", String(start)),
                ("RequestedCount", String(count)),
                ("SortCriteria", ""),
            ],
            timeoutSeconds: 20)

        guard let didl = response["Result"], !didl.isEmpty else { return [] }
        let host = server.baseURL.host ?? ""
        let port = server.baseURL.port ?? 80
        let items = BrowseXMLParser.parse(didl, deviceIP: host, devicePort: port,
                                          upgradeInsecureArt: false)
            .filter(isAudioRelevant)
            .map(markAsDirectHTTP)
        // Content and art usually come from a different port than control, and
        // can come from a different host entirely. Remember where they were
        // served from so a track playing later can be traced back to this
        // server — that is what names it in Now Playing.
        for item in items {
            for url in [item.resourceURI, item.albumArtURI].compactMap({ $0 }) {
                if let contentHost = URL(string: url)?.host, IPAddress.isLAN(contentHost) {
                    ContentHosts.remember(host: contentHost, serverID: server.id)
                }
            }
            if let playURL = item.resourceURI {
                PublishedArt.remember(playURL: playURL, art: item.albumArtURI)
            }
        }
        return items
    }

    /// UPnP ContentDirectory `Search` across the whole server (container
    /// "0") for audio items whose title contains `term`. Search support
    /// is server-dependent: a server without it faults or returns
    /// nothing, and this fails open to an empty result rather than
    /// erroring the caller — a miss, not a failure.
    public static func search(server: MediaServer,
                              term: String,
                              count: Int = 25,
                              soap: SOAPClient = SOAPClient()) async -> [BrowseItem] {
        let escaped = term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let criteria = "upnp:class derivedfrom \"object.item.audioItem\" and dc:title contains \"\(escaped)\""
        do {
            let response = try await soap.send(
                to: server.baseURL,
                path: server.controlPath,
                service: "ContentDirectory",
                action: "Search",
                arguments: [
                    ("ContainerID", "0"),
                    ("SearchCriteria", criteria),
                    ("Filter", "*"),
                    ("StartingIndex", "0"),
                    ("RequestedCount", String(count)),
                    ("SortCriteria", ""),
                ],
                timeoutSeconds: 20)
            guard let didl = response["Result"], !didl.isEmpty else { return [] }
            let host = server.baseURL.host ?? ""
            let port = server.baseURL.port ?? 80
            let items = BrowseXMLParser.parse(didl, deviceIP: host, devicePort: port,
                                              upgradeInsecureArt: false)
                .filter(isAudioRelevant)
                .map(markAsDirectHTTP)
            for item in items {
                if let playURL = item.resourceURI {
                    PublishedArt.remember(playURL: playURL, art: item.albumArtURI)
                    if let contentHost = URL(string: playURL)?.host, IPAddress.isLAN(contentHost) {
                        ContentHosts.remember(host: contentHost, serverID: server.id)
                    }
                }
            }
            return items
        } catch {
            sonosDebugLog("[MEDIASERVER] Search unsupported or failed on \(server.name): \(error)")
            return []
        }
    }

    /// Drops photo and video entries from a music controller's browse.
    ///
    /// `upnp:class` is a standard ContentDirectory attribute every server
    /// publishes, so item-level filtering is reliable: `videoItem` and
    /// `imageItem` subtrees are defined by the spec and cannot be audio.
    /// Containers are kept — general-purpose servers (Synology included) tag
    /// photo and video FOLDERS as plain `storageFolder`, indistinguishable
    /// from music folders by class alone; those are handled by the root-level
    /// emptiness probe in `browseRoot` instead.
    private static func isAudioRelevant(_ item: BrowseItem) -> Bool {
        guard !item.isContainer, let raw = item.rawUPnPClass else { return true }
        return !raw.contains("videoItem") && !raw.contains("imageItem")
    }

    /// Root browse with pruning. Each top-level container's first page of
    /// children decides its fate:
    ///   - nothing at all → dropped (Synology answers photo/video subtrees
    ///     empty on this browse profile);
    ///   - any audio signal (audio item, music album/artist/genre/playlist
    ///     container) → kept;
    ///   - only image/video signals → dropped (minidlna-style servers return
    ///     populated Pictures/Video trees whose items are class-tagged);
    ///   - only generic folders → kept. Fail-open: hiding real music behind a
    ///     generic folder costs more than showing a stray section.
    /// One extra count-10 browse per root container, root page only.
    public static func browseRoot(server: MediaServer,
                                  soap: SOAPClient = SOAPClient()) async -> [BrowseItem] {
        guard let entries = try? await browse(server: server, objectID: "0", soap: soap) else { return [] }
        var kept: [BrowseItem] = []
        await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, entry) in entries.enumerated() {
                guard entry.isContainer else { kept.append(entry); continue }
                group.addTask {
                    let children = (try? await browse(server: server, objectID: entry.objectID,
                                                      start: 0, count: 10, soap: soap)) ?? []
                    return (index, subtreeLooksAudio(children))
                }
            }
            var verdicts: [Int: Bool] = [:]
            for await (index, keep) in group { verdicts[index] = keep }
            for (index, entry) in entries.enumerated() where verdicts[index] == true {
                kept.append(entry)
            }
        }
        return kept.sorted { a, b in
            (entries.firstIndex(where: { $0.id == a.id }) ?? 0)
                < (entries.firstIndex(where: { $0.id == b.id }) ?? 0)
        }
    }

    /// Verdict for one root container from its first page of children.
    static func subtreeLooksAudio(_ children: [BrowseItem]) -> Bool {
        guard !children.isEmpty else { return false }
        var sawVisual = false
        var sawGeneric = false
        for child in children {
            let raw = child.rawUPnPClass ?? ""
            if raw.contains("audioItem") || raw.contains("audioBroadcast")
                || raw.contains("musicAlbum") || raw.contains("musicArtist")
                || raw.contains("musicGenre") || raw.contains("playlistContainer") {
                return true
            }
            if raw.contains("videoItem") || raw.contains("imageItem")
                || raw.contains("photoAlbum") || raw.contains("videoContainer")
                || raw.contains("photoContainer") {
                sawVisual = true
            } else {
                sawGeneric = true
            }
        }
        // No direct audio signal: visual-only pages are dropped, anything
        // with generic folders stays reachable.
        return sawGeneric || !sawVisual
    }

    /// Media-server tracks play by handing the speaker the server's own URL,
    /// which is the strategy Suno and TIDAL already use. Containers are left
    /// alone so they still browse.
    private static func markAsDirectHTTP(_ item: BrowseItem) -> BrowseItem {
        guard !item.isContainer,
              let uri = item.resourceURI,
              uri.hasPrefix("http://") || uri.hasPrefix("https://")
        else { return item }
        var copy = item
        copy.playbackStrategy = .directHTTPSQueue
        // The queue add sends this DIDL verbatim. A server's own DIDL uses its
        // object ids and container parents, which the speaker will not accept,
        // so a track DIDL is built from the fields instead — including the art
        // URL, which is otherwise lost and leaves Now Playing hunting the web
        // for a cover the server was already serving.
        let mediaType: String
        let lowered = uri.lowercased()
        if lowered.contains(".flac") { mediaType = "flac" }
        else if lowered.contains(".m4a") || lowered.contains(".mp4") { mediaType = "mp4" }
        else if lowered.contains(".aac") { mediaType = "aac" }
        else if lowered.contains(".ogg") { mediaType = "ogg" }
        else if lowered.contains(".wav") { mediaType = "wav" }
        else { mediaType = "mp3" }
        copy.resourceMetadata = ServiceSearchProvider.shared.buildDirectHTTPTrackDIDL(
            title: item.title, artist: item.artist ?? "", url: uri,
            mediaType: mediaType, albumArtURI: item.albumArtURI)
        return copy
    }
}

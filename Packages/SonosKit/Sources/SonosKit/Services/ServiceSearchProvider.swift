/// ServiceSearchProvider.swift — Searches public music APIs and constructs Sonos-playable BrowseItems.
///
/// Uses iTunes Search API (free, no auth) to find tracks and albums on Apple Music.
/// Results are returned as BrowseItems with x-sonos-http URIs that the speaker can play
/// if Apple Music is connected via the Sonos app.
import Foundation

public final class ServiceSearchProvider {
    public static let shared = ServiceSearchProvider()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Apple Music (iTunes Search API)

    /// Search Apple Music for tracks via the iTunes Search API.
    /// Returns BrowseItems with constructed Sonos URIs ready for playback.
    public func searchAppleMusic(query: String, sn: Int, limit: Int = 25) async -> [BrowseItem] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&media=music&entity=song&limit=\(limit)") else {
            return []
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            let sid = ServiceID.appleMusic
            let serviceType = (sid << 8) + 7  // 52231

            return results.compactMap { result in
                guard let trackId = result["trackId"] as? Int,
                      let trackName = result["trackName"] as? String,
                      let artistName = result["artistName"] as? String else {
                    return nil
                }

                let albumName = result["collectionName"] as? String ?? ""
                let artURL = (result["artworkUrl100"] as? String)?
                    .replacingOccurrences(of: "100x100", with: "600x600")

                // Construct Sonos-compatible URI
                let resourceURI = "x-sonos-http:song%3a\(trackId).mp4?sid=\(sid)&flags=8224&sn=\(sn)"

                // Build DIDL metadata
                let escapedTitle = xmlEscape(trackName)
                let escapedArtist = xmlEscape(artistName)
                let escapedAlbum = xmlEscape(albumName)
                let metadata = """
                <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="00032020song%3a\(trackId)" parentID="0004206calbum%3a\(result["collectionId"] as? Int ?? 0)" restricted="true"><dc:title>\(escapedTitle)</dc:title><dc:creator>\(escapedArtist)</dc:creator><upnp:album>\(escapedAlbum)</upnp:album><upnp:class>object.item.audioItem.musicTrack</upnp:class><desc id="cdudn" nameSpace="urn:schemas-rinconnetworks-com:metadata-1-0/">SA_RINCON\(serviceType)_X_#Svc\(serviceType)-0-Token</desc></item></DIDL-Lite>
                """

                return BrowseItem(
                    id: "apple:\(trackId)",
                    title: trackName,
                    artist: artistName,
                    album: albumName,
                    albumArtURI: artURL,
                    itemClass: .musicTrack,
                    resourceURI: resourceURI,
                    resourceMetadata: metadata
                )
            }
        } catch {
            sonosDebugLog("[SERVICE_SEARCH] Apple Music search failed: \(error)")
            return []
        }
    }

    // MARK: - Helpers

    private func xmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

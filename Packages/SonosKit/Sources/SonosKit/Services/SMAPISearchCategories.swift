/// SMAPISearchCategories.swift — Which search id a service actually answers to.
///
/// `search` takes a category id, and the ids are per service: most answer
/// to the generic `track` / `album` / `artist`, but a service is free to
/// publish its own in its presentation map. Amazon Music publishes
/// `catalog:tracks:search`, `catalog:albums:search`,
/// `catalog:artists:search` and `catalog:universal:search`, and answers a
/// generic id with an EMPTY result rather than a fault — so asking the
/// wrong question looks exactly like a search that found nothing.
///
/// The categories come from the service (`getMetadata` on `search`) and
/// are cached in UserDefaults, shared with the Browse window so one
/// discovery serves both.
import Foundation

public enum SMAPISearchCategories {

    /// What the caller wants to find, independent of any service's naming.
    public enum Kind: String, Sendable {
        case tracks, albums, artists
        /// Ids a service is likely to use for this kind, most specific
        /// first. Matched against the service's published ids as a
        /// case-insensitive substring, so `catalog:tracks:search`,
        /// `tracks` and `track` all resolve for `.tracks`.
        var tokens: [String] {
            switch self {
            case .tracks: return ["track"]
            case .albums: return ["album"]
            case .artists: return ["artist"]
            }
        }
        /// The id used when a service publishes nothing recognisable.
        var genericID: String {
            switch self {
            case .tracks: return "track"
            case .albums: return "album"
            case .artists: return "artist"
            }
        }
    }

    /// Ids that search everything at once. Worth trying after a
    /// type-specific category comes back empty: Amazon's own tracks
    /// category returns nothing for terms its universal category matches.
    /// `all` is matched whole, not as a substring, so an id that merely
    /// contains those letters cannot pose as the catch-all.
    static let universalTokens = ["universal"]
    static let universalExactIDs = ["all"]

    public static func cacheKey(serviceID: Int) -> String { "smapiSearchCategories_\(serviceID)" }

    public static func cached(serviceID: Int) -> [(id: String, title: String)] {
        let raw = UserDefaults.standard.array(forKey: cacheKey(serviceID: serviceID)) as? [[String: String]]
        return (raw ?? []).compactMap { entry in
            guard let id = entry["id"], let title = entry["title"] else { return nil }
            return (id, title)
        }
    }

    public static func store(_ categories: [(id: String, title: String)], serviceID: Int) {
        guard !categories.isEmpty else { return }
        UserDefaults.standard.set(categories.map { ["id": $0.id, "title": $0.title] },
                                  forKey: cacheKey(serviceID: serviceID))
    }

    // MARK: - Categories a service publishes but does not answer

    /// A service can list a category it never fills: Amazon Music publishes
    /// `catalog:tracks:search` and returns an empty result for every term on
    /// an account whose albums and universal categories match that same
    /// term. The only evidence is observed behaviour, so the Browse "All"
    /// fan-out — one term sent to every category — records it: an id that
    /// returned nothing while another returned at least `evidenceThreshold`
    /// rows is hidden from the category chips. The fan-out keeps querying
    /// hidden ids and rewrites the set each time, so a category that starts
    /// answering reappears on the next search, and a term that matched
    /// nothing anywhere changes nothing.
    public static let evidenceThreshold = 5

    public static func emptyKey(serviceID: Int) -> String { "smapiEmptySearchIDs_\(serviceID)" }

    public static func emptySearchIDs(serviceID: Int) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: emptyKey(serviceID: serviceID)) ?? [])
    }

    /// `counts` is the row count each category returned for one term.
    public static func recordFanOut(serviceID: Int, counts: [String: Int]) {
        guard let best = counts.values.max(), best >= evidenceThreshold else { return }
        let empty = counts.filter { $0.value == 0 }.keys.sorted()
        UserDefaults.standard.set(empty, forKey: emptyKey(serviceID: serviceID))
    }

    /// The service's categories, from cache when present and from the
    /// service otherwise. A discovery failure is not an error: the
    /// generic ids are the fallback, and they work for most services.
    public static func resolve(serviceID: Int, serviceURI: String,
                               token: SMAPIToken) async -> [(id: String, title: String)] {
        let known = cached(serviceID: serviceID)
        if !known.isEmpty { return known }
        guard let discovered = try? await SMAPIClient.shared.getSearchCategories(serviceURI: serviceURI, token: token),
              !discovered.isEmpty else { return [] }
        store(discovered, serviceID: serviceID)
        return discovered
    }

    /// The ids to try for `kind`, in order: the service's own category
    /// for that kind, then its search-everything category, then the
    /// generic id. Never empty, and never repeats an id.
    public static func searchIDs(for kind: Kind,
                                 in categories: [(id: String, title: String)]) -> [String] {
        var ordered: [String] = []
        func add(_ id: String) {
            guard !ordered.contains(where: { $0.caseInsensitiveCompare(id) == .orderedSame }) else { return }
            ordered.append(id)
        }
        func firstMatching(_ tokens: [String]) -> String? {
            categories.first { category in
                tokens.contains { category.id.range(of: $0, options: .caseInsensitive) != nil }
            }?.id
        }
        if let specific = firstMatching(kind.tokens) { add(specific) }
        if let universal = firstMatching(universalTokens)
            ?? categories.first(where: { category in
                universalExactIDs.contains { category.id.caseInsensitiveCompare($0) == .orderedSame }
            })?.id {
            add(universal)
        }
        add(kind.genericID)
        return ordered
    }
}

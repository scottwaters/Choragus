import Foundation

/// Sort orders for a browse or search result list. The set offered
/// depends on the rows: relevance and title are always there; artist
/// appears only when some row names an artist, and newest and oldest
/// only when some row carries a release date or year, so a list that
/// cannot be sorted a given way does not offer it.
public enum BrowseSortOption: String, CaseIterable, Hashable, Sendable {
    /// The order the source returned.
    case relevance
    case titleAscending
    case titleDescending
    case artistAscending
    case artistDescending
    case newest
    case oldest

    public var label: String {
        switch self {
        case .relevance:        return L10n.sortRelevance
        case .titleAscending:   return L10n.sortTitleAscending
        case .titleDescending:  return L10n.sortTitleDescending
        case .artistAscending:  return L10n.sortArtistAscending
        case .artistDescending: return L10n.sortArtistDescending
        case .newest:           return L10n.sortNewest
        case .oldest:           return L10n.sortOldest
        }
    }

    /// The options that make sense for `items`, in menu order.
    public static func available(for items: [BrowseItem]) -> [BrowseSortOption] {
        var out: [BrowseSortOption] = [.relevance, .titleAscending, .titleDescending]
        if items.contains(where: { !$0.artist.isEmpty }) {
            out += [.artistAscending, .artistDescending]
        }
        if items.contains(where: { $0.releaseDate != nil || $0.releaseYear != nil }) {
            out += [.newest, .oldest]
        }
        return out
    }

    /// `items` in this order. Stable: rows that compare equal keep their
    /// source order. Rows without a date sort after dated rows in both
    /// year orders. Artist orders break ties on title.
    public func apply(_ items: [BrowseItem]) -> [BrowseItem] {
        if self == .relevance { return items }
        let indexed = Array(items.enumerated())
        func text(_ a: String, _ b: String) -> ComparisonResult { a.localizedCaseInsensitiveCompare(b) }
        func year(_ item: BrowseItem) -> Double? {
            if let date = item.releaseDate { return date.timeIntervalSince1970 }
            if let year = item.releaseYear { return Double(year) * 366 * 86_400 }
            return nil
        }
        let sorted = indexed.sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            var result: ComparisonResult
            switch self {
            case .relevance:
                result = .orderedSame
            case .titleAscending:
                result = text(a.title, b.title)
            case .titleDescending:
                result = text(b.title, a.title)
            case .artistAscending:
                result = text(a.artist, b.artist)
                if result == .orderedSame { result = text(a.title, b.title) }
            case .artistDescending:
                result = text(b.artist, a.artist)
                if result == .orderedSame { result = text(a.title, b.title) }
            case .newest, .oldest:
                switch (year(a), year(b)) {
                case (nil, nil): result = .orderedSame
                case (nil, _): result = .orderedDescending
                case (_, nil): result = .orderedAscending
                case (let x?, let y?):
                    result = x == y ? .orderedSame
                        : ((self == .newest ? x > y : x < y) ? .orderedAscending : .orderedDescending)
                }
            }
            if result == .orderedSame { return lhs.offset < rhs.offset }
            return result == .orderedAscending
        }
        return sorted.map(\.element)
    }
}

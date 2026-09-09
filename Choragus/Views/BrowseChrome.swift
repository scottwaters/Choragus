/// BrowseChrome.swift — Chrome shared by every browse and search list:
/// the drill-down back bar and the bulk-action bar. One implementation
/// so the services read the same wherever the functionality matches.
import SwiftUI
import SonosKit

/// Back bar for a drilled-in level: chevron plus the level's title.
struct BrowseBackBar: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Play All / Add All to Queue / Play Next over the current list, with
/// a localised item count. Buttons disable while an action is in flight
/// so a double click cannot enqueue a list twice.
struct BrowseBulkActionBar: View {
    let count: Int
    var inFlight: Bool = false
    let playAll: () -> Void
    let addAll: () -> Void
    let playNext: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: playAll) { Label(L10n.playAll, systemImage: "play.fill") }
                .controlSize(.small)
            Button(action: addAll) { Label(L10n.addAllToQueue, systemImage: "text.append") }
                .controlSize(.small)
            Button(action: playNext) { Label(L10n.playNext, systemImage: "text.insert") }
                .controlSize(.small)
            if inFlight {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Text(L10n.itemsCount(count))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .disabled(inFlight)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

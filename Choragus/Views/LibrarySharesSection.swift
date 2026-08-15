/// LibrarySharesSection.swift — network folders each Sonos system indexes
/// as local music (#75). Read-only: `CreateObject` on the `S:` container
/// answers HTTP 200 and persists nothing (verified on S1 and S2, both DIDL
/// shapes), so adding and removing shares stays in the Sonos app.
import SwiftUI
import SonosKit

struct LibrarySharesSection: View {
    @EnvironmentObject var sonosManager: SonosManager

    @State private var shares: [SonosManager.LibraryShare] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.librarySharesHeader)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            if isLoading {
                ProgressView().controlSize(.small)
            } else if shares.isEmpty {
                Text(L10n.noLibrarySharesConfigured)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(shares) { share in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(share.path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // S1 and S2 index the same path separately; without
                        // the tag the two rows are indistinguishable.
                        if sonosManager.hasMultipleSystems {
                            Text(share.systemVersion.displayLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
                                )
                        }
                        Spacer()
                    }
                    .help(share.coordinatorRoom)
                }
            }

            Text(L10n.libraryShareHint)
                .font(.callout)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await reload() }
    }

    private func reload() async {
        isLoading = true
        shares = await sonosManager.libraryShares()
        isLoading = false
    }
}

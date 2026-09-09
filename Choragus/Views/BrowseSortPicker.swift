/// BrowseSortPicker.swift — The one sort control every browse and
/// search list uses. Offers only the orders that apply to the rows on
/// screen (see `BrowseSortOption.available`) and falls back to the
/// source order when the chosen one stops applying.
import SwiftUI
import SonosKit

struct BrowseSortPicker: View {
    let items: [BrowseItem]
    @Binding var selection: BrowseSortOption

    private var options: [BrowseSortOption] { BrowseSortOption.available(for: items) }

    var body: some View {
        HStack(spacing: 4) {
            Text(L10n.sortLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 160)
            .languageReactive()
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onChange(of: options) {
            if !options.contains(selection) { selection = .relevance }
        }
    }
}

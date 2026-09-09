/// LineInBrowseView.swift — Lists speakers that have analog or TV inputs.
///
/// Tapping a speaker plays its input through the currently-selected
/// group. Discovery, URI and DIDL live in `PhysicalInput` (SonosKit),
/// shared with the Select Input Shortcuts intent.
import SwiftUI
import SonosKit
import AppKit

struct LineInBrowseView: View {
    @Environment(SonosManager.self) private var sonosManager
    let group: SonosGroup?

    @State private var playError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.lineInSources).font(.subheadline.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if let err = playError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.85))
            }

            let inputs = PhysicalInput.inputs(in: sonosManager.devices)
            if inputs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector").font(.title2).foregroundStyle(.tertiary)
                    Text(L10n.noSpeakersWithLineInOrTV)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                List {
                    ForEach(inputs) { input in
                        Button { play(input) } label: {
                            row(for: input)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - Row

    private func row(for input: PhysicalInput) -> some View {
        HStack(spacing: 10) {
            Image(systemName: input.kind == .tv ? "tv.fill" : "cable.connector.horizontal")
                .frame(width: 30, height: 30)
                .foregroundStyle(input.kind == .tv ? .blue : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(input.roomName).font(.body).lineLimit(1)
                Text("\(input.modelName)  •  \(input.kind == .tv ? L10n.lineInTVInput : L10n.lineInAnalogInput)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Playback

    private func play(_ input: PhysicalInput) {
        guard let group = group else {
            playError = L10n.noSpeakerGroupSelected
            return
        }
        playError = nil
        Task {
            do {
                try await sonosManager.playInput(input, in: group)
            } catch {
                playError = L10n.couldNotStartInputFormat(input.title, error.localizedDescription)
                sonosDebugLog("[LINEIN] play failed for \(input.deviceID): \(error)")
            }
        }
    }
}

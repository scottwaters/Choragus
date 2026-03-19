import SwiftUI
import SonosKit

struct EQView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let device: SonosDevice

    @State private var bass: Double = 0
    @State private var treble: Double = 0
    @State private var loudness: Bool = false
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("EQ: \(device.roomName)")
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Bass")
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $bass, in: -10...10, step: 1) { editing in
                        if !editing { Task { await saveBass() } }
                    }
                    Text("\(Int(bass))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }

                HStack {
                    Text("Treble")
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $treble, in: -10...10, step: 1) { editing in
                        if !editing { Task { await saveTreble() } }
                    }
                    Text("\(Int(treble))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }

                Toggle("Loudness", isOn: $loudness)
                    .onChange(of: loudness) {
                        Task { await saveLoudness() }
                    }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 320, height: 220)
        .onAppear { Task { await loadEQ() } }
    }

    private func loadEQ() async {
        do {
            bass = Double(try await sonosManager.getBass(device: device))
            treble = Double(try await sonosManager.getTreble(device: device))
            loudness = try await sonosManager.getLoudness(device: device)
            isLoading = false
        } catch {
            print("Failed to load EQ: \(error)")
        }
    }

    private func saveBass() async {
        try? await sonosManager.setBass(device: device, bass: Int(bass))
    }

    private func saveTreble() async {
        try? await sonosManager.setTreble(device: device, treble: Int(treble))
    }

    private func saveLoudness() async {
        try? await sonosManager.setLoudness(device: device, enabled: loudness)
    }
}

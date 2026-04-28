import SwiftUI
import SonosKit

struct SleepTimerView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @Environment(\.dismiss) private var dismiss
    let group: SonosGroup

    @State private var remaining: String = ""
    @State private var isActive = false

    private var presets: [(String, String)] {[
        (L10n.min15, "0:15:00"),
        (L10n.min30, "0:30:00"),
        (L10n.min45, "0:45:00"),
        (L10n.hour1, "1:00:00"),
        (L10n.hours2, "2:00:00"),
    ]}

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.sleepTimer)
                .font(.headline)

            Divider()

            if isActive {
                VStack(spacing: 8) {
                    Text(L10n.timeRemaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(remaining)
                        .font(.title)
                        .monospacedDigit()

                    Button(L10n.cancelTimer) {
                        Task {
                            try? await sonosManager.cancelSleepTimer(group: group)
                            isActive = false
                            remaining = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(presets, id: \.0) { preset in
                        Button(preset.0) {
                            Task {
                                try? await sonosManager.setSleepTimer(group: group, duration: preset.1)
                                remaining = preset.1
                                isActive = true
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button(L10n.done) { dismiss() }
                    .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 240, height: 320)
        .onAppear { Task { await checkTimer() } }
    }

    private func checkTimer() async {
        do {
            let rem = try await sonosManager.getSleepTimerRemaining(group: group)
            if !rem.isEmpty && rem != "0:00:00" {
                remaining = rem
                isActive = true
            }
        } catch {
            // no timer active
        }
    }
}

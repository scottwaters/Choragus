/// SettingsView.swift — App preferences: startup mode, cache management, artwork limits.
///
/// Startup mode controls whether the app uses cached topology (Quick Start) or waits
/// for live SSDP discovery (Classic). Artwork cache settings let users configure
/// max disk size and expiry age for the ImageCache LRU eviction.
import SwiftUI
import SonosKit

struct SettingsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.title)
                    .fontWeight(.bold)

                // Startup Mode
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Startup Mode")
                            .font(.headline)

                        Picker("", selection: $sonosManager.startupMode) {
                            ForEach(StartupMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if sonosManager.startupMode == .quickStart {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Instant startup", systemImage: "bolt.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)

                                Text("Your speaker layout and browse menu are saved locally when the app closes. On next launch, the UI appears instantly from this saved state while speakers are verified in the background.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)

                                Text("If a speaker has moved, gone offline, or groups have changed since the last session, you'll see a brief notification and the list will refresh automatically. Any action on a stale speaker will gracefully retry.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Live discovery", systemImage: "wifi")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.accentColor)

                                Text("The app waits for live network discovery to complete before showing any speakers. This takes a few seconds but guarantees the speaker list is always current.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)

                                Text("Use this mode if your Sonos setup changes frequently (speakers added/removed, IP addresses changing) and you prefer accuracy over speed.")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(4)
                }

                // Cache Status
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Cache Status")
                            .font(.headline)

                        if sonosManager.isUsingCachedData {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title3)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading) {
                                    Text("Using cached data")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Last saved \(sonosManager.cacheAge). Background refresh in progress.")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading) {
                                    Text("Live data")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("All speakers verified and up to date.")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Clear Speaker Cache") {
                                sonosManager.clearCache()
                            }
                            Button("Clear Artwork Cache") {
                                ImageCache.shared.clearDisk()
                                ImageCache.shared.clearMemory()
                            }
                        }

                        Text("Speaker cache stores your room layout for instant startup. Artwork cache stores album art for faster browsing. Both rebuild automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                // Artwork Cache Settings
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Artwork Cache")
                            .font(.headline)

                        HStack {
                            Text("Current usage:")
                                .font(.body)
                            Text("\(ImageCache.shared.diskUsageString) (\(ImageCache.shared.fileCount) images)")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Max size")
                                .frame(width: 80, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { ImageCache.shared.maxSizeMB },
                                set: { ImageCache.shared.maxSizeMB = $0 }
                            )) {
                                Text("100 MB").tag(100)
                                Text("250 MB").tag(250)
                                Text("500 MB").tag(500)
                                Text("1 GB").tag(1024)
                                Text("2 GB").tag(2048)
                                Text("5 GB").tag(5120)
                            }
                            .frame(width: 140)
                        }

                        HStack {
                            Text("Max age")
                                .frame(width: 80, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { ImageCache.shared.maxAgeDays },
                                set: { ImageCache.shared.maxAgeDays = $0 }
                            )) {
                                Text("7 days").tag(7)
                                Text("14 days").tag(14)
                                Text("30 days").tag(30)
                                Text("90 days").tag(90)
                                Text("1 year").tag(365)
                                Text("Never").tag(99999)
                            }
                            .frame(width: 140)
                        }

                        Text("Images older than the max age are removed automatically. If total size exceeds the limit, the oldest images are removed first.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding(28)
        }
        .frame(width: 520, height: 540)
        .overlay(alignment: .bottomTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.return)
                .padding(24)
        }
    }
}

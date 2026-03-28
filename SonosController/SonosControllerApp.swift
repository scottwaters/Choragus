/// SonosControllerApp.swift — App entry point.
///
/// Creates the SonosManager singleton and injects it into the SwiftUI environment.
/// Discovery begins immediately on appear so speakers populate while the window loads.
/// Applies the user's appearance preference. Accent color is applied per-view,
/// not on the whole window, to avoid tinting toolbar icons.
import SwiftUI
import SonosKit

/// Build timestamp for version validation in title bar
let buildTimestamp: String = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(buildEpoch)))
}()
// Computed at compile time via __DATE__ and __TIME__ equivalent
private let buildEpoch: Int = {
    // Use file modification date of the compiled binary as build time proxy
    let bundlePath = Bundle.main.executablePath ?? ""
    let attrs = try? FileManager.default.attributesOfItem(atPath: bundlePath)
    let date = attrs?[.modificationDate] as? Date ?? Date()
    return Int(date.timeIntervalSince1970)
}()

@main
struct SonosControllerApp: App {
    @StateObject private var sonosManager = SonosManager()
    @StateObject private var presetManager = PresetManager()
    @StateObject private var playHistoryManager = PlayHistoryManager()
    @StateObject private var playlistScanner = PlaylistServiceScanner()
    @StateObject private var smapiManager = SMAPIAuthManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sonosManager)
                .environmentObject(presetManager)
                .environmentObject(playHistoryManager)
                .environmentObject(playlistScanner)
                .environmentObject(smapiManager)
                .onAppear {
                    sonosManager.playHistoryManager = playHistoryManager
                    sonosManager.startDiscovery()
                    MenuBarController.shared.setup(sonosManager: sonosManager)
                    // Load SMAPI services if enabled
                    if smapiManager.isEnabled, let speaker = sonosManager.groups.first?.coordinator {
                        Task { await smapiManager.loadServices(speakerIP: speaker.ip, musicServicesList: sonosManager.musicServicesList) }
                    }
                    WindowManager.shared.playHistoryManager = playHistoryManager
                    WindowManager.shared.sonosManager = sonosManager
                    WindowManager.shared.colorScheme = colorScheme
                }
                .onChange(of: sonosManager.appearanceMode) {
                    WindowManager.shared.colorScheme = colorScheme
                }
                .frame(minWidth: 700, minHeight: 450)
                .navigationTitle("SonosController — build \(buildTimestamp)")
                .preferredColorScheme(colorScheme)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 550)
        .commands {
            // Hide default menus — only the system app menu ("SonosController") remains
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {}
            CommandGroup(replacing: .pasteboard) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(replacing: .windowSize) {}
            CommandGroup(replacing: .windowList) {}
            CommandGroup(replacing: .help) {}
        }
    }

    private var colorScheme: ColorScheme? {
        switch sonosManager.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

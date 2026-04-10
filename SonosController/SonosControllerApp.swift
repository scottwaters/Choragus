/// SonosControllerApp.swift — App entry point.
///
/// Creates the SonosManager singleton and injects it into the SwiftUI environment.
/// Discovery begins immediately on appear so speakers populate while the window loads.
/// Applies the user's appearance preference. Accent color is applied per-view,
/// not on the whole window, to avoid tinting toolbar icons.
import SwiftUI
import SonosKit


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
                .frame(minWidth: 640, minHeight: 450)
                .navigationTitle("The SonosController")
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

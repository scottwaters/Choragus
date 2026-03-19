/// SonosControllerApp.swift — App entry point.
///
/// Creates the SonosManager singleton and injects it into the SwiftUI environment.
/// Discovery begins immediately on appear so speakers populate while the window loads.
import SwiftUI
import SonosKit

@main
struct SonosControllerApp: App {
    @StateObject private var sonosManager = SonosManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sonosManager)
                .onAppear {
                    sonosManager.startDiscovery()
                }
                .frame(minWidth: 700, minHeight: 450)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 550)
    }
}

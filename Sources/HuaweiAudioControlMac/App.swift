import AppKit
import SwiftUI

/// Handles the process lifecycle the SwiftUI scene graph can't reach, most
/// importantly releasing the earbuds' serial channel on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // The earbuds keep a stale session if the channel is abandoned, so the
        // channel must always be closed explicitly.
        AppState.state.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Owns the long-lived objects shared across scenes.
@MainActor
enum AppState {
    static let state = DeviceState()
    static let settings = AppSettings()
}

@main
struct HuaweiAudioControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.state
    @ObservedObject private var settings = AppState.settings

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(state)
                .environmentObject(settings)
        } label: {
            MenuBarIcon(connected: state.isConnected,
                        battery: settings.showBatteryInMenuBar
                            ? state.snapshot.weakestBud : nil,
                        name: state.snapshot.modelName)
        }
        .menuBarExtraStyle(.window)

        Window(AppSettings.windowID, id: AppSettings.windowID) {
            SettingsView()
                .environmentObject(AppState.settings)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: Theme.settingsWidth, height: Theme.settingsHeight)
        .windowStyle(.hiddenTitleBar)
    }
}

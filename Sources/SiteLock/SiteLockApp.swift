import AppKit
import SwiftUI

@main
struct SiteLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SiteLock") {
            ContentView()
                .environmentObject(model)
                .frame(width: 440, height: 520)
        }
        .windowResizability(.contentSize)
    }
}

/// The app is only opened to edit the list; closing the window quits it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

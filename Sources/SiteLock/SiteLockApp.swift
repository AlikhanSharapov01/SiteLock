import AppKit
import SiteLockCore
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
        .commands {
            CommandGroup(after: .importExport) {
                Button("Import List…") { Task { await model.importList() } }
                    .disabled(model.screen != .unlocked || model.busy)
                Button("Export List…") { model.exportList() }
                    .disabled(model.screen != .unlocked)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.showingUpdates = true }
                Button("Uninstall SiteLock…") { model.showingUninstall = true }
            }
        }
    }
}

/// The app is only opened to edit the list; closing the window quits it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

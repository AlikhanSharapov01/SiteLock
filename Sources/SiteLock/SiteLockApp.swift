import AppKit
import ServiceManagement
import SiteLockCore
import SwiftUI

@main
struct SiteLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.status?.unblocks.isEmpty == false ? "lock.open" : "lock.shield")
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("SiteLock", id: "main") {
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

/// The app lives in the menu bar: no Dock icon while no SiteLock window is visible.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { _ in
            NSApp.setActivationPolicy(.regular)
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // The closing window is still visible during this notification: look one turn later.
            DispatchQueue.main.async {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var statusLine: String {
        guard let status = model.status else { return "SiteLock is not installed" }
        guard status.initialized else { return "Set a password in SiteLock" }
        let names = Browser.catalog.filter { status.browsers.contains($0.id) }.map(\.name)
        let sites = status.domainCount == 1 ? "1 site" : "\(status.domainCount) sites"
        return names.isEmpty ? "Not blocking in any browser" : "Blocking \(sites) in \(names.joined(separator: ", "))"
    }

    var body: some View {
        Text(statusLine)
        if let unblocks = model.status?.unblocks {
            ForEach(unblocks.sorted { $0.value < $1.value }, id: \.key) { domain, until in
                Text("\(domain) — until \(until.formatted(date: .omitted, time: .shortened))")
                Button("Re-block \(domain) now") { Task { await model.reblockNow(domain) } }
            }
        }
        Divider()
        Button("Open SiteLock…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Toggle("Open at Login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
        if let error = model.launchAtLoginError { Text(error) }
        Divider()
        Button("Quit SiteLock") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .onAppear {
                launchAtLogin = SMAppService.mainApp.status == .enabled
                Task { await model.refreshStatus() }
            }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            model.launchAtLoginError = nil
        } catch {
            model.launchAtLoginError = "Open at Login failed: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

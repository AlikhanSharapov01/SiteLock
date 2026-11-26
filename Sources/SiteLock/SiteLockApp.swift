import AppKit
import ServiceManagement
import SiteLockCore
import SwiftUI

@main
struct SiteLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.menu)

        Window("SiteLock", id: "main") {
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
                Button("Report a Problem…") { model.reportProblem() }
                Button("Uninstall SiteLock…") { model.showingUninstall = true }
            }
        }
    }
}

struct MenuBarIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let unblocked = model.status?.unblocks.values.contains { $0 > Date() } == true
        Image(systemName: unblocked ? "lock.open" : "lock.shield")
    }
}

/// The app lives in the menu bar: no Dock icon while no SiteLock window is visible.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var launchedAtLogin = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started by "Open at Login": stay in the menu bar, no window. Unverified for SMAppService
        // launches; if the Apple Event is not the login-item one the window simply opens as usual.
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
                == OSType(keyAELaunchedAsLogInItem)

        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            Task { @MainActor in
                guard let self else { return }
                if self.launchedAtLogin {
                    self.launchedAtLogin = false
                    window?.close()
                    NSApp.setActivationPolicy(.accessory)
                } else {
                    NSApp.setActivationPolicy(.regular)
                }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? NSWindow)?.canBecomeMain == true else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.model.screen == .unlocked { self.model.lock() }
                // The closing window may still count as visible this turn: check once more.
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
        if model.serviceOutdated { return "Update the background service in SiteLock" }
        guard let status = model.status else {
            return "SiteLock is not installed"
        }
        if !model.reachable { return "SiteLock is not reachable" }
        guard status.initialized else { return "Set a password in SiteLock" }
        let names = Browser.catalog.filter { status.browsers.contains($0.id) }.map(\.name)
        let sites = status.domainCount == 1 ? "1 site" : "\(status.domainCount) sites"
        return names.isEmpty ? "Not blocking in any browser" : "Blocking \(sites) in \(names.joined(separator: ", "))"
    }

    var body: some View {
        Text(statusLine)
        if let unblocks = model.status?.unblocks.filter({ $0.value > Date() }) {
            ForEach(unblocks.sorted { $0.value < $1.value }, id: \.key) { domain, until in
                Text("\(domain) — until \(until.formatted(date: .omitted, time: .shortened))")
                Button("Re-block \(domain) now") { Task { await model.reblockNow(domain) } }
            }
        }
        if let error = model.error { Text(error) }
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

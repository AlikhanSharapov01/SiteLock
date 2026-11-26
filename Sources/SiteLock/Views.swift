import AppKit
import SwiftUI
import SiteLockCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .connecting:
                ProgressView("Connecting to SiteLock…")
            case .unreachable(let reason):
                UnreachableView(reason: reason)
            case .setup:
                SetupView()
            case .locked:
                UnlockView()
            case .unlocked:
                BlocklistView()
            case .removed:
                RemovedView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) {
            if model.updateAvailable && model.screen != .removed { UpdateBanner() }
        }
        .sheet(isPresented: $model.showingUninstall) { UninstallSheet() }
        .sheet(isPresented: $model.showingUpdates) { UpdatesSheet() }
        .task { await model.connect() }
        // The app keeps running in the menu bar after the window closes: forget the password.
        .onDisappear { if model.screen == .unlocked { model.lock() } }
    }
}

/// Shown when the running service is a different version than the one inside this app.
struct UpdateBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack {
            Text("The installed service is \(model.installedVersion.map { "version \($0)" } ?? "an older version"); this app has \(SiteLockVersion.current).")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Update") { Task { await model.install() } }
                .disabled(model.busy)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.12))
    }
}

struct UninstallSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstall SiteLock")
                .font(.headline)
            Text("Removes the background service, the blocklist and your SiteLock password. Browsers stop blocking after they restart.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("SiteLock password", text: $password)
                .textFieldStyle(.roundedBorder)
            ErrorText(message: model.error)
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) {
                    model.error = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) {
                    Task { if await model.uninstall(password: password) { dismiss() } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || password.isEmpty)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear { model.error = nil }
    }
}

struct UpdatesSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Software Update")
                .font(.headline)
            switch model.updateCheck {
            case .idle, .checking:
                HStack { ProgressView().controlSize(.small); Text("Checking for updates…") }
            case .upToDate:
                Text("SiteLock \(SiteLockVersion.current) is the latest version.")
            case .available(let version):
                Text("SiteLock \(version) is available. You have \(SiteLockVersion.current).")
                Text("SiteLock downloads it, replaces this app and reopens. Then click Update to update the background service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .installing:
                HStack { ProgressView().controlSize(.small); Text("Downloading and installing…") }
            case .failed(let message):
                ErrorText(message: message)
            }
            HStack {
                Spacer()
                if case .failed = model.updateCheck {
                    Button("Try Again") { Task { await model.checkForUpdates() } }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.updateCheck == .installing)
                if case .available = model.updateCheck {
                    Button("Download and Install") { Task { await model.installUpdate() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 360)
        .task { await model.checkForUpdates() }
    }
}

struct RemovedView: View {
    var body: some View {
        VStack(spacing: 12) {
            AppIconView()
            Text("SiteLock was removed")
                .font(.title2)
            Text("Restart your browsers so they stop blocking. You can now move SiteLock.app to the Trash.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}

/// The app's own icon (Resources/AppIcon.icns), so the windows are recognisably SiteLock.
struct AppIconView: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }
}

/// Error text shown under a form; nothing when there is no error.
struct ErrorText: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct UnreachableView: View {
    @EnvironmentObject private var model: AppModel
    let reason: String

    var body: some View {
        VStack(spacing: 12) {
            AppIconView()
            Text("SiteLock is not installed")
                .font(.title2)
            Text("Install the background service that blocks sites in your browsers. macOS asks for an administrator password once.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            ErrorText(message: model.error)
            HStack {
                Button("Retry") { Task { await model.connect() } }
                Button("Install") { Task { await model.install() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
            }
        }
        .padding()
    }
}

struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AppIconView()
                Text("Set your SiteLock password")
                    .font(.title2)
            }
            Text("Use a new password, not your Mac login password. You will need it to change the blocklist, unblock a site or uninstall SiteLock. At least \(PasswordHasher.minimumLength) characters.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
            SecureField("Confirm password", text: $confirmation)
            ErrorText(message: model.error)
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Set Password") {
                    Task { await model.setup(password: password, confirmation: confirmation) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || password.isEmpty || confirmation.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
    }
}

struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @State private var password = ""

    var body: some View {
        VStack(spacing: 12) {
            AppIconView()
            Text("Enter your SiteLock password")
                .font(.title2)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit(unlock)
            ErrorText(message: model.error)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || password.isEmpty)
            }
            HStack(spacing: 16) {
                Button("Check for Updates…") { model.showingUpdates = true }
                Button("Uninstall SiteLock…") { model.showingUninstall = true }
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.top, 8)
        }
        .padding()
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        Task { await model.unlock(password: password) }
    }
}

struct BlocklistView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newDomain = ""
    @State private var customUnblockDomain: String?
    @State private var editDomain: String?
    @State private var removeDomain: String?
    @State private var changingPassword = false
    @State private var choosingBrowsers = false

    private var blockingSummary: String {
        let names = model.state.browsers.compactMap { Browser.byID($0)?.name }
        return names.isEmpty ? "Blocking in: no browser" : "Blocking in: " + names.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ErrorText(message: model.error)
            if let summary = model.importSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.state.domains.isEmpty {
                Text("No blocked sites yet. A site blocks its subdomains too: youtube.com also blocks music.youtube.com, while www.youtube.com blocks only YouTube itself.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Re-render every 15 s so "Unblocked until" turns back into "Blocked" on time.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    List(model.state.domains, id: \.self) { domain in
                        DomainRow(domain: domain,
                                  unblockedUntil: model.state.isTemporarilyUnblocked(domain, now: context.date)
                                      ? model.state.unblocks[domain] : nil,
                                  onUnblock: { minutes in Task { await model.unblock(domain, minutes: minutes) } },
                                  onCustomUnblock: { customUnblockDomain = domain },
                                  onReblock: { Task { await model.reblock(domain) } },
                                  onEdit: { editDomain = domain },
                                  onRemove: { removeDomain = domain })
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
            }

            HStack {
                Text(blockingSummary)
                    .font(.caption)
                    .foregroundStyle(model.state.browsers.isEmpty ? Color.red : Color.secondary)
                Spacer()
                Button("Browsers…") { choosingBrowsers = true }
            }

            HStack {
                Text("Changes quit and reopen the selected browsers so they load the new list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Menu {
                    Button("Check for Updates…") { model.showingUpdates = true }
                    Button("Browsers…") { choosingBrowsers = true }
                    Button("Import List…") { Task { await model.importList() } }
                        .disabled(model.busy)
                    Button("Export List…") { model.exportList() }
                    Button("Change Password…") { changingPassword = true }
                    Button("Report a Problem…") { model.reportProblem() }
                    Divider()
                    Button("Uninstall SiteLock…") { model.showingUninstall = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                Button("Lock") { model.lock() }
            }
        }
        .padding()
        .disabled(model.busy)
        .sheet(item: Binding(get: { editDomain.map(IdentifiedDomain.init) },
                             set: { editDomain = $0?.id })) { item in
            EditDomainSheet(domain: item.id)
        }
        .sheet(item: Binding(get: { customUnblockDomain.map(IdentifiedDomain.init) },
                             set: { customUnblockDomain = $0?.id })) { item in
            CustomUnblockSheet(domain: item.id) { minutes in
                Task { await model.unblock(item.id, minutes: minutes) }
            }
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordSheet() }
        .sheet(isPresented: $choosingBrowsers) { BrowsersSheet() }
        .confirmationDialog("Remove \(removeDomain ?? "") from the blocklist?",
                            isPresented: Binding(get: { removeDomain != nil }, set: { if !$0 { removeDomain = nil } })) {
            Button("Remove", role: .destructive) {
                if let domain = removeDomain { Task { await model.remove(domain) } }
            }
        }
    }

    private func add() {
        let domain = newDomain
        guard !domain.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { if await model.add(domain) { newDomain = "" } }
    }
}

struct BrowsersSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browsers")
                .font(.headline)
            ForEach(model.installedBrowsers) { browser in
                if browser.isSupported {
                    Toggle(browser.name, isOn: Binding(
                        get: { model.state.browsers.contains(browser.id) },
                        set: { enabled in Task { await model.setBrowser(browser.id, enabled: enabled) } }))
                        .disabled(model.busy)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(browser.name)
                            .foregroundStyle(.secondary)
                        Text(browser.unsupportedReason ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("Turning a browser on or off restarts it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ErrorText(message: model.error)
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Done") { model.error = nil; dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360)
    }
}

struct IdentifiedDomain: Identifiable {
    let id: String
}

struct DomainRow: View {
    static let presets = [5, 15, 30, 60, 120]

    let domain: String
    let unblockedUntil: Date?
    let onUnblock: (Int) -> Void
    let onCustomUnblock: () -> Void
    let onReblock: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(domain)
                if let until = unblockedUntil {
                    Text("Unblocked until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Blocked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if unblockedUntil != nil {
                Button("Re-block now", action: onReblock)
            } else {
                Menu("Unblock") {
                    ForEach(Self.presets, id: \.self) { minutes in
                        Button("For \(minutes) minutes") { onUnblock(minutes) }
                    }
                    Divider()
                    Button("Custom…", action: onCustomUnblock)
                }
                .fixedSize()
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit \(domain)")
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(domain)")
        }
        .padding(.vertical, 2)
    }
}

struct EditDomainSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let domain: String
    @State private var text = ""

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(domain)")
                .font(.headline)
            TextField("example.com", text: $text)
                .textFieldStyle(.roundedBorder)
            Text("The new entry blocks that host and its subdomains. A temporary unblock of \(domain) ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ErrorText(message: model.error)
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) {
                    model.error = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        if await model.edit(domain, to: trimmed) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || trimmed.isEmpty || trimmed.lowercased() == domain)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            text = domain
            model.error = nil
        }
    }
}

struct CustomUnblockSheet: View {
    @Environment(\.dismiss) private var dismiss
    let domain: String
    let onConfirm: (Int) -> Void
    @State private var text = "10"

    private var minutes: Int? {
        Int(text.trimmingCharacters(in: .whitespaces)).flatMap {
            (1...BlockState.maxUnblockMinutes).contains($0) ? $0 : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unblock \(domain)")
                .font(.headline)
            HStack {
                TextField("Minutes", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                Text("minutes (1–\(BlockState.maxUnblockMinutes))")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unblock") {
                    if let minutes { onConfirm(minutes) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(minutes == nil)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

struct ChangePasswordSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change SiteLock password")
                .font(.headline)
            SecureField("Current password", text: $current)
            SecureField("New password (at least \(PasswordHasher.minimumLength) characters)", text: $new)
            SecureField("Confirm new password", text: $confirmation)
            ErrorText(message: model.error)
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) {
                    model.error = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Change Password") {
                    Task {
                        if await model.changePassword(current: current, new: new, confirmation: confirmation) {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || current.isEmpty || new.isEmpty || confirmation.isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding()
        .frame(width: 340)
        .onAppear { model.error = nil }
    }
}

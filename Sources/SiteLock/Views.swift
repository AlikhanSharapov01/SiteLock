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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.connect() }
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
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("SiteLock is not running")
                .font(.title2)
            Text("The background service could not be reached. Install it with `sudo ./install.sh`, then try again.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Retry") { Task { await model.connect() } }
                .keyboardShortcut(.defaultAction)
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
            Text("Set your SiteLock password")
                .font(.title2)
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
            Image(systemName: "lock")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
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
    @State private var removeDomain: String?

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

            if model.state.domains.isEmpty {
                Text("No blocked sites yet. Add a domain above; its subdomains are blocked too.")
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
                                  onRemove: { removeDomain = domain })
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                }
            }

            HStack {
                Text("Changes quit and reopen Firefox so it loads the new list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("Lock") { model.lock() }
            }
        }
        .padding()
        .disabled(model.busy)
        .sheet(item: Binding(get: { customUnblockDomain.map(IdentifiedDomain.init) },
                             set: { customUnblockDomain = $0?.id })) { item in
            CustomUnblockSheet(domain: item.id) { minutes in
                Task { await model.unblock(item.id, minutes: minutes) }
            }
        }
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
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove \(domain)")
        }
        .padding(.vertical, 2)
    }
}

struct CustomUnblockSheet: View {
    @Environment(\.dismiss) private var dismiss
    let domain: String
    let onConfirm: (Int) -> Void
    @State private var minutes = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Unblock \(domain)")
                .font(.headline)
            Stepper(value: $minutes, in: 1...BlockState.maxUnblockMinutes) {
                HStack {
                    TextField("Minutes", value: $minutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Text("minutes")
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unblock") {
                    onConfirm(minutes)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!(1...BlockState.maxUnblockMinutes).contains(minutes))
            }
        }
        .padding()
        .frame(width: 300)
    }
}

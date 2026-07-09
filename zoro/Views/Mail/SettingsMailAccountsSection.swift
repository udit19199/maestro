//
//  SettingsMailAccountsSection.swift
//  zoro
//

import SwiftUI

private enum IMAPPreset: String, CaseIterable, Identifiable {
    case namecheap = "Namecheap Private Email"
    case iCloud = "iCloud"

    var id: String { rawValue }

    func makeAccount(email: String, displayName: String) -> MailAccount {
        switch self {
        case .namecheap:
            return .namecheapPrivateEmail(email: email, displayName: displayName)
        case .iCloud:
            return .iCloud(email: email, displayName: displayName)
        }
    }

    var passwordHint: String {
        switch self {
        case .namecheap:
            return "Use your Namecheap Private Email mailbox password."
        case .iCloud:
            return "iCloud requires an app-specific password from appleid.apple.com."
        }
    }

    var passwordHelpURL: URL? {
        switch self {
        case .iCloud:
            return URL(string: "https://appleid.apple.com/account/manage")
        default:
            return nil
        }
    }
}

struct SettingsMailAccountsSection: View {
    @ObservedObject private var accountStore = MailAccountStore.shared
    @ObservedObject private var gmailAuth = GmailAuthManager.shared
    @ObservedObject private var mailManager = MailManager.shared

    @AppStorage("mail_weekly_cleanup_enabled") private var weeklyCleanupEnabled = true

    @State private var gmailClientId = ""
    @State private var gmailClientSecret = ""
    @State private var gmailStatusMessage = "Not connected"
    @State private var imapStatusMessage: String?

    @State private var showAddIMAPSheet = false
    @State private var accountPendingDisconnect: MailAccount?
    @State private var isSyncingAll = false

    var body: some View {
        Form {
            Section {
                if accountStore.accounts.isEmpty {
                    emptyAccountsState
                } else {
                    ForEach(accountStore.accounts) { account in
                        accountRow(account)
                    }
                }

                HStack {
                    Button {
                        imapStatusMessage = nil
                        showAddIMAPSheet = true
                    } label: {
                        Label("Add IMAP Account…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        syncAllAccounts()
                    } label: {
                        Label(
                            isSyncingAll || mailManager.isSyncing ? "Syncing…" : "Sync All",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSyncingAll || mailManager.isSyncing || accountStore.enabledAccounts.isEmpty)
                }

                if let imapStatusMessage {
                    Label(imapStatusMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Connect Gmail via OAuth, or an IMAP mailbox (Namecheap Private Email, iCloud).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Google Client ID", text: $gmailClientId)
                    .onChange(of: gmailClientId) { _, newValue in
                        KeychainHelper.save(key: "gmail_client_id", value: newValue)
                    }

                SecureField("Google Client Secret", text: $gmailClientSecret)
                    .onChange(of: gmailClientSecret) { _, newValue in
                        KeychainHelper.save(key: "gmail_client_secret", value: newValue)
                    }

                Button {
                    connectGmail()
                } label: {
                    Label(
                        gmailAuth.isAuthorizing ? "Connecting Gmail…" : "Connect Gmail Account",
                        systemImage: "envelope.badge"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(gmailAuth.isAuthorizing || !hasGmailCredentials)

                if !hasGmailCredentials {
                    Text("Enter your Google Client ID and Secret above to enable Gmail sign-in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: gmailAuth.isConnected ? "checkmark.circle.fill" : "envelope")
                        .foregroundStyle(gmailAuth.isConnected ? .green : .secondary)
                    Text(gmailStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Gmail OAuth App")
            } footer: {
                Text("Shared OAuth credentials for all Gmail accounts. See reference/gmail-setup.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Weekly Cleanup") {
                Toggle("Sunday cleanup review", isOn: $weeklyCleanupEnabled)
                Text("When enabled, Zoro surfaces a newsletter cleanup review on Sunday evenings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddIMAPSheet) {
            AddIMAPAccountSheet { result in
                switch result {
                case .success(let account):
                    imapStatusMessage = "Added \(account.accountLabel)."
                    syncAllAccounts()
                case .failure(let error):
                    imapStatusMessage = error
                }
            }
        }
        .alert(
            "Disconnect account?",
            isPresented: Binding(
                get: { accountPendingDisconnect != nil },
                set: { if !$0 { accountPendingDisconnect = nil } }
            ),
            presenting: accountPendingDisconnect
        ) { account in
            Button("Disconnect", role: .destructive) {
                disconnect(account)
            }
            Button("Cancel", role: .cancel) {
                accountPendingDisconnect = nil
            }
        } message: { account in
            Text("Remove \(account.email.isEmpty ? account.accountLabel : account.email) from Zoro? Credentials will be deleted from Keychain.")
        }
        .onAppear(perform: loadSettings)
    }

    private var emptyAccountsState: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("No mail accounts connected yet")
                    .font(.body)
                Text("Add a Gmail or IMAP account to start syncing your inbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func accountRow(_ account: MailAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.email.isEmpty ? account.accountLabel : account.email)
                        .font(.body)
                        .fontWeight(.medium)
                    if !account.displayName.isEmpty, account.displayName != account.email {
                        Text(account.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                AccountBadge(label: account.provider == .gmail ? "Gmail" : "IMAP")
            }

            HStack {
                Toggle("Enabled", isOn: enabledBinding(for: account))
                    .toggleStyle(.switch)

                Spacer()

                Button("Disconnect", role: .destructive) {
                    accountPendingDisconnect = account
                }
                .buttonStyle(.borderless)
            }

            syncStatusLine(for: account)
        }
        .padding(.vertical, 4)
    }

    private func enabledBinding(for account: MailAccount) -> Binding<Bool> {
        Binding(
            get: { accountStore.account(id: account.id)?.isEnabled ?? account.isEnabled },
            set: { enabled in
                accountStore.setAccountEnabled(id: account.id, enabled: enabled)
                Task { await mailManager.syncAllAccounts() }
            }
        )
    }

    @ViewBuilder
    private func syncStatusLine(for account: MailAccount) -> some View {
        if let status = mailManager.syncStatus[account.id] {
            switch status {
            case .idle:
                EmptyView()
            case .syncing:
                Label("Syncing…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .ok(let unreadCount):
                Label("\(unreadCount) unread", systemImage: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } else if account.isEnabled, isAccountConfigured(account) {
            Label("Not synced yet", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if account.isEnabled {
            Label("Missing credentials", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private var hasGmailCredentials: Bool {
        !gmailClientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !gmailClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isAccountConfigured(_ account: MailAccount) -> Bool {
        switch account.provider {
        case .gmail:
            return gmailAuth.isAccountConnected(account.id)
        case .imap:
            return MailAccountKeychain.imapPassword(for: account.id) != nil
        }
    }

    private func loadSettings() {
        gmailClientId = KeychainHelper.retrieve(key: "gmail_client_id") ?? ""
        gmailClientSecret = KeychainHelper.retrieve(key: "gmail_client_secret") ?? ""

        Task {
            await gmailAuth.refreshConnectionStatus()
            await MainActor.run {
                updateGmailStatusMessage()
            }
            if !accountStore.enabledAccounts.isEmpty {
                await mailManager.syncAllAccounts()
            }
        }
    }

    private func updateGmailStatusMessage() {
        let gmailAccounts = accountStore.accounts.filter { $0.provider == .gmail }
        if gmailAccounts.isEmpty {
            gmailStatusMessage = gmailAuth.isConnected
                ? "Gmail connected"
                : "No Gmail accounts connected"
        } else {
            let labels = gmailAccounts.map { $0.email.isEmpty ? $0.accountLabel : $0.email }
            gmailStatusMessage = "Connected: \(labels.joined(separator: ", "))"
        }
    }

    private func connectGmail() {
        Task {
            do {
                let account = try await gmailAuth.connectAccount()
                gmailStatusMessage = "Connected as \(account.email)"
                await mailManager.syncAllAccounts()
            } catch {
                gmailStatusMessage = error.localizedDescription
            }
        }
    }

    private func disconnect(_ account: MailAccount) {
        switch account.provider {
        case .gmail:
            gmailAuth.disconnect(accountId: account.id)
            updateGmailStatusMessage()
        case .imap:
            accountStore.removeAccount(id: account.id)
        }
        accountPendingDisconnect = nil
        Task { await mailManager.syncAllAccounts() }
    }

    private func syncAllAccounts() {
        isSyncingAll = true
        Task {
            await mailManager.syncAllAccounts()
            await MainActor.run { isSyncingAll = false }
        }
    }
}

// MARK: - Add IMAP sheet

private struct AddIMAPAccountSheet: View {
    enum AddResult {
        case success(MailAccount)
        case failure(String)
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var accountStore = MailAccountStore.shared

    @State private var preset: IMAPPreset = .namecheap
    @State private var email = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var errorMessage: String?

    var onComplete: (AddResult) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add IMAP Account")
                .font(.headline)
                .padding()

            Form {
                Picker("Provider preset", selection: $preset) {
                    ForEach(IMAPPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }

                TextField("Email address", text: $email)
                    .textContentType(.emailAddress)

                TextField("Display name (optional)", text: $displayName)

                SecureField("Password", text: $password)

                Text(preset.passwordHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let url = preset.passwordHelpURL {
                    Link("Create app-specific password at Apple ID", destination: url)
                        .font(.caption)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add Account") {
                    addAccount()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .padding()
        }
        .frame(width: 440, height: 420)
    }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    private func addAccount() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmedEmail.lowercased()

        if accountStore.accounts.contains(where: { $0.email.lowercased() == lower && !lower.isEmpty }) {
            errorMessage = "An account with this email is already connected."
            return
        }

        var account = preset.makeAccount(
            email: trimmedEmail,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if account.displayName.isEmpty {
            account.displayName = trimmedEmail
        }

        accountStore.addAccount(account)
        MailAccountKeychain.saveIMAPPassword(password, accountId: account.id)
        accountStore.persistNow()

        onComplete(.success(account))
        dismiss()
    }
}

#Preview {
    SettingsMailAccountsSection()
        .frame(width: 520, height: 600)
}

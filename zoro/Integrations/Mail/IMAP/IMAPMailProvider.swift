//
//  IMAPMailProvider.swift
//  zoro
//
//  MailProvider implementation for Namecheap Private Email and iCloud IMAP accounts.
//

import Foundation

struct IMAPMailProvider: MailProvider {
    nonisolated let accountId: UUID
    let account: MailAccount

    nonisolated init(account: MailAccount) throws {
        guard account.provider == .imap else {
            throw MailError.unsupportedOperation("IMAPMailProvider requires an IMAP account.")
        }
        guard account.imapHost != nil, account.imapPort != nil, account.smtpHost != nil else {
            throw MailError.providerError(.imap, "IMAP account is missing host configuration.")
        }
        self.accountId = account.id
        self.account = account
    }

    func fetchUnread(limit: Int) async throws -> MailFetchResult {
        try await withClient { client in
            try await client.fetchUnread(limit: limit)
        }
    }

    func search(query: String, limit: Int) async throws -> MailFetchResult {
        try await withClient { client in
            try await client.search(query: query, limit: limit)
        }
    }

    func readMessage(id: String) async throws -> MailMessageContent {
        try await withClient { client in
            try await client.readMessage(id: id)
        }
    }

    func archive(id: String) async throws {
        try await withClient { client in
            try await client.archive(id: id)
        }
    }

    func markRead(id: String) async throws {
        try await withClient { client in
            try await client.markRead(id: id)
        }
    }

    func createDraft(_ draft: MailDraft) async throws -> String {
        try await withClient { client in
            try await client.createDraft(draft)
        }
    }

    func send(draftId: String) async throws {
        try await withClient { client in
            try await client.send(draftId: draftId)
        }
    }

    // MARK: - Private

    private func withClient<T>(
        _ operation: (IMAPClient) async throws -> T
    ) async throws -> T {
        guard let password = MailAccountKeychain.imapPassword(for: accountId), !password.isEmpty else {
            throw MailError.authenticationFailed(
                accountId: accountId,
                detail: presetHint(for: account)
            )
        }

        do {
            let client = try IMAPClient(account: account, password: password)
            return try await operation(client)
        } catch let error as MailError {
            throw error
        } catch {
            throw MailError.providerError(.imap, error.localizedDescription)
        }
    }

    private func presetHint(for account: MailAccount) -> String {
        switch account.imapHost {
        case "imap.mail.me.com":
            return "iCloud requires an app-specific password. Create one at appleid.apple.com and save it in Settings."
        case "mail.privateemail.com":
            return "Namecheap Private Email password not found in Keychain."
        default:
            return "IMAP password not found in Keychain."
        }
    }
}

// MARK: - Factory

enum IMAPMailProviderFactory {
    static func makeProvider(for account: MailAccount) throws -> IMAPMailProvider {
        try IMAPMailProvider(account: account)
    }

    static func makeProviderIfConfigured(for account: MailAccount) -> IMAPMailProvider? {
        guard account.provider == .imap, account.isEnabled else { return nil }
        return try? IMAPMailProvider(account: account)
    }
}

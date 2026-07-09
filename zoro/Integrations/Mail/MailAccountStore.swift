//
//  MailAccountStore.swift
//  zoro
//

import Foundation
import Combine
import os

// MARK: - Keychain key schema

enum MailAccountKeychain {
    private static let legacyGmailRefresh = "gmail_refresh_token"
    private static let legacyGmailAccess = "gmail_access_token"
    private static let legacyGmailExpiry = "gmail_token_expiry"

    static func gmailRefreshToken(accountId: UUID) -> String {
        "mail_gmail_refresh_\(accountId.uuidString)"
    }

    static func gmailAccessToken(accountId: UUID) -> String {
        "mail_gmail_access_\(accountId.uuidString)"
    }

    static func gmailTokenExpiry(accountId: UUID) -> String {
        "mail_gmail_expiry_\(accountId.uuidString)"
    }

    static func imapPassword(accountId: UUID) -> String {
        "mail_imap_password_\(accountId.uuidString)"
    }

    // MARK: - Gmail tokens

    static func saveGmailRefreshToken(_ token: String, accountId: UUID) {
        KeychainHelper.save(key: gmailRefreshToken(accountId: accountId), value: token)
    }

    static func gmailRefreshToken(for accountId: UUID) -> String? {
        KeychainHelper.retrieve(key: gmailRefreshToken(accountId: accountId))
    }

    static func saveGmailAccessToken(_ token: String, accountId: UUID) {
        KeychainHelper.save(key: gmailAccessToken(accountId: accountId), value: token)
    }

    static func gmailAccessToken(for accountId: UUID) -> String? {
        KeychainHelper.retrieve(key: gmailAccessToken(accountId: accountId))
    }

    static func saveGmailTokenExpiry(_ date: Date, accountId: UUID) {
        let iso = ISO8601DateFormatter().string(from: date)
        KeychainHelper.save(key: gmailTokenExpiry(accountId: accountId), value: iso)
    }

    static func gmailTokenExpiry(for accountId: UUID) -> Date? {
        guard let raw = KeychainHelper.retrieve(key: gmailTokenExpiry(accountId: accountId)) else {
            return nil
        }
        if let date = ISO8601DateFormatter().date(from: raw) {
            return date
        }
        if let unix = Double(raw) {
            return Date(timeIntervalSince1970: unix)
        }
        return nil
    }

    static func deleteGmailCredentials(for accountId: UUID) {
        KeychainHelper.delete(key: gmailRefreshToken(accountId: accountId))
        KeychainHelper.delete(key: gmailAccessToken(accountId: accountId))
        KeychainHelper.delete(key: gmailTokenExpiry(accountId: accountId))
    }

    // MARK: - IMAP password

    static func saveIMAPPassword(_ password: String, accountId: UUID) {
        KeychainHelper.save(key: imapPassword(accountId: accountId), value: password)
    }

    static func imapPassword(for accountId: UUID) -> String? {
        KeychainHelper.retrieve(key: imapPassword(accountId: accountId))
    }

    static func deleteIMAPPassword(for accountId: UUID) {
        KeychainHelper.delete(key: imapPassword(accountId: accountId))
    }

    static func deleteAllCredentials(for account: MailAccount) {
        switch account.provider {
        case .gmail:
            deleteGmailCredentials(for: account.id)
        case .imap:
            deleteIMAPPassword(for: account.id)
        }
    }

    // MARK: - Legacy Gmail migration

    static var hasLegacyGmailRefreshToken: Bool {
        guard let token = KeychainHelper.retrieve(key: legacyGmailRefresh) else { return false }
        return !token.isEmpty
    }

    static func migrateLegacyGmailTokens(to accountId: UUID) -> Bool {
        guard hasLegacyGmailRefreshToken else { return false }

        var migrated = false
        if let refresh = KeychainHelper.retrieve(key: legacyGmailRefresh), !refresh.isEmpty {
            saveGmailRefreshToken(refresh, accountId: accountId)
            migrated = true
        }
        if let access = KeychainHelper.retrieve(key: legacyGmailAccess), !access.isEmpty {
            saveGmailAccessToken(access, accountId: accountId)
        }
        if let expiryRaw = KeychainHelper.retrieve(key: legacyGmailExpiry), !expiryRaw.isEmpty {
            if let unix = Double(expiryRaw) {
                saveGmailTokenExpiry(Date(timeIntervalSince1970: unix), accountId: accountId)
            } else if let date = ISO8601DateFormatter().date(from: expiryRaw) {
                saveGmailTokenExpiry(date, accountId: accountId)
            }
        }
        return migrated
    }

    /// Removes flat `gmail_*` keys after `GmailAuthManager` reads namespaced keys (gmail-multi phase).
    static func removeLegacyGmailKeys() {
        KeychainHelper.delete(key: legacyGmailRefresh)
        KeychainHelper.delete(key: legacyGmailAccess)
        KeychainHelper.delete(key: legacyGmailExpiry)
    }
}

// MARK: - Persistence

private struct MailAccountsFile: Codable {
    var accounts: [MailAccount]
}

@MainActor
final class MailAccountStore: ObservableObject {
    static let shared = MailAccountStore()

    @Published private(set) var accounts: [MailAccount] = []

    private let logger = Logger(subsystem: "com.zoro.mail", category: "MailAccountStore")
    private var saveTask: Task<Void, Never>?
    private let saveDebounceNanoseconds: UInt64 = 500_000_000

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let base = appSupport?.appendingPathComponent("Zoro", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Zoro", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private var storageURL: URL {
        storageDirectory.appendingPathComponent("mail_accounts.json")
    }

    private init() {
        load()
        migrateLegacyGmailIfNeeded()
    }

    var enabledAccounts: [MailAccount] {
        accounts.filter(\.isEnabled)
    }

    func account(id: UUID) -> MailAccount? {
        accounts.first { $0.id == id }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let file = try decoder.decode(MailAccountsFile.self, from: data)
            accounts = file.accounts
        } catch {
            logger.error("Failed to load mail accounts: \(error.localizedDescription, privacy: .public)")
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: saveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self.persistNow()
        }
    }

    func persistNow() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let file = MailAccountsFile(accounts: accounts)
            let data = try encoder.encode(file)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            logger.error("Failed to save mail accounts: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func addAccount(_ account: MailAccount) -> MailAccount {
        accounts.append(account)
        scheduleSave()
        return account
    }

    func updateAccount(_ account: MailAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        scheduleSave()
    }

    func removeAccount(id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts.remove(at: index)
        MailAccountKeychain.deleteAllCredentials(for: account)
        scheduleSave()
    }

    func setAccountEnabled(id: UUID, enabled: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].isEnabled = enabled
        scheduleSave()
    }

    func accountLabelsByID() -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.accountLabel) })
    }

    // MARK: - Legacy migration

    private func migrateLegacyGmailIfNeeded() {
        guard MailAccountKeychain.hasLegacyGmailRefreshToken else { return }

        if let existingGmail = accounts.first(where: { $0.provider == .gmail }) {
            _ = MailAccountKeychain.migrateLegacyGmailTokens(to: existingGmail.id)
            return
        }

        let accountId = UUID()
        guard MailAccountKeychain.migrateLegacyGmailTokens(to: accountId) else { return }

        let migrated = MailAccount(
            id: accountId,
            email: "",
            displayName: "Gmail",
            provider: .gmail,
            isEnabled: true
        )
        accounts.append(migrated)
        persistNow()
        logger.info("Migrated legacy Gmail keychain tokens to account \(accountId.uuidString, privacy: .public)")
    }
}

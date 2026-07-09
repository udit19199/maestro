//
//  MailAccount.swift
//  zoro
//

import Foundation

enum MailProviderType: String, Codable, Sendable, CaseIterable {
    case gmail
    case imap
}

struct MailAccount: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var email: String
    var displayName: String
    var provider: MailProviderType
    var imapHost: String?
    var imapPort: Int?
    var smtpHost: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        email: String,
        displayName: String,
        provider: MailProviderType,
        imapHost: String? = nil,
        imapPort: Int? = nil,
        smtpHost: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.provider = provider
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.smtpHost = smtpHost
        self.isEnabled = isEnabled
    }

    /// Short label for briefing rows and account badges.
    var accountLabel: String {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let local = trimmedEmail.split(separator: "@").first, !local.isEmpty {
            return String(local)
        }
        return provider == .gmail ? "gmail" : "mail"
    }
}

// MARK: - IMAP presets

extension MailAccount {
    static func namecheapPrivateEmail(email: String, displayName: String = "") -> MailAccount {
        MailAccount(
            email: email,
            displayName: displayName,
            provider: .imap,
            imapHost: "mail.privateemail.com",
            imapPort: 993,
            smtpHost: "mail.privateemail.com"
        )
    }

    static func iCloud(email: String, displayName: String = "") -> MailAccount {
        MailAccount(
            email: email,
            displayName: displayName,
            provider: .imap,
            imapHost: "imap.mail.me.com",
            imapPort: 993,
            smtpHost: "smtp.mail.me.com"
        )
    }
}

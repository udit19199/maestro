//
//  GmailAuthManager.swift
//  zoro
//
//  OAuth 2.0 token management for the Gmail API.
//

import Foundation
import AppKit
import Combine
import CryptoKit
import Security
import os

enum GmailAuthError: LocalizedError {
    case missingCredentials
    case notConnected
    case accountNotConnected(UUID)
    case authorizationInProgress
    case authorizationFailed(String)
    case tokenRefreshFailed(String)
    case networkError(String)
    case duplicateAccount(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Gmail OAuth credentials are missing. Add your Google Cloud Client ID and Client Secret in Settings."
        case .notConnected:
            return "Gmail is not connected. Click 'Connect Gmail' in Settings to authorize access."
        case .accountNotConnected(let accountId):
            return "Gmail account \(accountId.uuidString) is not connected."
        case .authorizationInProgress:
            return "Gmail authorization is already in progress. Wait for it to finish before adding another account."
        case .authorizationFailed(let detail):
            return "Gmail authorization failed: \(detail)"
        case .tokenRefreshFailed(let detail):
            return "Failed to refresh Gmail access token: \(detail)"
        case .networkError(let detail):
            return "Gmail network error: \(detail)"
        case .duplicateAccount(let email):
            return "Gmail account \(email) is already connected."
        }
    }
}

@MainActor
final class GmailAuthManager: ObservableObject {
    static let shared = GmailAuthManager()

    static let redirectPort: UInt16 = 8765
    static let redirectURI = "http://127.0.0.1:8765/"

    private static let clientIdKey = "gmail_client_id"
    private static let clientSecretKey = "gmail_client_secret"

    private static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify"
    ].joined(separator: " ")

    @Published var isConnected: Bool = false
    @Published var connectedEmail: String? = nil
    @Published var isAuthorizing: Bool = false

    private let logger = Logger(subsystem: "com.zoro.mail", category: "GmailAuthManager")

    private init() {
        refreshLocalConnectionState()
        removeLegacyKeysIfMigrated()
    }

    // MARK: - Connection state

    func refreshConnectionStatus() async {
        refreshLocalConnectionState()
        removeLegacyKeysIfMigrated()

        guard let accountId = primaryConnectedAccountId() else {
            isConnected = false
            connectedEmail = nil
            return
        }

        do {
            let token = try await getValidAccessToken(accountId: accountId)
            let email = try await fetchProfileEmail(accessToken: token)
            connectedEmail = email
            isConnected = true

            if let account = MailAccountStore.shared.account(id: accountId), account.email != email {
                var updated = account
                updated.email = email
                if updated.displayName == "Gmail" || updated.displayName.isEmpty {
                    updated.displayName = email
                }
                MailAccountStore.shared.updateAccount(updated)
            }

            Task { await GmailManager.shared.refreshSnapshot() }
        } catch {
            refreshLocalConnectionState()
        }
    }

    func isAccountConnected(_ accountId: UUID) -> Bool {
        guard MailAccountStore.shared.account(id: accountId)?.provider == .gmail else { return false }
        return MailAccountKeychain.gmailRefreshToken(for: accountId) != nil
    }

    func connectedGmailAccountIds() -> [UUID] {
        MailAccountStore.shared.accounts
            .filter { $0.provider == .gmail && isAccountConnected($0.id) }
            .map(\.id)
    }

    /// Adds a Gmail account via OAuth. Re-authorizing an existing email updates its tokens.
    @discardableResult
    func connectAccount() async throws -> MailAccount {
        guard let clientId = KeychainHelper.retrieve(key: Self.clientIdKey),
              let clientSecret = KeychainHelper.retrieve(key: Self.clientSecretKey),
              !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GmailAuthError.missingCredentials
        }

        guard !isAuthorizing else {
            throw GmailAuthError.authorizationInProgress
        }

        isAuthorizing = true
        defer { isAuthorizing = false }

        let pendingAccountId = UUID()
        let state = UUID().uuidString
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let authURL = components.url else {
            throw GmailAuthError.authorizationFailed("Could not build authorization URL.")
        }

        let code = try await OAuthCallbackServer.shared.waitForAuthorizationCode(
            authURL: authURL,
            expectedState: state,
            port: Self.redirectPort
        )

        try await exchangeCodeForTokens(
            code: code,
            clientId: clientId,
            clientSecret: clientSecret,
            codeVerifier: codeVerifier,
            accountId: pendingAccountId
        )

        let token = try await getValidAccessToken(accountId: pendingAccountId)
        let email = try await fetchProfileEmail(accessToken: token)

        let account = reconcileAccount(
            pendingAccountId: pendingAccountId,
            email: email
        )

        refreshLocalConnectionState()
        removeLegacyKeysIfMigrated()

        Task {
            await GmailManager.shared.refreshSnapshot()
            await MainActor.run { WorkspaceManager.shared.invalidateSessionsForConfigChange() }
        }

        return account
    }

    /// Legacy entry point — adds another Gmail account (same as `connectAccount()`).
    func connect() async throws {
        _ = try await connectAccount()
    }

    func disconnect(accountId: UUID) {
        MailAccountKeychain.deleteGmailCredentials(for: accountId)
        MailAccountStore.shared.removeAccount(id: accountId)
        refreshLocalConnectionState()

        if !isConnected {
            GmailManager.shared.unreadCount = nil
            GmailManager.shared.inboxPreview = []
            GmailManager.shared.stopAutoRefresh()
        }

        WorkspaceManager.shared.invalidateSessionsForConfigChange()
    }

    /// Disconnects all Gmail accounts (legacy single-account API).
    func disconnect() {
        let accountIds = connectedGmailAccountIds()
        for accountId in accountIds {
            MailAccountKeychain.deleteGmailCredentials(for: accountId)
            MailAccountStore.shared.removeAccount(id: accountId)
        }
        isConnected = false
        connectedEmail = nil
        GmailManager.shared.unreadCount = nil
        GmailManager.shared.inboxPreview = []
        GmailManager.shared.stopAutoRefresh()
        WorkspaceManager.shared.invalidateSessionsForConfigChange()
    }

    func getValidAccessToken(accountId: UUID) async throws -> String {
        guard isAccountConnected(accountId)
            || MailAccountKeychain.gmailRefreshToken(for: accountId) != nil else {
            throw GmailAuthError.accountNotConnected(accountId)
        }

        if let accessToken = MailAccountKeychain.gmailAccessToken(for: accountId),
           let expiry = MailAccountKeychain.gmailTokenExpiry(for: accountId),
           Date() < expiry.addingTimeInterval(-60) {
            return accessToken
        }

        guard let refreshToken = MailAccountKeychain.gmailRefreshToken(for: accountId),
              !refreshToken.isEmpty else {
            throw GmailAuthError.accountNotConnected(accountId)
        }

        guard let clientId = KeychainHelper.retrieve(key: Self.clientIdKey),
              let clientSecret = KeychainHelper.retrieve(key: Self.clientSecretKey) else {
            throw GmailAuthError.missingCredentials
        }

        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAuthError.networkError("Invalid token refresh response.")
        }

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw GmailAuthError.tokenRefreshFailed(detail)
        }

        let tokenResponse = try JSONDecoder().decode(GmailTokenResponse.self, from: data)
        storeAccessToken(tokenResponse.accessToken, expiresIn: tokenResponse.expiresIn, accountId: accountId)
        removeLegacyKeysIfMigrated()
        return tokenResponse.accessToken
    }

    // MARK: - Private

    private func refreshLocalConnectionState() {
        let connected = connectedGmailAccounts()
        isConnected = !connected.isEmpty
        connectedEmail = connected.first?.email.nilIfEmpty
    }

    private func connectedGmailAccounts() -> [MailAccount] {
        MailAccountStore.shared.accounts.filter { account in
            account.provider == .gmail && MailAccountKeychain.gmailRefreshToken(for: account.id) != nil
        }
    }

    private func primaryConnectedAccountId() -> UUID? {
        connectedGmailAccounts().first?.id
    }

    private func reconcileAccount(pendingAccountId: UUID, email: String) -> MailAccount {
        if let existing = MailAccountStore.shared.accounts.first(where: {
            $0.provider == .gmail && $0.email.caseInsensitiveCompare(email) == .orderedSame
        }) {
            if pendingAccountId != existing.id {
                moveGmailCredentials(from: pendingAccountId, to: existing.id)
            }
            var updated = existing
            updated.email = email
            if updated.displayName == "Gmail" || updated.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.displayName = email
            }
            MailAccountStore.shared.updateAccount(updated)
            return updated
        }

        if let placeholder = MailAccountStore.shared.accounts.first(where: {
            $0.id == pendingAccountId || ($0.provider == .gmail && $0.email.isEmpty)
        }) {
            var updated = placeholder
            updated.email = email
            updated.displayName = email
            MailAccountStore.shared.updateAccount(updated)
            return updated
        }

        let account = MailAccount(
            id: pendingAccountId,
            email: email,
            displayName: email,
            provider: .gmail,
            isEnabled: true
        )
        MailAccountStore.shared.addAccount(account)
        return account
    }

    private func moveGmailCredentials(from sourceId: UUID, to destinationId: UUID) {
        if let refresh = MailAccountKeychain.gmailRefreshToken(for: sourceId) {
            MailAccountKeychain.saveGmailRefreshToken(refresh, accountId: destinationId)
        }
        if let access = MailAccountKeychain.gmailAccessToken(for: sourceId) {
            MailAccountKeychain.saveGmailAccessToken(access, accountId: destinationId)
        }
        if let expiry = MailAccountKeychain.gmailTokenExpiry(for: sourceId) {
            MailAccountKeychain.saveGmailTokenExpiry(expiry, accountId: destinationId)
        }
        MailAccountKeychain.deleteGmailCredentials(for: sourceId)
    }

    private func removeLegacyKeysIfMigrated() {
        guard MailAccountKeychain.hasLegacyGmailRefreshToken else { return }

        let gmailAccounts = MailAccountStore.shared.accounts.filter { $0.provider == .gmail }
        guard !gmailAccounts.isEmpty else { return }

        let allMigrated = gmailAccounts.allSatisfy {
            MailAccountKeychain.gmailRefreshToken(for: $0.id) != nil
        }
        guard allMigrated else { return }

        MailAccountKeychain.removeLegacyGmailKeys()
        logger.info("Removed legacy flat gmail_* keychain keys after multi-account migration")
    }

    private func exchangeCodeForTokens(
        code: String,
        clientId: String,
        clientSecret: String,
        codeVerifier: String,
        accountId: UUID
    ) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": Self.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": codeVerifier
        ]
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailAuthError.networkError("Invalid token exchange response.")
        }

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw GmailAuthError.authorizationFailed(detail)
        }

        let tokenResponse = try JSONDecoder().decode(GmailTokenResponse.self, from: data)
        storeAccessToken(tokenResponse.accessToken, expiresIn: tokenResponse.expiresIn, accountId: accountId)

        if let refreshToken = tokenResponse.refreshToken {
            MailAccountKeychain.saveGmailRefreshToken(refreshToken, accountId: accountId)
        }
    }

    private func storeAccessToken(_ token: String, expiresIn: Int, accountId: UUID) {
        MailAccountKeychain.saveGmailAccessToken(token, accountId: accountId)
        let expiry = Date().addingTimeInterval(Double(expiresIn))
        MailAccountKeychain.saveGmailTokenExpiry(expiry, accountId: accountId)
    }

    private func fetchProfileEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailAuthError.networkError(detail)
        }

        let profile = try JSONDecoder().decode(GmailProfileResponse.self, from: data)
        return profile.emailAddress
    }

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GmailTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct GmailProfileResponse: Decodable {
    let emailAddress: String
}

// MARK: - Local OAuth callback server

final class OAuthCallbackServer {
    static let shared = OAuthCallbackServer()

    private var serverSocket: Int32 = -1
    private let queue = DispatchQueue(label: "com.zoro.oauth-callback")

    private init() {}

    func waitForAuthorizationCode(authURL: URL, expectedState: String, port: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: GmailAuthError.authorizationFailed("Server unavailable."))
                    return
                }

                do {
                    let code = try self.runServer(
                        authURL: authURL,
                        expectedState: expectedState,
                        port: port
                    )
                    continuation.resume(returning: code)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runServer(authURL: URL, expectedState: String, port: UInt16) throws -> String {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw GmailAuthError.authorizationFailed("Could not create local callback server.")
        }
        defer {
            close(serverSocket)
            serverSocket = -1
        }

        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw GmailAuthError.authorizationFailed("Could not bind to port \(port). Ensure it is not in use.")
        }

        guard listen(serverSocket, 1) == 0 else {
            throw GmailAuthError.authorizationFailed("Could not listen on port \(port).")
        }

        DispatchQueue.main.async {
            NSWorkspace.shared.open(authURL)
        }

        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverSocket, $0, &clientLen)
            }
        }
        guard clientSocket >= 0 else {
            throw GmailAuthError.authorizationFailed("Authorization callback timed out or failed.")
        }
        defer { close(clientSocket) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = recv(clientSocket, &buffer, buffer.count, 0)
        guard bytesRead > 0 else {
            throw GmailAuthError.authorizationFailed("Empty authorization callback.")
        }

        let request = String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
        guard let requestLine = request.components(separatedBy: "\r\n").first,
              let path = requestLine.split(separator: " ").dropFirst().first else {
            throw GmailAuthError.authorizationFailed("Malformed authorization callback.")
        }

        sendSuccessPage(to: clientSocket)

        guard let components = URLComponents(string: "http://127.0.0.1\(path)") else {
            throw GmailAuthError.authorizationFailed("Could not parse callback URL.")
        }

        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        if let error = queryItems["error"] {
            throw GmailAuthError.authorizationFailed(error)
        }

        guard queryItems["state"] == expectedState else {
            throw GmailAuthError.authorizationFailed("OAuth state mismatch.")
        }

        guard let code = queryItems["code"], !code.isEmpty else {
            throw GmailAuthError.authorizationFailed("Missing authorization code.")
        }

        return code
    }

    private func sendSuccessPage(to socket: Int32) {
        let html = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html\r
        Connection: close\r
        \r
        <!DOCTYPE html><html><body style="font-family: -apple-system, sans-serif; text-align: center; padding: 40px;">
        <h2>Gmail connected</h2><p>You can close this tab and return to Zoro.</p>
        </body></html>
        """
        _ = html.withCString { send(socket, $0, strlen($0), 0) }
    }
}

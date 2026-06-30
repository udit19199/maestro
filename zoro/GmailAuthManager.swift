//
//  GmailAuthManager.swift
//  zoro
//
//  OAuth 2.0 token management for the Gmail API.
//

import Foundation
import AppKit
import Combine

enum GmailAuthError: LocalizedError {
    case missingCredentials
    case notConnected
    case authorizationFailed(String)
    case tokenRefreshFailed(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Gmail OAuth credentials are missing. Add your Google Cloud Client ID and Client Secret in Settings."
        case .notConnected:
            return "Gmail is not connected. Click 'Connect Gmail' in Settings to authorize access."
        case .authorizationFailed(let detail):
            return "Gmail authorization failed: \(detail)"
        case .tokenRefreshFailed(let detail):
            return "Failed to refresh Gmail access token: \(detail)"
        case .networkError(let detail):
            return "Gmail network error: \(detail)"
        }
    }
}

@MainActor
final class GmailAuthManager: ObservableObject {
    static let shared = GmailAuthManager()

    static let redirectPort: UInt16 = 8765
    static let redirectURI = "http://127.0.0.1:8765/"

    private static let scopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify"
    ].joined(separator: " ")

    @Published var isConnected: Bool = false
    @Published var connectedEmail: String? = nil
    @Published var isAuthorizing: Bool = false

    private init() {
        isConnected = KeychainHelper.retrieve(key: "gmail_refresh_token") != nil
    }

    func refreshConnectionStatus() async {
        guard KeychainHelper.retrieve(key: "gmail_refresh_token") != nil else {
            isConnected = false
            connectedEmail = nil
            return
        }

        do {
            let token = try await getValidAccessToken()
            connectedEmail = try await fetchProfileEmail(accessToken: token)
            isConnected = true
        } catch {
            isConnected = KeychainHelper.retrieve(key: "gmail_refresh_token") != nil
            connectedEmail = nil
        }
    }

    func connect() async throws {
        guard let clientId = KeychainHelper.retrieve(key: "gmail_client_id"),
              let clientSecret = KeychainHelper.retrieve(key: "gmail_client_secret"),
              !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GmailAuthError.missingCredentials
        }

        isAuthorizing = true
        defer { isAuthorizing = false }

        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
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
            clientSecret: clientSecret
        )

        let token = try await getValidAccessToken()
        connectedEmail = try await fetchProfileEmail(accessToken: token)
        isConnected = true
    }

    func disconnect() {
        KeychainHelper.delete(key: "gmail_refresh_token")
        KeychainHelper.delete(key: "gmail_access_token")
        KeychainHelper.delete(key: "gmail_token_expiry")
        isConnected = false
        connectedEmail = nil
    }

    func getValidAccessToken() async throws -> String {
        if let accessToken = KeychainHelper.retrieve(key: "gmail_access_token"),
           let expiryString = KeychainHelper.retrieve(key: "gmail_token_expiry"),
           let expiry = Double(expiryString),
           Date().timeIntervalSince1970 < expiry - 60 {
            return accessToken
        }

        guard let refreshToken = KeychainHelper.retrieve(key: "gmail_refresh_token"),
              !refreshToken.isEmpty else {
            throw GmailAuthError.notConnected
        }

        guard let clientId = KeychainHelper.retrieve(key: "gmail_client_id"),
              let clientSecret = KeychainHelper.retrieve(key: "gmail_client_secret") else {
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
        storeAccessToken(tokenResponse.accessToken, expiresIn: tokenResponse.expiresIn)
        return tokenResponse.accessToken
    }

    private func exchangeCodeForTokens(code: String, clientId: String, clientSecret: String) async throws {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": Self.redirectURI,
            "grant_type": "authorization_code"
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
        storeAccessToken(tokenResponse.accessToken, expiresIn: tokenResponse.expiresIn)

        if let refreshToken = tokenResponse.refreshToken {
            KeychainHelper.save(key: "gmail_refresh_token", value: refreshToken)
        }
    }

    private func storeAccessToken(_ token: String, expiresIn: Int) {
        KeychainHelper.save(key: "gmail_access_token", value: token)
        let expiry = Date().timeIntervalSince1970 + Double(expiresIn)
        KeychainHelper.save(key: "gmail_token_expiry", value: String(expiry))
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

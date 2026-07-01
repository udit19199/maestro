//
//  CodexAuthManager.swift
//  zoro
//
//  ChatGPT / Codex subscription authentication for the Codex backend API.
//

import Foundation
import AppKit
import Combine
import CryptoKit
import Security

enum CodexAuthError: LocalizedError {
    case notConnected
    case authorizationFailed(String)
    case tokenRefreshFailed(String)
    case importFailed(String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Codex is not connected. Sign in with your ChatGPT account in Settings."
        case .authorizationFailed(let detail):
            return "Codex authorization failed: \(detail)"
        case .tokenRefreshFailed(let detail):
            return "Failed to refresh Codex access token: \(detail)"
        case .importFailed(let detail):
            return "Could not import Codex CLI credentials: \(detail)"
        case .networkError(let detail):
            return "Codex network error: \(detail)"
        }
    }
}

struct CodexCredentials: Sendable {
    let accessToken: String
    let accountID: String
}

@MainActor
final class CodexAuthManager: ObservableObject {
    static let shared = CodexAuthManager()

    static let oauthClientID = CodexAuthSupport.oauthClientID
    static let oauthIssuer = CodexAuthSupport.oauthIssuer
    static let tokenURL = CodexAuthSupport.tokenURL
    static let defaultCallbackPort: UInt16 = 1455
    static let fallbackCallbackPort: UInt16 = 1457

    private static let oauthScope =
        "openid profile email offline_access api.connectors.read api.connectors.invoke"

    @Published var isConnected: Bool = false
    @Published var connectedEmail: String? = nil
    @Published var isAuthorizing: Bool = false
    @Published var deviceCodePrompt: DeviceCodePrompt? = nil

    struct DeviceCodePrompt: Equatable {
        let verificationURL: String
        let userCode: String
    }

    private init() {
        isConnected = KeychainHelper.retrieve(key: "codex_refresh_token") != nil
    }

    func refreshConnectionStatus() async {
        guard KeychainHelper.retrieve(key: "codex_refresh_token") != nil else {
            isConnected = false
            connectedEmail = nil
            return
        }

        do {
            _ = try await getValidCredentials()
            isConnected = true
            connectedEmail = Self.emailFromStoredTokens()
        } catch {
            isConnected = KeychainHelper.retrieve(key: "codex_refresh_token") != nil
            connectedEmail = Self.emailFromStoredTokens()
        }
    }

    /// Import credentials from an existing Codex CLI login at ~/.codex/auth.json.
    func importFromCLI() throws {
        let authPath = CodexAuthSupport.cliAuthPath()
        guard CodexAuthSupport.isSafeCLIAuthPath(authPath) else {
            throw CodexAuthError.importFailed("Refusing to import Codex auth from an unexpected path.")
        }
        guard FileManager.default.fileExists(atPath: authPath.path) else {
            throw CodexAuthError.importFailed(
                "No Codex CLI auth file found at \(authPath.path). Run `codex login` in Terminal first, or use Sign in with ChatGPT."
            )
        }

        let data = try Data(contentsOf: authPath)
        let tokens = try CodexAuthSupport.parseChatGPTAuthDocument(data)
        try persistTokens(from: tokens)
        isConnected = true
        connectedEmail = Self.emailFromStoredTokens()
        WorkspaceManager.shared.invalidateSessionsForConfigChange()
    }

    /// Browser-based ChatGPT OAuth (same flow as Codex CLI).
    func connect() async throws {
        isAuthorizing = true
        defer { isAuthorizing = false }

        let state = Self.generateRandomURLSafeString(length: 32)
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)

        let port = Self.findAvailablePort(preferred: Self.defaultCallbackPort, fallback: Self.fallbackCallbackPort)
        let redirectURI = "http://localhost:\(port)/auth/callback"
        let authURL = Self.buildAuthorizeURL(
            redirectURI: redirectURI,
            codeChallenge: codeChallenge,
            state: state
        )

        let code = try await CodexOAuthCallbackServer.shared.waitForAuthorizationCode(
            authURL: authURL,
            expectedState: state,
            port: port
        )

        try await exchangeAuthorizationCode(code: code, redirectURI: redirectURI, codeVerifier: codeVerifier)
        isConnected = true
        connectedEmail = Self.emailFromStoredTokens()
        WorkspaceManager.shared.invalidateSessionsForConfigChange()
    }

    /// Device code flow for environments where browser redirect is awkward.
    func startDeviceCodeLogin() async throws {
        isAuthorizing = true
        defer {
            isAuthorizing = false
            deviceCodePrompt = nil
        }

        let userCodeResponse = try await requestDeviceUserCode()
        deviceCodePrompt = DeviceCodePrompt(
            verificationURL: "\(Self.oauthIssuer)/codex/device",
            userCode: userCodeResponse.userCode
        )

        let tokenPoll = try await pollDeviceCode(
            deviceAuthID: userCodeResponse.deviceAuthID,
            userCode: userCodeResponse.userCode,
            interval: userCodeResponse.interval
        )

        let redirectURI = "\(Self.oauthIssuer)/deviceauth/callback"
        try await exchangeAuthorizationCode(
            code: tokenPoll.authorizationCode,
            redirectURI: redirectURI,
            codeVerifier: tokenPoll.codeVerifier
        )

        isConnected = true
        connectedEmail = Self.emailFromStoredTokens()
        WorkspaceManager.shared.invalidateSessionsForConfigChange()
    }

    func disconnect() async {
        await revokeStoredTokens()
        KeychainHelper.delete(key: "codex_access_token")
        KeychainHelper.delete(key: "codex_refresh_token")
        KeychainHelper.delete(key: "codex_id_token")
        KeychainHelper.delete(key: "codex_account_id")
        KeychainHelper.delete(key: "codex_token_expiry")
        isConnected = false
        connectedEmail = nil
        WorkspaceManager.shared.invalidateSessionsForConfigChange()
    }

    func getValidCredentials(forceRefresh: Bool = false) async throws -> CodexCredentials {
        if !forceRefresh,
           let accessToken = KeychainHelper.retrieve(key: "codex_access_token"),
           let expiryString = KeychainHelper.retrieve(key: "codex_token_expiry"),
           let expiry = Double(expiryString),
           Date().timeIntervalSince1970 < expiry - 30 {
            let accountID = KeychainHelper.retrieve(key: "codex_account_id") ?? CodexAuthSupport.extractAccountID(
                idToken: KeychainHelper.retrieve(key: "codex_id_token"),
                accessToken: accessToken
            )
            if !accountID.isEmpty {
                KeychainHelper.save(key: "codex_account_id", value: accountID)
            }
            return CodexCredentials(accessToken: accessToken, accountID: accountID)
        }

        return try await refreshStoredCredentials()
    }

    /// Redacts token-like substrings before surfacing upstream errors in the UI.
    static func sanitizedErrorDetail(_ detail: String) -> String {
        CodexAuthSupport.sanitizedErrorDetail(detail)
    }

    private func revokeStoredTokens() async {
        let body = CodexAuthSupport.revokeRequestBody(
            refreshToken: KeychainHelper.retrieve(key: "codex_refresh_token"),
            accessToken: KeychainHelper.retrieve(key: "codex_access_token")
        )
        guard let body, let url = URL(string: CodexAuthSupport.revokeURL) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func refreshStoredCredentials() async throws -> CodexCredentials {
        guard let refreshToken = KeychainHelper.retrieve(key: "codex_refresh_token"),
              !refreshToken.isEmpty else {
            throw CodexAuthError.notConnected
        }

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.oauthClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexAuthError.networkError("Invalid token refresh response.")
        }

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw CodexAuthError.tokenRefreshFailed(CodexAuthSupport.sanitizedErrorDetail(detail))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.tokenRefreshFailed("Invalid refresh response JSON.")
        }

        var tokens: [String: Any] = [:]
        if let access = json["access_token"] as? String { tokens["access_token"] = access }
        if let refresh = json["refresh_token"] as? String { tokens["refresh_token"] = refresh }
        if let idToken = json["id_token"] as? String { tokens["id_token"] = idToken }
        try persistTokens(from: tokens)

        let accessToken = json["access_token"] as? String ?? ""
        let accountID = CodexAuthSupport.extractAccountID(
            idToken: json["id_token"] as? String,
            accessToken: accessToken
        )
        if !accountID.isEmpty {
            KeychainHelper.save(key: "codex_account_id", value: accountID)
        }

        return CodexCredentials(accessToken: accessToken, accountID: accountID)
    }

    // MARK: - Private helpers

    private func exchangeAuthorizationCode(code: String, redirectURI: String, codeVerifier: String) async throws {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.oauthClientID,
            "code_verifier": codeVerifier
        ]
        request.httpBody = body
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexAuthError.networkError("Invalid token exchange response.")
        }

        guard httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw CodexAuthError.authorizationFailed(CodexAuthSupport.sanitizedErrorDetail(detail))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.authorizationFailed("Invalid token exchange JSON.")
        }

        try persistTokens(from: json)
    }

    private func persistTokens(from tokens: [String: Any]) throws {
        guard let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty else {
            throw CodexAuthError.authorizationFailed("Token response missing access_token.")
        }

        KeychainHelper.save(key: "codex_access_token", value: accessToken)

        if let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty {
            KeychainHelper.save(key: "codex_refresh_token", value: refreshToken)
        }

        if let idToken = tokens["id_token"] as? String, !idToken.isEmpty {
            KeychainHelper.save(key: "codex_id_token", value: idToken)
        }

        let accountID = CodexAuthSupport.extractAccountID(
            idToken: tokens["id_token"] as? String,
            accessToken: accessToken
        )
        if !accountID.isEmpty {
            KeychainHelper.save(key: "codex_account_id", value: accountID)
        }

        if let expiry = CodexAuthSupport.jwtExpiry(accessToken) {
            KeychainHelper.save(key: "codex_token_expiry", value: String(expiry))
        }
    }

    private struct DeviceUserCodeResponse {
        let deviceAuthID: String
        let userCode: String
        let interval: UInt64
    }

    private struct DeviceTokenPollResponse {
        let authorizationCode: String
        let codeVerifier: String
    }

    private func requestDeviceUserCode() async throws -> DeviceUserCodeResponse {
        let url = URL(string: "\(Self.oauthIssuer)/api/accounts/deviceauth/usercode")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": Self.oauthClientID])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw CodexAuthError.authorizationFailed("Device code request failed: \(detail)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceAuthID = json["device_auth_id"] as? String,
              let userCode = (json["user_code"] as? String) ?? (json["usercode"] as? String) else {
            throw CodexAuthError.authorizationFailed("Invalid device code response.")
        }

        let interval: UInt64
        if let intervalNumber = json["interval"] as? NSNumber {
            interval = intervalNumber.uint64Value
        } else if let intervalString = json["interval"] as? String, let parsed = UInt64(intervalString.trimmingCharacters(in: .whitespaces)) {
            interval = parsed
        } else {
            interval = 5
        }

        return DeviceUserCodeResponse(deviceAuthID: deviceAuthID, userCode: userCode, interval: interval)
    }

    private func pollDeviceCode(deviceAuthID: String, userCode: String, interval: UInt64) async throws -> DeviceTokenPollResponse {
        let url = URL(string: "\(Self.oauthIssuer)/api/accounts/deviceauth/token")!
        let deadline = Date().addingTimeInterval(15 * 60)

        while Date() < deadline {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceAuthID,
                "user_code": userCode
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw CodexAuthError.networkError("Invalid device auth poll response.")
            }

            if httpResponse.statusCode == 200 {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let authorizationCode = json["authorization_code"] as? String,
                      let codeVerifier = json["code_verifier"] as? String else {
                    throw CodexAuthError.authorizationFailed("Invalid device auth token response.")
                }
                return DeviceTokenPollResponse(authorizationCode: authorizationCode, codeVerifier: codeVerifier)
            }

            if httpResponse.statusCode == 403 || httpResponse.statusCode == 404 {
                try await Task.sleep(nanoseconds: interval * 1_000_000_000)
                continue
            }

            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw CodexAuthError.authorizationFailed("Device auth polling failed: \(detail)")
        }

        throw CodexAuthError.authorizationFailed("Device code authentication timed out after 15 minutes.")
    }

    private static func buildAuthorizeURL(redirectURI: String, codeChallenge: String, state: String) -> URL {
        var components = URLComponents(string: "\(oauthIssuer)/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: oauthClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: oauthScope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: "zoro")
        ]
        return components.url!
    }

    private static func generateCodeVerifier() -> String {
        generateRandomURLSafeString(length: 43)
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateRandomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func findAvailablePort(preferred: UInt16, fallback: UInt16) -> UInt16 {
        if Self.isPortAvailable(preferred) { return preferred }
        if Self.isPortAvailable(fallback) { return fallback }
        return preferred
    }

    private static func isPortAvailable(_ port: UInt16) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }

    private static func emailFromStoredTokens() -> String? {
        CodexAuthSupport.emailFromJWTClaims(
            idToken: KeychainHelper.retrieve(key: "codex_id_token"),
            accessToken: KeychainHelper.retrieve(key: "codex_access_token")
        )
    }
}

// MARK: - Local OAuth callback server (Codex CLI compatible)

final class CodexOAuthCallbackServer {
    static let shared = CodexOAuthCallbackServer()

    private var serverSocket: Int32 = -1
    private let queue = DispatchQueue(label: "com.zoro.codex-oauth-callback")

    private init() {}

    func waitForAuthorizationCode(authURL: URL, expectedState: String, port: UInt16) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CodexAuthError.authorizationFailed("Server unavailable."))
                    return
                }

                do {
                    let code = try self.runServer(authURL: authURL, expectedState: expectedState, port: port)
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
            throw CodexAuthError.authorizationFailed("Could not create local callback server.")
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
            throw CodexAuthError.authorizationFailed("Could not bind to port \(port). Another app may be using it.")
        }

        guard listen(serverSocket, 1) == 0 else {
            throw CodexAuthError.authorizationFailed("Could not listen on port \(port).")
        }

        var acceptTimeout = timeval(tv_sec: 300, tv_usec: 0)
        setsockopt(serverSocket, SOL_SOCKET, SO_RCVTIMEO, &acceptTimeout, socklen_t(MemoryLayout<timeval>.size))

        DispatchQueue.main.async {
            NSWorkspace.shared.open(authURL)
        }

        var clientAddr = sockaddr_in()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverSocket, $0, &clientAddrLen)
            }
        }
        guard clientSocket >= 0 else {
            throw CodexAuthError.authorizationFailed("OAuth callback timed out after 5 minutes.")
        }
        defer { close(clientSocket) }

        guard isLoopbackAddress(clientAddr) else {
            sendHTTPResponse(clientSocket, status: 403, body: "Forbidden")
            throw CodexAuthError.authorizationFailed("OAuth callback must originate from localhost.")
        }

        var requestData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(clientSocket, &buffer, buffer.count)
            guard bytesRead > 0 else { break }
            requestData.append(contentsOf: buffer[0..<bytesRead])
            if requestData.contains(Data("\r\n\r\n".utf8)) { break }
        }

        guard let requestString = String(data: requestData, encoding: .utf8),
              let requestLine = requestString.components(separatedBy: "\r\n").first else {
            throw CodexAuthError.authorizationFailed("Invalid OAuth callback request.")
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "GET" else {
            sendHTTPResponse(clientSocket, status: 405, body: "Method Not Allowed")
            throw CodexAuthError.authorizationFailed("OAuth callback must use GET.")
        }

        let path = String(parts[1])
        guard path.hasPrefix("/auth/callback") else {
            sendHTTPResponse(clientSocket, status: 404, body: "Not Found")
            throw CodexAuthError.authorizationFailed("Unexpected OAuth callback path.")
        }

        guard let urlComponents = URLComponents(string: "http://localhost\(path)") else {
            throw CodexAuthError.authorizationFailed("Could not parse OAuth callback URL.")
        }

        if let error = urlComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            let description = urlComponents.queryItems?.first(where: { $0.name == "error_description" })?.value
            sendHTTPResponse(clientSocket, status: 400, body: "Authorization failed.")
            throw CodexAuthError.authorizationFailed(description ?? error)
        }

        guard let code = urlComponents.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = urlComponents.queryItems?.first(where: { $0.name == "state" })?.value else {
            sendHTTPResponse(clientSocket, status: 400, body: "Missing authorization code.")
            throw CodexAuthError.authorizationFailed("OAuth callback missing code or state.")
        }

        guard state == expectedState else {
            sendHTTPResponse(clientSocket, status: 400, body: "State mismatch.")
            throw CodexAuthError.authorizationFailed("OAuth state mismatch.")
        }

        sendHTTPResponse(
            clientSocket,
            status: 200,
            body: "<html><body><h2>Signed in to Codex</h2><p>You can close this tab and return to Zoro.</p></body></html>",
            contentType: "text/html; charset=utf-8"
        )

        return code
    }

    private func sendHTTPResponse(_ socket: Int32, status: Int, body: String, contentType: String = "text/plain") {
        let response = """
        HTTP/1.1 \(status) OK\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        _ = response.withCString { write(socket, $0, strlen($0)) }
    }

    private func isLoopbackAddress(_ addr: sockaddr_in) -> Bool {
        addr.sin_addr.s_addr == inet_addr("127.0.0.1")
    }
}

//
//  CodexAuthSupport.swift
//  zoro
//
//  Pure Codex auth helpers (Foundation only — unit-testable on macOS).
//

import Foundation

enum CodexAuthSupport {
    static let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let oauthIssuer = "https://auth.openai.com"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let revokeURL = "https://auth.openai.com/oauth/revoke"

    static func cliAuthPath(codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"]) -> URL {
        let homePath: String
        if let codexHome, !codexHome.isEmpty {
            homePath = codexHome
        } else {
            homePath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex").path
        }
        return URL(fileURLWithPath: homePath).appendingPathComponent("auth.json")
    }

    static func isSafeCLIAuthPath(_ path: URL) -> Bool {
        let standardized = path.standardizedFileURL
        let expected = cliAuthPath().standardizedFileURL
        return standardized == expected
    }

    static func parseChatGPTAuthDocument(_ data: Data) throws -> [String: Any] {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAuthError.importFailed("Invalid auth.json format.")
        }

        guard let authMode = doc["auth_mode"] as? String, authMode == "chatgpt" else {
            throw CodexAuthError.importFailed(
                "Expected auth_mode 'chatgpt' in auth.json. API-key auth belongs on the OpenAI API backend, not Codex subscription."
            )
        }

        guard let tokens = doc["tokens"] as? [String: Any] else {
            throw CodexAuthError.importFailed("No tokens object in auth.json.")
        }

        guard let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            throw CodexAuthError.importFailed("auth.json is missing refresh_token; run `codex login` again.")
        }

        guard let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw CodexAuthError.importFailed("auth.json is missing access_token.")
        }

        return tokens
    }

    static func sanitizedErrorDetail(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown error" }

        let redacted = trimmed.replacingOccurrences(
            of: #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#,
            with: "[redacted-token]",
            options: .regularExpression
        )
        if redacted.count <= 280 {
            return redacted
        }
        return String(redacted.prefix(280)) + "…"
    }

    static func extractAccountID(idToken: String?, accessToken: String?) -> String {
        for token in [idToken, accessToken].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            guard let claims = jwtClaims(token) else { continue }

            if let accountID = claims["chatgpt_account_id"] as? String, !accountID.isEmpty {
                return accountID
            }

            if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
               let accountID = auth["chatgpt_account_id"] as? String, !accountID.isEmpty {
                return accountID
            }

            if let orgs = claims["organizations"] as? [[String: Any]],
               let firstID = orgs.first?["id"] as? String, !firstID.isEmpty {
                return firstID
            }
        }
        return ""
    }

    static func emailFromJWTClaims(idToken: String?, accessToken: String?) -> String? {
        for token in [idToken, accessToken].compactMap({ $0 }).filter({ !$0.isEmpty }) {
            if let claims = jwtClaims(token),
               let email = claims["email"] as? String,
               !email.isEmpty {
                return email
            }
        }
        return nil
    }

    static func jwtExpiry(_ token: String) -> TimeInterval? {
        guard let claims = jwtClaims(token) else { return nil }
        if let exp = claims["exp"] as? Double { return exp }
        if let exp = claims["exp"] as? Int { return TimeInterval(exp) }
        if let exp = claims["exp"] as? TimeInterval { return exp }
        return nil
    }

    static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func revokeRequestBody(refreshToken: String?, accessToken: String?) -> [String: String]? {
        if let refreshToken, !refreshToken.isEmpty {
            return [
                "token": refreshToken,
                "token_type_hint": "refresh_token",
                "client_id": oauthClientID
            ]
        }
        if let accessToken, !accessToken.isEmpty {
            return [
                "token": accessToken,
                "token_type_hint": "access_token"
            ]
        }
        return nil
    }

    static func normalizedModelName(_ raw: String, default defaultName: String = "gpt-5-codex") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultName : trimmed
    }
}

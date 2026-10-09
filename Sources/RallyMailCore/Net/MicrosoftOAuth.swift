import Foundation

/// Microsoft sign-in via the OAuth 2.0 device code flow (no redirect URL or web server needed).
/// Requires an Azure app registration with "Allow public client flows" enabled.
public enum MicrosoftOAuth {
    static let authority = "https://login.microsoftonline.com/common/oauth2/v2.0"
    static let scope = "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send"

    public struct DeviceCode: Sendable {
        public var userCode: String
        public var verificationURL: URL
        public var deviceCode: String
        public var interval: Int
        public var expiresAt: Date
    }

    public struct Tokens: Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date
    }

    public struct OAuthError: LocalizedError {
        public var message: String
        public var errorDescription: String? { "Microsoft sign-in: \(message)" }
    }

    public static func startDeviceFlow(clientID: String) async throws -> DeviceCode {
        let json = try await post("devicecode", ["client_id": clientID, "scope": scope])
        guard let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init) else {
            throw OAuthError(message: json["error_description"] as? String ?? "unexpected answer")
        }
        return DeviceCode(userCode: userCode, verificationURL: uri, deviceCode: deviceCode,
                          interval: json["interval"] as? Int ?? 5,
                          expiresAt: Date().addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 900)))
    }

    /// Polls until the user finished signing in in the browser.
    public static func waitForTokens(clientID: String, code: DeviceCode) async throws -> Tokens {
        var interval = code.interval
        while Date() < code.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            let json = try await post("token", [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientID,
                "device_code": code.deviceCode,
            ])
            if let tokens = tokens(from: json) { return tokens }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            default: throw OAuthError(message: json["error_description"] as? String ?? "sign-in failed")
            }
        }
        throw OAuthError(message: "the code expired, please try again")
    }

    public static func refresh(clientID: String, refreshToken: String) async throws -> Tokens {
        let json = try await post("token", [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
            "scope": scope,
        ])
        guard let tokens = tokens(from: json) else {
            throw OAuthError(message: json["error_description"] as? String ?? "token refresh failed")
        }
        return tokens
    }

    private static func tokens(from json: [String: Any]) -> Tokens? {
        guard let access = json["access_token"] as? String else { return nil }
        return Tokens(accessToken: access, refreshToken: json["refresh_token"] as? String,
                      expiresAt: Date().addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 3600) - 60))
    }

    private static func post(_ endpoint: String, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(authority)/\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

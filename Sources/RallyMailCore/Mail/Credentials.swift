import Foundation

public enum CredentialError: LocalizedError {
    case missingPassword(String)
    case notSignedIn(String)

    public var errorDescription: String? {
        switch self {
        case .missingPassword(let email): "No password stored for \(email). Open Settings → Accounts."
        case .notSignedIn(let email): "\(email) is not signed in with Microsoft. Open Settings → Accounts."
        }
    }
}

/// Resolves login data for accounts; caches OAuth access tokens in memory.
public actor Credentials {
    public static let shared = Credentials()

    private var tokens: [UUID: MicrosoftOAuth.Tokens] = [:]

    public func auth(for account: Account) async throws -> IMAPAuth {
        switch account.auth {
        case .password:
            guard let password = Keychain.get(Keychain.passwordKey(account.id)) else {
                throw CredentialError.missingPassword(account.email)
            }
            return .password(user: account.username, password: password)
        case .microsoftOAuth:
            if let cached = tokens[account.id], cached.expiresAt > Date() {
                return .xoauth2(user: account.username, token: cached.accessToken)
            }
            guard let clientID = account.oauthClientID,
                  let refresh = Keychain.get(Keychain.refreshTokenKey(account.id)) else {
                throw CredentialError.notSignedIn(account.email)
            }
            let fresh = try await MicrosoftOAuth.refresh(clientID: clientID, refreshToken: refresh)
            store(fresh, for: account.id)
            return .xoauth2(user: account.username, token: fresh.accessToken)
        }
    }

    public func store(_ fresh: MicrosoftOAuth.Tokens, for account: UUID) {
        tokens[account] = fresh
        if let refresh = fresh.refreshToken {
            try? Keychain.set(refresh, for: Keychain.refreshTokenKey(account))
        }
    }
}

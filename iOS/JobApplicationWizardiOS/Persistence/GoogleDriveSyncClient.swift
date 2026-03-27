import Foundation
import CryptoKit
import JobApplicationShared
import AuthenticationServices
import os.log

private let syncLog = Logger(subsystem: "com.zsparks.JobApplicationWizardiOS", category: "GoogleDriveSync")

// MARK: - Google Drive Sync Implementation

/// Implements SyncClient using Google Drive REST API v3 with the appdata scope.
/// Uses OAuth 2.0 via ASWebAuthenticationSession (no Google SDK dependency).
/// Delegates all Drive API operations to the shared GoogleDriveAPI module.
enum GoogleDriveSync {

    // MARK: - Configuration

    // TODO: Replace with your OAuth client ID from Google Cloud Console
    static let clientID = GoogleDriveSecrets.clientID
    static let redirectURI = GoogleDriveSecrets.redirectURI
    static let scope = "https://www.googleapis.com/auth/drive.appdata"
    static let tokenURL = "https://oauth2.googleapis.com/token"

    // MARK: - Token Storage

    private static let tokenKey = "google_drive_refresh_token"
    private static let tokenManager = TokenManager()

    static var isAuthenticated: Bool {
        getRefreshToken() != nil
    }

    // MARK: - OAuth Flow

    /// Authenticate via OAuth 2.0 using ASWebAuthenticationSession.
    @MainActor
    static func authenticate() async throws {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let authURL = components.url!
        let callbackScheme = GoogleDriveSecrets.callbackScheme

        let callbackURL: URL = try await {
            // Create and retain the session BEFORE entering the continuation
            // to prevent ARC deallocation during presentation
            var retainedSession: ASWebAuthenticationSession?

            let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: callbackScheme
                ) { url, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let url {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: SyncStorageError.notAuthenticated)
                    }
                }
                session.prefersEphemeralWebBrowserSession = false
                session.presentationContextProvider = WebAuthContextProvider.shared
                retainedSession = session
                WebAuthContextProvider.shared.currentSession = session
                session.start()
            }

            _ = retainedSession  // prevent ARC deallocation during auth
            retainedSession = nil
            WebAuthContextProvider.shared.currentSession = nil
            return url
        }()

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw SyncStorageError.notAuthenticated
        }

        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
    }

    // MARK: - Token Management

    private static func exchangeCodeForTokens(code: String, codeVerifier: String) async throws {
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "code=\(urlEncode(code))",
            "client_id=\(urlEncode(clientID))",
            "redirect_uri=\(urlEncode(redirectURI))",
            "grant_type=authorization_code",
            "code_verifier=\(urlEncode(codeVerifier))",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let data = try await GoogleDriveAPI.checkedData(for: request)
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        await tokenManager.setToken(tokenResponse)

        if let refreshToken = tokenResponse.refresh_token {
            saveRefreshToken(refreshToken)
        }
    }

    private static func refreshAccessToken() async throws {
        guard let refreshToken = getRefreshToken() else {
            throw SyncStorageError.notAuthenticated
        }

        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "refresh_token=\(urlEncode(refreshToken))",
            "client_id=\(urlEncode(clientID))",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let data = try await GoogleDriveAPI.checkedData(for: request)
        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)

        await tokenManager.setToken(tokenResponse)
    }

    static func getValidAccessToken() async throws -> String {
        try await tokenManager.getValidToken { @Sendable in
            try await refreshAccessToken()
        }
    }

    // MARK: - Keychain Helpers

    private static func saveRefreshToken(_ token: String) {
        let data = token.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.zsparks.JobApplicationWizard.gdrive",
            kSecAttrAccount as String: tokenKey,
        ]
        SecItemDelete(query as CFDictionary)
        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func getRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.zsparks.JobApplicationWizard.gdrive",
            kSecAttrAccount as String: tokenKey,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.zsparks.JobApplicationWizard.gdrive",
            kSecAttrAccount as String: tokenKey,
        ]
        SecItemDelete(query as CFDictionary)
        Task { await tokenManager.clear() }
    }

    // MARK: - Token Provider

    private static let tokenProvider: GoogleDriveAPI.TokenProvider = {
        try await getValidAccessToken()
    }

    // MARK: - Build SyncStorageClient

    static func makeSyncStorageClient() -> SyncStorageClient {
        syncLog.info("Building SyncStorageClient for iOS")
        return GoogleDriveSyncStorage.makeClient(
            tokenProvider: tokenProvider,
            authenticate: { try await authenticate() },
            isAuthenticated: { isAuthenticated },
            signOut: { deleteRefreshToken() }
        )
    }
}

// MARK: - Token Manager (Actor)

private actor TokenManager {
    var accessToken: String?
    var accessTokenExpiry: Date?
    var refreshTask: Task<String, Error>?

    func getValidToken(refreshing: @Sendable @escaping () async throws -> Void) async throws -> String {
        if let token = accessToken, let expiry = accessTokenExpiry, expiry > Date() {
            return token
        }
        // Coalesce concurrent refresh requests
        if let existing = refreshTask {
            return try await existing.value
        }
        let task = Task<String, Error> {
            try await refreshing()
            guard let token = accessToken else {
                throw SyncStorageError.notAuthenticated
            }
            return token
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func setToken(_ response: TokenResponse) {
        accessToken = response.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(response.expires_in - 60))
    }

    func clear() {
        accessToken = nil
        accessTokenExpiry = nil
    }
}

// MARK: - ASWebAuthenticationSession Context

@MainActor
class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebAuthContextProvider()
    var currentSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

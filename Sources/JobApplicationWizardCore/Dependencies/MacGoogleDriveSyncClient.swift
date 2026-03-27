import Foundation
import CryptoKit
import AuthenticationServices
import AppKit
import os.log
import JobApplicationShared

private let syncLog = Logger(subsystem: "com.zsparks.JobApplicationWizard", category: "GoogleDriveSync")

// MARK: - macOS Google Drive Sync Implementation

/// Implements SyncClient using Google Drive REST API v3 for macOS.
/// Delegates all Drive API operations to the shared GoogleDriveAPI module.
public enum MacGoogleDriveSync {

    // MARK: - Configuration

    static let clientID = GoogleDriveSecrets.clientID
    static let redirectURI = GoogleDriveSecrets.redirectURI
    static let scope = "https://www.googleapis.com/auth/drive.appdata"
    static let tokenURL = "https://oauth2.googleapis.com/token"

    // MARK: - Token Management (actor for thread safety)

    private static let tokenManager = TokenManager()

    private actor TokenManager {
        var accessToken: String?
        var accessTokenExpiry: Date?
        private var refreshTask: Task<String, Error>?

        func getValidToken(refreshing: @escaping @Sendable () async throws -> Void) async throws -> String {
            if let token = accessToken, let expiry = accessTokenExpiry, expiry > Date() {
                return token
            }
            if let existing = refreshTask {
                return try await existing.value
            }
            let task = Task<String, Error> {
                try await refreshing()
                defer { refreshTask = nil }
                guard let token = accessToken else { throw SyncStorageError.notAuthenticated }
                return token
            }
            refreshTask = task
            return try await task.value
        }

        func setToken(_ response: TokenResponse) {
            accessToken = response.access_token
            accessTokenExpiry = Date().addingTimeInterval(TimeInterval(response.expires_in - 60))
            refreshTask = nil
        }

        func clear() {
            accessToken = nil
            accessTokenExpiry = nil
            refreshTask = nil
        }
    }

    static var isAuthenticated: Bool {
        getRefreshToken() != nil
    }

    // MARK: - OAuth Flow (macOS)

    @MainActor
    public static func authenticate() async throws {
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

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
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
            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = MacWebAuthContextProvider.shared
            MacWebAuthContextProvider.shared.currentSession = session
            session.start()
        }
        MacWebAuthContextProvider.shared.currentSession = nil

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw SyncStorageError.notAuthenticated
        }

        try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
    }

    // MARK: - Token Exchange

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
        try await tokenManager.getValidToken {
            try await refreshAccessToken()
        }
    }

    // MARK: - Keychain

    private static let keychainService = "com.zsparks.JobApplicationWizard.gdrive"
    private static let tokenKey = "google_drive_refresh_token"

    private static func saveRefreshToken(_ token: String) {
        let data = token.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
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
            kSecAttrService as String: keychainService,
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
            kSecAttrService as String: keychainService,
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

    public static func makeSyncStorageClient() -> SyncStorageClient {
        syncLog.info("Building SyncStorageClient for macOS")
        return GoogleDriveSyncStorage.makeClient(
            tokenProvider: tokenProvider,
            authenticate: { try await authenticate() },
            isAuthenticated: { isAuthenticated },
            signOut: { deleteRefreshToken() }
        )
    }
}

// MARK: - macOS Auth Context

@MainActor
class MacWebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = MacWebAuthContextProvider()
    var currentSession: ASWebAuthenticationSession?

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? ASPresentationAnchor()
    }
}

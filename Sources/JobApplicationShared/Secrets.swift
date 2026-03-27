import Foundation

/// OAuth credentials for Google Drive sync.
///
/// To enable sync, replace the placeholder values with your Google Cloud
/// Console OAuth client ID, then run:
///   git update-index --skip-worktree Sources/JobApplicationShared/Secrets.swift
/// to prevent accidentally committing your credentials.
public enum GoogleDriveSecrets {
    public static let clientID = "YOUR_OAUTH_CLIENT_ID.apps.googleusercontent.com"
    public static let redirectURI = "com.googleusercontent.apps.YOUR_OAUTH_CLIENT_ID:/oauth2callback"
    public static let callbackScheme = "com.googleusercontent.apps.YOUR_OAUTH_CLIENT_ID"

    /// True when real credentials are configured (not placeholder values).
    public static var isConfigured: Bool {
        !clientID.contains("YOUR_OAUTH_CLIENT_ID")
    }
}

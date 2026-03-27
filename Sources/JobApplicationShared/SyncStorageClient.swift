import Foundation
import ComposableArchitecture

// MARK: - Remote Version

/// An opaque version token representing the state of a remote resource.
/// Only meaningful to the storage backend that produced it (e.g., an ETag for Google Drive).
public struct RemoteVersion: Codable, Equatable, Sendable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

// MARK: - Sync Storage Client

/// Backend-agnostic contract for remote state storage with optimistic concurrency.
///
/// The contract is intentionally minimal: read, conditional write, auth.
/// All merge/conflict logic lives above this layer.
public struct SyncStorageClient: Sendable {
    /// Authenticate with the storage backend (presents sign-in UI if needed).
    public var authenticate: @Sendable () async throws -> Void

    /// Check if user is currently authenticated.
    public var isAuthenticated: @Sendable () async -> Bool

    /// Sign out and clear stored credentials.
    public var signOut: @Sendable () -> Void

    /// Read the remote state file.
    /// Returns (data, version) if the file exists, nil if no remote state yet.
    public var read: @Sendable () async throws -> (Data, RemoteVersion)?

    /// Write data to the remote state file.
    /// - Parameter data: The serialized state to upload.
    /// - Parameter ifVersion: If provided, the write is conditional; the backend
    ///   rejects it (throws `SyncStorageError.conflict`) if the remote has changed
    ///   since that version. If nil, creates the file unconditionally (first write).
    /// - Returns: The new `RemoteVersion` after a successful write.
    public var write: @Sendable (_ data: Data, _ ifVersion: RemoteVersion?) async throws -> RemoteVersion

    public init(
        authenticate: @escaping @Sendable () async throws -> Void,
        isAuthenticated: @escaping @Sendable () async -> Bool,
        signOut: @escaping @Sendable () -> Void,
        read: @escaping @Sendable () async throws -> (Data, RemoteVersion)?,
        write: @escaping @Sendable (_ data: Data, _ ifVersion: RemoteVersion?) async throws -> RemoteVersion
    ) {
        self.authenticate = authenticate
        self.isAuthenticated = isAuthenticated
        self.signOut = signOut
        self.read = read
        self.write = write
    }
}

// MARK: - Dependency Registration

extension SyncStorageClient: DependencyKey {
    /// Default: no-op (sync disabled until configured).
    public static let liveValue = SyncStorageClient(
        authenticate: { },
        isAuthenticated: { false },
        signOut: { },
        read: { nil },
        write: { _, _ in RemoteVersion(value: "") }
    )

    public static let testValue = SyncStorageClient(
        authenticate: { },
        isAuthenticated: { false },
        signOut: { },
        read: { nil },
        write: { _, _ in RemoteVersion(value: "") }
    )
}

public extension DependencyValues {
    var syncStorageClient: SyncStorageClient {
        get { self[SyncStorageClient.self] }
        set { self[SyncStorageClient.self] = newValue }
    }
}

// MARK: - Sync Storage Errors

public enum SyncStorageError: Error, LocalizedError {
    /// The remote resource changed since the provided version (HTTP 412 / ETag mismatch).
    case conflict
    /// Not signed in to the storage backend.
    case notAuthenticated
    /// Network or transport error.
    case networkError(Error)
    /// Backend-specific error.
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .conflict:
            return "Remote state changed since last read. Retrying."
        case .notAuthenticated:
            return "Not signed in to sync storage."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .storageError(let message):
            return "Storage error: \(message)"
        }
    }
}

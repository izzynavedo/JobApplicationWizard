import Foundation
import os.log

private let syncLog = Logger(subsystem: "com.zsparks.JobApplicationWizard", category: "GoogleDriveSyncStorage")

// MARK: - Google Drive Sync Storage

/// Builds a `SyncStorageClient` backed by Google Drive appDataFolder.
/// Platform-specific auth (macOS ASWebAuthenticationSession vs iOS) is injected
/// via the `tokenProvider` and auth closures.
public enum GoogleDriveSyncStorage {

    private static let stateFileName = "state.json"

    /// Build a `SyncStorageClient` using Google Drive as the backend.
    /// - Parameters:
    ///   - tokenProvider: Closure that returns a valid access token (handles refresh).
    ///   - authenticate: Platform-specific OAuth flow.
    ///   - isAuthenticated: Check if a refresh token exists.
    ///   - signOut: Clear stored credentials.
    public static func makeClient(
        tokenProvider: @escaping GoogleDriveAPI.TokenProvider,
        authenticate: @escaping @Sendable () async throws -> Void,
        isAuthenticated: @escaping @Sendable () async -> Bool,
        signOut: @escaping @Sendable () -> Void
    ) -> SyncStorageClient {
        // Track the file ID so we don't re-list on every write
        let fileIdRef = FileIdRef()

        return SyncStorageClient(
            authenticate: authenticate,
            isAuthenticated: isAuthenticated,
            signOut: signOut,
            read: {
                syncLog.info("[SyncStorage] read: looking for \(stateFileName)")
                let files = try await GoogleDriveAPI.listFiles(
                    query: "name = '\(stateFileName)'",
                    tokenProvider: tokenProvider
                )
                guard let file = files.first else {
                    syncLog.info("[SyncStorage] read: no state file found on Drive")
                    return nil
                }
                await fileIdRef.set(file.id)
                syncLog.info("[SyncStorage] read: found file id=\(file.id), version=\(file.version ?? "nil")")
                let rawData = try await GoogleDriveAPI.downloadFile(
                    fileId: file.id,
                    tokenProvider: tokenProvider
                )
                // Decompress (zlib), falling back to raw for legacy uncompressed files
                let data: Data
                if let decompressed = try? (rawData as NSData).decompressed(using: .zlib) as Data {
                    data = decompressed
                    syncLog.info("[SyncStorage] read: decompressed \(rawData.count) -> \(data.count) bytes")
                } else {
                    data = rawData
                }
                guard let version = file.version else {
                    throw SyncStorageError.storageError("Drive file missing version")
                }
                syncLog.info("[SyncStorage] read: downloaded \(data.count) bytes")
                return (data, RemoteVersion(value: version))
            },
            write: { data, ifVersion in
                let existingId = await fileIdRef.get()
                let compressed = try (data as NSData).compressed(using: .zlib) as Data
                syncLog.info("[SyncStorage] write: compressed \(data.count) -> \(compressed.count) bytes, existingId=\(existingId ?? "nil"), ifVersion=\(ifVersion?.value ?? "nil")")

                let file = try await GoogleDriveAPI.uploadFileConditional(
                    name: stateFileName,
                    data: compressed,
                    existingFileId: existingId,
                    expectedVersion: ifVersion?.value,
                    tokenProvider: tokenProvider
                )
                await fileIdRef.set(file.id)
                guard let version = file.version else {
                    throw SyncStorageError.storageError("Drive response missing version")
                }
                syncLog.info("[SyncStorage] write: success, new version=\(version)")
                return RemoteVersion(value: version)
            }
        )
    }
}

// MARK: - File ID Cache (actor for thread safety)

/// Caches the Drive file ID for state.json to avoid re-listing on every write.
private actor FileIdRef {
    private var fileId: String?

    func get() -> String? { fileId }
    func set(_ id: String) { fileId = id }
}

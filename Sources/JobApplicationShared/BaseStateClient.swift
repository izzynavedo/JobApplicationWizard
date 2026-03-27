import Foundation
import ComposableArchitecture

// MARK: - Base State Client

/// Persists the "base" state (last-known-common ancestor) and the corresponding
/// remote version locally. Used by the 3-way merge to detect which side changed what.
public struct BaseStateClient: Sendable {
    /// Load the last-known base state from disk. Returns nil on first sync.
    public var load: @Sendable () async -> SyncState?
    /// Save the merged state as the new base after a successful sync.
    public var save: @Sendable (SyncState) async throws -> Void
    /// Load the last-known remote version (ETag). Returns nil on first sync.
    public var loadVersion: @Sendable () async -> RemoteVersion?
    /// Save the remote version after a successful sync.
    public var saveVersion: @Sendable (RemoteVersion) async throws -> Void

    public init(
        load: @escaping @Sendable () async -> SyncState?,
        save: @escaping @Sendable (SyncState) async throws -> Void,
        loadVersion: @escaping @Sendable () async -> RemoteVersion?,
        saveVersion: @escaping @Sendable (RemoteVersion) async throws -> Void
    ) {
        self.load = load
        self.save = save
        self.loadVersion = loadVersion
        self.saveVersion = saveVersion
    }
}

// MARK: - Dependency Registration

extension BaseStateClient: DependencyKey {
    public static let liveValue: BaseStateClient = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JobApplicationWizard")
        let stateURL = dir.appendingPathComponent("sync-base.json")
        let versionURL = dir.appendingPathComponent("sync-version.txt")

        return BaseStateClient(
            load: {
                guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
                guard let data = try? Data(contentsOf: stateURL) else { return nil }
                return try? JSONDecoder().decode(SyncState.self, from: data)
            },
            save: { state in
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(state)
                try data.write(to: stateURL, options: .atomic)
            },
            loadVersion: {
                guard let str = try? String(contentsOf: versionURL, encoding: .utf8) else { return nil }
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : RemoteVersion(value: trimmed)
            },
            saveVersion: { version in
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try version.value.write(to: versionURL, atomically: true, encoding: .utf8)
            }
        )
    }()

    public static let testValue = BaseStateClient(
        load: { nil },
        save: { _ in },
        loadVersion: { nil },
        saveVersion: { _ in }
    )
}

public extension DependencyValues {
    var baseStateClient: BaseStateClient {
        get { self[BaseStateClient.self] }
        set { self[BaseStateClient.self] = newValue }
    }
}

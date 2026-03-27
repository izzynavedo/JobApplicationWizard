import Foundation

// MARK: - Sync State

/// The complete app state that gets serialized to a single file on the sync backend.
/// This is the unit of sync: read it, merge it, write it back.
public struct SyncState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var lastModified: Date
    public var jobs: [JobApplication]
    public var settings: AppSettings

    public init(
        version: Int = Self.currentVersion,
        lastModified: Date = Date(),
        jobs: [JobApplication] = [],
        settings: AppSettings = AppSettings()
    ) {
        self.version = version
        self.lastModified = lastModified
        self.jobs = jobs
        self.settings = settings
    }
}

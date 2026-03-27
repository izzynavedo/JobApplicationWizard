import Foundation

// MARK: - Merge Result

public enum MergeResult: Equatable, Sendable {
    /// No conflicts; merged deterministically (only one side changed each field).
    case clean(SyncState)
    /// Conflicts were resolved via last-writer-wins by updatedAt/lastModified.
    case resolved(SyncState)
}

// MARK: - State Merger

/// 3-way merge engine for SyncState.
///
/// Compares a base (last-known-common ancestor) against local and remote states.
/// Jobs are matched by UUID. Fields are compared against the base to detect
/// which side changed what. Conflicts are resolved by last-writer-wins using
/// the job's `updatedAt` timestamp.
public enum StateMerger {

    /// Merge local and remote states using the base as the common ancestor.
    /// - Parameters:
    ///   - base: The last-known-common state (nil on first sync).
    ///   - local: The current device's state.
    ///   - remote: The state read from the sync backend.
    /// - Returns: A `MergeResult` containing the merged state.
    public static func merge(
        base: SyncState?,
        local: SyncState,
        remote: SyncState
    ) -> MergeResult {
        var hadConflicts = false

        // Index jobs by ID for O(1) lookup
        let baseJobs = Dictionary((base?.jobs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let localJobs = Dictionary(local.jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let remoteJobs = Dictionary(remote.jobs.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        let allIds = Set(baseJobs.keys).union(localJobs.keys).union(remoteJobs.keys)
        var mergedJobs: [JobApplication] = []

        for id in allIds {
            let b = baseJobs[id]
            let l = localJobs[id]
            let r = remoteJobs[id]

            switch (b, l, r) {
            // Both have it: merge fields
            case (_, .some(let localJob), .some(let remoteJob)):
                let (merged, conflicted) = mergeJob(base: b, local: localJob, remote: remoteJob)
                mergedJobs.append(merged)
                if conflicted { hadConflicts = true }

            // Only local has it (added locally, or remote deleted it)
            case (.some, .some(let localJob), .none):
                // Was in base, remote deleted it. Keep if local modified it since base.
                if let baseJob = b, localJob.updatedAt > baseJob.updatedAt {
                    mergedJobs.append(localJob)
                    hadConflicts = true
                }
                // Otherwise: remote deletion wins

            case (.none, .some(let localJob), .none):
                // Not in base, not in remote: local added it
                mergedJobs.append(localJob)

            // Only remote has it (added remotely, or local deleted it)
            case (.some, .none, .some(let remoteJob)):
                if let baseJob = b, remoteJob.updatedAt > baseJob.updatedAt {
                    mergedJobs.append(remoteJob)
                    hadConflicts = true
                }

            case (.none, .none, .some(let remoteJob)):
                mergedJobs.append(remoteJob)

            // Both deleted it (or it was in base and both removed it)
            case (_, .none, .none):
                break
            }
        }

        // Settings: last-writer-wins by lastModified
        let mergedSettings: AppSettings
        if local.lastModified >= remote.lastModified {
            mergedSettings = local.settings
        } else {
            mergedSettings = remote.settings
            if local.settings != remote.settings {
                hadConflicts = true
            }
        }

        let merged = SyncState(
            lastModified: max(local.lastModified, remote.lastModified),
            jobs: mergedJobs.sorted { $0.dateAdded < $1.dateAdded },
            settings: mergedSettings
        )

        return hadConflicts ? .resolved(merged) : .clean(merged)
    }

    // MARK: - Per-Job Field Merge

    private static func mergeJob(
        base: JobApplication?,
        local: JobApplication,
        remote: JobApplication
    ) -> (JobApplication, Bool) {
        // If identical, no merge needed
        if local == remote { return (local, false) }

        // If no base, or base matches one side, take the other
        if let base = base {
            if base == local { return (remote, false) }
            if base == remote { return (local, false) }
        }

        // Both sides differ from base: merge field by field
        var merged = local
        var hadConflict = false

        // Determine the "winner" for conflicting fields: whichever job was updated more recently
        let localWins = local.updatedAt >= remote.updatedAt

        func pick<T: Equatable>(_ keyPath: WritableKeyPath<JobApplication, T>) {
            let baseVal = base?[keyPath: keyPath]
            let localVal = local[keyPath: keyPath]
            let remoteVal = remote[keyPath: keyPath]

            let localChanged = baseVal == nil || localVal != baseVal
            let remoteChanged = baseVal == nil || remoteVal != baseVal

            if localChanged && remoteChanged && localVal != remoteVal {
                // Both changed to different values: conflict
                merged[keyPath: keyPath] = localWins ? localVal : remoteVal
                hadConflict = true
            } else if remoteChanged && !localChanged {
                // Only remote changed
                merged[keyPath: keyPath] = remoteVal
            }
            // If only local changed (or neither), merged already has local's value
        }

        pick(\.company)
        pick(\.title)
        pick(\.url)
        pick(\.status)
        pick(\.dateApplied)
        pick(\.salary)
        pick(\.location)
        pick(\.jobDescription)
        pick(\.resumeUsed)
        pick(\.coverLetter)
        pick(\.isFavorite)
        pick(\.excitement)
        pick(\.hasPDF)
        pick(\.pdfPath)
        pick(\.atsProvider)

        // Array sub-items: merge by UUID
        let (mergedNotes, notesConflict) = mergeArray(
            base: base?.noteCards ?? [], local: local.noteCards, remote: remote.noteCards, localWins: localWins
        )
        merged.noteCards = mergedNotes
        if notesConflict { hadConflict = true }

        let (mergedContacts, contactsConflict) = mergeArray(
            base: base?.contacts ?? [], local: local.contacts, remote: remote.contacts, localWins: localWins
        )
        merged.contacts = mergedContacts
        if contactsConflict { hadConflict = true }

        let (mergedInterviews, interviewsConflict) = mergeArray(
            base: base?.interviews ?? [], local: local.interviews, remote: remote.interviews, localWins: localWins
        )
        merged.interviews = mergedInterviews
        if interviewsConflict { hadConflict = true }

        let (mergedTasks, tasksConflict) = mergeArray(
            base: base?.tasks ?? [], local: local.tasks, remote: remote.tasks, localWins: localWins
        )
        merged.tasks = mergedTasks
        if tasksConflict { hadConflict = true }

        let (mergedLabels, labelsConflict) = mergeArray(
            base: base?.labels ?? [], local: local.labels, remote: remote.labels, localWins: localWins
        )
        merged.labels = mergedLabels
        if labelsConflict { hadConflict = true }

        let (mergedDocuments, docsConflict) = mergeArray(
            base: base?.documents ?? [], local: local.documents, remote: remote.documents, localWins: localWins
        )
        merged.documents = mergedDocuments
        if docsConflict { hadConflict = true }

        merged.updatedAt = max(local.updatedAt, remote.updatedAt)

        return (merged, hadConflict)
    }

    // MARK: - Array Sub-Item Merge

    /// Merge arrays of Identifiable + Equatable items by their ID.
    private static func mergeArray<T: Identifiable & Equatable>(
        base: [T],
        local: [T],
        remote: [T],
        localWins: Bool
    ) -> ([T], Bool) where T.ID: Hashable {
        let baseById = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let localById = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let remoteById = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        let allIds = Set(baseById.keys).union(localById.keys).union(remoteById.keys)
        var result: [T] = []
        var hadConflict = false

        for id in allIds {
            let b = baseById[id]
            let l = localById[id]
            let r = remoteById[id]

            switch (b, l, r) {
            case (_, .some(let lv), .some(let rv)):
                if lv == rv {
                    result.append(lv)
                } else if let bv = b {
                    if lv == bv { result.append(rv) }
                    else if rv == bv { result.append(lv) }
                    else {
                        // Both modified: last-writer-wins
                        result.append(localWins ? lv : rv)
                        hadConflict = true
                    }
                } else {
                    // No base, both added same ID with different content
                    result.append(localWins ? lv : rv)
                    hadConflict = true
                }

            case (.some, .some(let lv), .none):
                // In base, remote deleted, local still has it
                if let bv = b, lv != bv {
                    // Local modified it; keep local's version (conflict)
                    result.append(lv)
                    hadConflict = true
                }
                // Otherwise remote deletion wins

            case (.none, .some(let lv), .none):
                // Local added
                result.append(lv)

            case (.some, .none, .some(let rv)):
                if let bv = b, rv != bv {
                    result.append(rv)
                    hadConflict = true
                }

            case (.none, .none, .some(let rv)):
                result.append(rv)

            case (_, .none, .none):
                break
            }
        }

        // Preserve local ordering for items that were in local, append remote-only items at end
        let localOrder = local.map(\.id)
        let localSet = Set(localOrder)
        let resultById = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var ordered: [T] = []
        for id in localOrder {
            if let item = resultById[id] {
                ordered.append(item)
            }
        }
        for item in result where !localSet.contains(item.id) {
            ordered.append(item)
        }

        return (ordered, hadConflict)
    }
}

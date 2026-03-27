import XCTest
@testable import JobApplicationShared

final class StateMergerTests: XCTestCase {

    // Helper to create a minimal job
    private func makeJob(
        id: UUID = UUID(),
        company: String = "Test Co",
        title: String = "Engineer",
        status: JobStatus = .wishlist,
        updatedAt: Date = Date()
    ) -> JobApplication {
        var job = JobApplication()
        job.id = id
        job.company = company
        job.title = title
        job.status = status
        job.updatedAt = updatedAt
        return job
    }

    private func makeState(
        jobs: [JobApplication] = [],
        lastModified: Date = Date()
    ) -> SyncState {
        SyncState(lastModified: lastModified, jobs: jobs, settings: AppSettings())
    }

    // MARK: - Clean merges (no conflicts)

    func testCleanMerge_noChanges() {
        let job = makeJob()
        let base = makeState(jobs: [job])
        let result = StateMerger.merge(base: base, local: base, remote: base)
        if case .clean(let merged) = result {
            XCTAssertEqual(merged.jobs.count, 1)
        } else {
            XCTFail("Expected clean merge")
        }
    }

    func testCleanMerge_localAddsJob() {
        let existingJob = makeJob(company: "Existing")
        let newJob = makeJob(company: "New Local")
        let base = makeState(jobs: [existingJob])
        let local = makeState(jobs: [existingJob, newJob])
        let remote = base
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        if case .clean(let merged) = result {
            XCTAssertEqual(merged.jobs.count, 2)
            XCTAssert(merged.jobs.contains(where: { $0.company == "New Local" }))
        } else {
            XCTFail("Expected clean merge")
        }
    }

    func testCleanMerge_remoteAddsJob() {
        let existingJob = makeJob(company: "Existing")
        let newJob = makeJob(company: "New Remote")
        let base = makeState(jobs: [existingJob])
        let local = base
        let remote = makeState(jobs: [existingJob, newJob])
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        if case .clean(let merged) = result {
            XCTAssertEqual(merged.jobs.count, 2)
            XCTAssert(merged.jobs.contains(where: { $0.company == "New Remote" }))
        } else {
            XCTFail("Expected clean merge")
        }
    }

    func testCleanMerge_bothAddDifferentJobs() {
        let existingJob = makeJob(company: "Existing")
        let localNew = makeJob(company: "Local New")
        let remoteNew = makeJob(company: "Remote New")
        let base = makeState(jobs: [existingJob])
        let local = makeState(jobs: [existingJob, localNew])
        let remote = makeState(jobs: [existingJob, remoteNew])
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        // Both should be in the result (clean or resolved, both additions preserved)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        XCTAssertEqual(merged.jobs.count, 3)
        XCTAssert(merged.jobs.contains(where: { $0.company == "Local New" }))
        XCTAssert(merged.jobs.contains(where: { $0.company == "Remote New" }))
    }

    func testCleanMerge_localDeletesJob() {
        let job1 = makeJob(company: "Keep")
        let job2 = makeJob(company: "Delete")
        let base = makeState(jobs: [job1, job2])
        let local = makeState(jobs: [job1]) // deleted job2
        let remote = base
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        if case .clean(let merged) = result {
            XCTAssertEqual(merged.jobs.count, 1)
            XCTAssertEqual(merged.jobs.first?.company, "Keep")
        } else {
            XCTFail("Expected clean merge")
        }
    }

    func testCleanMerge_remoteDeletesJob() {
        let job1 = makeJob(company: "Keep")
        let job2 = makeJob(company: "Delete")
        let base = makeState(jobs: [job1, job2])
        let local = base
        let remote = makeState(jobs: [job1])
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        if case .clean(let merged) = result {
            XCTAssertEqual(merged.jobs.count, 1)
            XCTAssertEqual(merged.jobs.first?.company, "Keep")
        } else {
            XCTFail("Expected clean merge")
        }
    }

    func testCleanMerge_onlyLocalChangedField() {
        let id = UUID()
        let baseJob = makeJob(id: id, company: "Old", updatedAt: Date(timeIntervalSince1970: 100))
        var localJob = baseJob
        localJob.company = "Updated"
        localJob.updatedAt = Date(timeIntervalSince1970: 200)
        let base = makeState(jobs: [baseJob])
        let local = makeState(jobs: [localJob])
        let remote = base
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        if case .clean(let merged) = result {
            XCTAssertEqual(merged.jobs.first?.company, "Updated")
        } else {
            XCTFail("Expected clean merge")
        }
    }

    func testCleanMerge_onlyRemoteChangedField() {
        let id = UUID()
        let baseJob = makeJob(id: id, company: "Old", updatedAt: Date(timeIntervalSince1970: 100))
        var remoteJob = baseJob
        remoteJob.company = "Updated"
        remoteJob.updatedAt = Date(timeIntervalSince1970: 200)
        let base = makeState(jobs: [baseJob])
        let local = base
        let remote = makeState(jobs: [remoteJob])
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        if case .clean(let merged) = result {
            XCTAssertEqual(merged.jobs.first?.company, "Updated")
        } else {
            XCTFail("Expected clean merge")
        }
    }

    // MARK: - Conflict resolution

    func testConflict_bothChangedSameField_laterUpdatedAtWins() {
        let id = UUID()
        let baseJob = makeJob(id: id, company: "Old", updatedAt: Date(timeIntervalSince1970: 100))
        var localJob = baseJob
        localJob.company = "Local Version"
        localJob.updatedAt = Date(timeIntervalSince1970: 200)
        var remoteJob = baseJob
        remoteJob.company = "Remote Version"
        remoteJob.updatedAt = Date(timeIntervalSince1970: 300) // remote is newer
        let base = makeState(jobs: [baseJob])
        let local = makeState(jobs: [localJob])
        let remote = makeState(jobs: [remoteJob])
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        if case .resolved(let merged) = result {
            XCTAssertEqual(merged.jobs.first?.company, "Remote Version")
        } else {
            XCTFail("Expected resolved merge")
        }
    }

    func testConflict_bothChangedDifferentFields_bothPreserved() {
        let id = UUID()
        let baseJob = makeJob(id: id, company: "Base Co", title: "Base Title", updatedAt: Date(timeIntervalSince1970: 100))
        var localJob = baseJob
        localJob.company = "Local Co"
        localJob.updatedAt = Date(timeIntervalSince1970: 200)
        var remoteJob = baseJob
        remoteJob.title = "Remote Title"
        remoteJob.updatedAt = Date(timeIntervalSince1970: 200)
        let base = makeState(jobs: [baseJob])
        let local = makeState(jobs: [localJob])
        let remote = makeState(jobs: [remoteJob])
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        XCTAssertEqual(merged.jobs.first?.company, "Local Co")
        XCTAssertEqual(merged.jobs.first?.title, "Remote Title")
    }

    // MARK: - Nil base (first sync)

    func testNilBase_localAndRemoteSameJobs() {
        let job = makeJob()
        let local = makeState(jobs: [job])
        let remote = makeState(jobs: [job])
        let result = StateMerger.merge(base: nil, local: local, remote: remote)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        XCTAssertEqual(merged.jobs.count, 1)
    }

    func testNilBase_differentJobs_bothKept() {
        let localJob = makeJob(company: "Local")
        let remoteJob = makeJob(company: "Remote")
        let local = makeState(jobs: [localJob])
        let remote = makeState(jobs: [remoteJob])
        let result = StateMerger.merge(base: nil, local: local, remote: remote)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        XCTAssertEqual(merged.jobs.count, 2)
    }

    // MARK: - Array sub-item merges

    func testNotesMerge_localAddsNote() {
        let id = UUID()
        let baseJob = makeJob(id: id, updatedAt: Date(timeIntervalSince1970: 100))
        var localJob = baseJob
        localJob.noteCards = [Note(title: "New Note", body: "Content")]
        localJob.updatedAt = Date(timeIntervalSince1970: 200)
        let base = makeState(jobs: [baseJob])
        let local = makeState(jobs: [localJob])
        let remote = base
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        XCTAssertEqual(merged.jobs.first?.noteCards.count, 1)
        XCTAssertEqual(merged.jobs.first?.noteCards.first?.title, "New Note")
    }

    func testNotesMerge_bothAddDifferentNotes() {
        let id = UUID()
        let baseJob = makeJob(id: id, updatedAt: Date(timeIntervalSince1970: 100))
        var localJob = baseJob
        localJob.noteCards = [Note(title: "Local Note", body: "")]
        localJob.updatedAt = Date(timeIntervalSince1970: 200)
        var remoteJob = baseJob
        remoteJob.noteCards = [Note(title: "Remote Note", body: "")]
        remoteJob.updatedAt = Date(timeIntervalSince1970: 200)
        let base = makeState(jobs: [baseJob])
        let local = makeState(jobs: [localJob])
        let remote = makeState(jobs: [remoteJob])
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        XCTAssertEqual(merged.jobs.first?.noteCards.count, 2)
    }

    // MARK: - Delete vs modify conflict

    func testDeleteVsModify_localDeletedRemoteModified_remoteWins() {
        let id = UUID()
        let baseJob = makeJob(id: id, company: "Original", updatedAt: Date(timeIntervalSince1970: 100))
        var remoteJob = baseJob
        remoteJob.company = "Modified"
        remoteJob.updatedAt = Date(timeIntervalSince1970: 200)
        let base = makeState(jobs: [baseJob])
        let local = makeState(jobs: []) // deleted
        let remote = makeState(jobs: [remoteJob])
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        // Remote modified after base, so remote should win (job preserved)
        XCTAssertEqual(merged.jobs.count, 1)
        XCTAssertEqual(merged.jobs.first?.company, "Modified")
    }

    func testDeleteVsModify_localDeletedRemoteUnmodified_deleteWins() {
        let id = UUID()
        let baseJob = makeJob(id: id, updatedAt: Date(timeIntervalSince1970: 100))
        let base = makeState(jobs: [baseJob])
        let local = makeState(jobs: []) // deleted
        let remote = base // unchanged
        let result = StateMerger.merge(base: base, local: local, remote: remote)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        XCTAssertEqual(merged.jobs.count, 0)
    }

    // MARK: - Duplicate ID safety

    func testDuplicateIDs_doesNotCrash() {
        let job1 = makeJob(company: "First")
        var job2 = makeJob(company: "Second")
        job2.id = job1.id // duplicate ID
        let state = makeState(jobs: [job1, job2])
        // Should not crash (uniquingKeysWith handles it)
        let result = StateMerger.merge(base: nil, local: state, remote: state)
        let merged: SyncState
        switch result {
        case .clean(let s): merged = s
        case .resolved(let s): merged = s
        }
        XCTAssertEqual(merged.jobs.count, 1) // deduplicated
    }
}

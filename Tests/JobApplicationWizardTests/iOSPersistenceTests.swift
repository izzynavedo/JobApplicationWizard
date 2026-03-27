import XCTest
import ComposableArchitecture
import JobApplicationShared
@testable import JobApplicationWizardCore

/// Tests for iOS-side persistence and state logic.
/// These test the shared types used by the iOS app without importing the iOS target directly.
final class iOSPersistenceTests: XCTestCase {

    // MARK: - SharedPersistenceClient Export/Import Round-Trip

    func testExportImportRoundTrip() throws {
        let job = JobApplication.mock(
            noteCards: [Note(title: "Test", body: "Note body")],
            labels: [JobLabel(name: "Remote", colorHex: "#34C759")],
            contacts: [Contact(name: "Alice", title: "Recruiter")],
            interviews: [InterviewRound(round: 1, type: "Phone")],
            tasks: [SubTask(title: "Apply", forStatus: .applied)]
        )
        var settings = AppSettings()
        settings.userProfile.name = "Test User"

        let export = AppDataExport(jobs: [job], settings: settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(export)

        let decoded = try JSONDecoder().decode(AppDataExport.self, from: data)

        XCTAssertEqual(decoded.jobs.count, 1)
        XCTAssertEqual(decoded.jobs[0].id, job.id)
        XCTAssertEqual(decoded.jobs[0].company, "Acme Corp")
        XCTAssertEqual(decoded.jobs[0].noteCards.count, 1)
        XCTAssertEqual(decoded.jobs[0].labels.count, 1)
        XCTAssertEqual(decoded.jobs[0].contacts.count, 1)
        XCTAssertEqual(decoded.jobs[0].interviews.count, 1)
        XCTAssertEqual(decoded.jobs[0].tasks.count, 1)
        XCTAssertEqual(decoded.settings.userProfile.name, "Test User")
    }

    // MARK: - Filtered Jobs Logic

    func testFilteredJobsByStatus() {
        let wishlist = JobApplication.mock(
            id: UUID(), company: "WishCo", status: .wishlist
        )
        let applied = JobApplication.mock(
            id: UUID(), company: "AppliedCo", status: .applied
        )
        let jobs: IdentifiedArrayOf<JobApplication> = [wishlist, applied]

        let filtered = jobs.filter { $0.status == .wishlist }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.company, "WishCo")
    }

    func testFilteredJobsBySearch() {
        let acme = JobApplication.mock(
            id: UUID(), company: "Acme Corp", title: "Engineer"
        )
        let globex = JobApplication.mock(
            id: UUID(), company: "Globex Inc", title: "Designer"
        )
        let jobs: IdentifiedArrayOf<JobApplication> = [acme, globex]

        let query = "globex"
        let filtered = jobs.filter {
            $0.company.localizedCaseInsensitiveContains(query)
            || $0.title.localizedCaseInsensitiveContains(query)
            || $0.location.localizedCaseInsensitiveContains(query)
        }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.company, "Globex Inc")
    }

    func testFilteredJobsBySearchMatchesTitle() {
        let job = JobApplication.mock(
            id: UUID(), company: "SomeCo", title: "iOS Engineer"
        )
        let jobs: IdentifiedArrayOf<JobApplication> = [job]

        let query = "ios"
        let filtered = jobs.filter {
            $0.company.localizedCaseInsensitiveContains(query)
            || $0.title.localizedCaseInsensitiveContains(query)
            || $0.location.localizedCaseInsensitiveContains(query)
        }
        XCTAssertEqual(filtered.count, 1)
    }

    func testFilteredJobsBySearchMatchesLocation() {
        let job = JobApplication.mock(
            id: UUID(), company: "SomeCo", location: "San Francisco"
        )
        let jobs: IdentifiedArrayOf<JobApplication> = [job]

        let query = "francisco"
        let filtered = jobs.filter {
            $0.company.localizedCaseInsensitiveContains(query)
            || $0.title.localizedCaseInsensitiveContains(query)
            || $0.location.localizedCaseInsensitiveContains(query)
        }
        XCTAssertEqual(filtered.count, 1)
    }

    func testEmptySearchReturnsAll() {
        let job1 = JobApplication.mock(id: UUID(), company: "A")
        let job2 = JobApplication.mock(id: UUID(), company: "B")
        let jobs: IdentifiedArrayOf<JobApplication> = [job1, job2]

        let query = ""
        let filtered = query.isEmpty ? Array(jobs) : jobs.filter {
            $0.company.localizedCaseInsensitiveContains(query)
        }
        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - Job Mutation State Changes

    func testMoveJobUpdatesStatus() {
        var jobs: IdentifiedArrayOf<JobApplication> = [JobApplication.mock(status: .wishlist)]
        let id = jobs.first!.id

        jobs[id: id]?.status = .applied
        XCTAssertEqual(jobs[id: id]?.status, .applied)
    }

    func testToggleFavorite() {
        var jobs: IdentifiedArrayOf<JobApplication> = [JobApplication.mock(isFavorite: false)]
        let id = jobs.first!.id

        jobs[id: id]?.isFavorite.toggle()
        XCTAssertEqual(jobs[id: id]?.isFavorite, true)

        jobs[id: id]?.isFavorite.toggle()
        XCTAssertEqual(jobs[id: id]?.isFavorite, false)
    }

    func testAddAndDeleteJob() {
        var jobs: IdentifiedArrayOf<JobApplication> = []

        let job = JobApplication.mock()
        jobs.append(job)
        XCTAssertEqual(jobs.count, 1)

        jobs.remove(id: job.id)
        XCTAssertEqual(jobs.count, 0)
    }

    func testAddNote() {
        var jobs: IdentifiedArrayOf<JobApplication> = [JobApplication.mock()]
        let id = jobs.first!.id
        let note = Note(title: "Test", body: "Content")

        jobs[id: id]?.noteCards.append(note)
        XCTAssertEqual(jobs[id: id]?.noteCards.count, 1)
        XCTAssertEqual(jobs[id: id]?.noteCards.first?.title, "Test")
    }

    // MARK: - Import Data

    func testImportValidData() throws {
        let job = JobApplication.mock()
        let export = AppDataExport(jobs: [job], settings: AppSettings())
        let data = try JSONEncoder().encode(export)

        let decoded = try JSONDecoder().decode(AppDataExport.self, from: data)
        XCTAssertEqual(decoded.jobs.count, 1)
    }

    func testImportInvalidDataThrows() {
        let badData = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(AppDataExport.self, from: badData))
    }
}

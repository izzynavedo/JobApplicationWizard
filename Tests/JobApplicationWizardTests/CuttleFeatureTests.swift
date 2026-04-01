import ComposableArchitecture
import JobApplicationShared
import XCTest
@testable import JobApplicationWizardCore

@MainActor
final class CuttleFeatureTests: XCTestCase {

    // MARK: - Helpers

    private static let jobA = JobApplication.mock(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
        company: "Alpha", title: "Engineer", status: .interview
    )
    private static let jobB = JobApplication.mock(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
        company: "Beta", title: "Manager", status: .rejected
    )

    // MARK: - Toggle Expanded / Collapse

    func testToggleExpanded() async {
        let store = TestStore(initialState: CuttleFeature.State()) { CuttleFeature() }

        await store.send(.toggleExpanded) { $0.isExpanded = true }
        await store.send(.toggleExpanded) { $0.isExpanded = false }
    }

    func testCollapse() async {
        var state = CuttleFeature.State()
        state.isExpanded = true
        let store = TestStore(initialState: state) { CuttleFeature() }

        await store.send(.collapse) { $0.isExpanded = false }
    }

    // MARK: - Drag Changed

    func testDragChangedUpdatesPositionAndMood() async {
        let store = TestStore(initialState: CuttleFeature.State()) { CuttleFeature() }

        await store.send(.dragChanged(CGPoint(x: 100, y: 200))) {
            $0.isDragging = true
            $0.mood = .listening
            $0.position = CGPoint(x: 100, y: 200)
        }
    }

    func testDragChangedDetectsDropZone() async {
        var state = CuttleFeature.State()
        state.dropZones = [
            DropZone(id: "global", frame: CGRect(x: 50, y: 50, width: 100, height: 40), context: .global)
        ]
        let store = TestStore(initialState: state) { CuttleFeature() }

        await store.send(.dragChanged(CGPoint(x: 100, y: 70))) {
            $0.isDragging = true
            $0.mood = .listening
            $0.position = CGPoint(x: 100, y: 70)
            $0.pendingContext = .global
        }
    }

    func testDragChangedPrefersSpecificDropZone() async {
        let jobId = Self.jobA.id
        var state = CuttleFeature.State()
        // Overlapping zones: a status zone and a job zone inside it
        state.dropZones = [
            DropZone(id: "status-Interview", frame: CGRect(x: 0, y: 0, width: 300, height: 200), context: .status(.interview)),
            DropZone(id: "job-A", frame: CGRect(x: 50, y: 50, width: 100, height: 60), context: .job(jobId)),
        ]
        let store = TestStore(initialState: state) { CuttleFeature() }

        // Drag into the overlapping area; job should win over status
        await store.send(.dragChanged(CGPoint(x: 80, y: 70))) {
            $0.isDragging = true
            $0.mood = .listening
            $0.position = CGPoint(x: 80, y: 70)
            $0.pendingContext = .job(jobId)
        }
    }

    func testDragChangedClearsPendingWhenOutsideZones() async {
        var state = CuttleFeature.State()
        state.isDragging = true
        state.pendingContext = .global
        state.dropZones = [
            DropZone(id: "global", frame: CGRect(x: 50, y: 50, width: 100, height: 40), context: .global)
        ]
        let store = TestStore(initialState: state) { CuttleFeature() }

        await store.send(.dragChanged(CGPoint(x: 500, y: 500))) {
            $0.mood = .listening
            $0.position = CGPoint(x: 500, y: 500)
            $0.pendingContext = nil
        }
    }

    // MARK: - Drag Ended

    func testDragEndedSwitchesSilentlyWithEmptyChat() async {
        var state = CuttleFeature.State()
        state.isDragging = true
        state.pendingContext = .status(.interview)
        state.currentContext = .global
        state.chatMessages = []
        let store = TestStore(initialState: state) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.dragEnded(CGPoint(x: 100, y: 100)))

        XCTAssertEqual(store.state.currentContext, .status(.interview))
        XCTAssertFalse(store.state.isDragging)
        XCTAssertNil(store.state.pendingContext)
    }

    func testDragEndedSwitchesContextSilentlyWithActiveChat() async {
        var state = CuttleFeature.State()
        state.isDragging = true
        state.pendingContext = .status(.rejected)
        state.currentContext = .global
        state.chatMessages = [ChatMessage(role: .user, content: "Hello")]
        let store = TestStore(initialState: state) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.dragEnded(CGPoint(x: 100, y: 100)))

        XCTAssertFalse(store.state.isDragging)
        XCTAssertNil(store.state.pendingContext)
        XCTAssertTrue(store.state.isExpanded)
        XCTAssertEqual(store.state.currentContext, .status(.rejected))
    }

    func testDragEndedExpandsWhenDocking() async {
        var state = CuttleFeature.State()
        state.isDragging = true
        state.isExpanded = false
        state.pendingContext = .global
        state.currentContext = .global
        state.chatMessages = []
        let store = TestStore(initialState: state) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.dragEnded(CGPoint(x: 100, y: 100)))

        XCTAssertTrue(store.state.isExpanded)
    }

    func testDragEndedClampsWhenNoPendingContext() async {
        var state = CuttleFeature.State()
        state.isDragging = true
        state.pendingContext = nil
        state.windowSize = CGSize(width: 800, height: 600)
        state.position = CGPoint(x: 900, y: 700)
        let store = TestStore(initialState: state) { CuttleFeature() }

        await store.send(.dragEnded(CGPoint(x: 900, y: 700))) {
            $0.isDragging = false
            $0.mood = .idle
            $0.position = CGPoint(x: 776, y: 576)  // clamped: 800 - 24, 600 - 24
        }
    }

    // MARK: - Switch Context (silent)

    func testSwitchContextSavesAndLoadsHistory() async {
        let interviewSession = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .assistant, content: "Interview msg")]
        )
        var state = CuttleFeature.State()
        state.currentContext = .global
        state.chatMessages = [ChatMessage(role: .user, content: "Global msg")]
        state.activeSessionID = UUID()
        state.globalChatSessions = [ChatSession(id: state.activeSessionID!, providerType: .claudeAPI, messages: state.chatMessages)]
        state.statusChatSessions = ["Interview": [interviewSession]]
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
        }
        store.exhaustivity = .off

        await store.send(.switchContext(.status(.interview)))

        // Session synced for global context
        XCTAssertEqual(store.state.globalChatSessions.count, 1)
        XCTAssertEqual(store.state.globalChatSessions[0].messages[0].content, "Global msg")
        // Interview session loaded
        XCTAssertEqual(store.state.currentContext, .status(.interview))
        XCTAssertEqual(store.state.chatMessages.count, 1)
        XCTAssertEqual(store.state.chatMessages[0].content, "Interview msg")
        XCTAssertFalse(store.state.acpSentSystemPrompt)
    }

    func testSwitchContextCancelsInFlightAI() async {
        var state = CuttleFeature.State()
        state.currentContext = .global
        state.isLoading = true
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
        }
        store.exhaustivity = .off

        await store.send(.switchContext(.status(.offer)))

        XCTAssertFalse(store.state.isLoading)
        XCTAssertEqual(store.state.currentContext, .status(.offer))
    }

    // MARK: - Send Message

    func testSendMessageAppendsAndCallsAPI() async {
        var state = CuttleFeature.State()
        state.apiKey = "test-key"
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
            $0.claudeClient.chat = { _, _, _, _ in
                ("AI response", AITokenUsage(inputTokens: 10, outputTokens: 20), nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.sendMessage("Hello"))
        await store.receive(\.aiResponseReceived)

        XCTAssertFalse(store.state.isLoading)
        XCTAssertEqual(store.state.chatMessages.count, 2)
        XCTAssertEqual(store.state.chatMessages[0].role, .user)
        XCTAssertEqual(store.state.chatMessages[0].content, "Hello")
        XCTAssertEqual(store.state.chatMessages[1].role, .assistant)
        XCTAssertEqual(store.state.chatMessages[1].content, "AI response")
        XCTAssertEqual(store.state.chatInput, "")
    }

    func testSendMessageEmptyDoesNothing() async {
        let store = TestStore(initialState: CuttleFeature.State()) { CuttleFeature() }
        await store.send(.sendMessage("   "))
    }

    func testSendMessageAccumulatesTokens() async {
        var state = CuttleFeature.State()
        state.apiKey = "test-key"
        state.tokenUsage = AITokenUsage(inputTokens: 100, outputTokens: 200)
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
            $0.claudeClient.chat = { _, _, _, _ in
                ("Response", AITokenUsage(inputTokens: 50, outputTokens: 75), nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.sendMessage("More"))
        await store.receive(\.aiResponseReceived)

        XCTAssertEqual(store.state.tokenUsage.inputTokens, 150)
        XCTAssertEqual(store.state.tokenUsage.outputTokens, 275)
    }

    func testSendMessageErrorSetsErrorAndSavesHistory() async {
        var state = CuttleFeature.State()
        state.apiKey = "key"
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
            $0.claudeClient.chat = { _, _, _, _ in throw AIError.noAPIKey }
        }
        store.exhaustivity = .off

        await store.send(.sendMessage("Hello"))
        await store.receive(\.aiResponseReceived)

        XCTAssertFalse(store.state.isLoading)
        XCTAssertNotNil(store.state.error)
        // User message preserved (session created on failure)
        XCTAssertFalse(store.state.globalChatSessions.isEmpty)
    }

    // MARK: - AI Response with Job Context (delegate)

    func testAIResponseInJobContextSendsDelegate() async {
        let job = Self.jobA
        var state = CuttleFeature.State()
        state.currentContext = .job(job.id)
        state.jobs = [job]
        state.apiKey = "test-key"
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
            $0.claudeClient.chat = { _, _, _, _ in
                ("AI response", AITokenUsage(inputTokens: 10, outputTokens: 20), nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.sendMessage("Analyze my fit"))
        await store.receive(\.aiResponseReceived)
        // Should receive a delegate to persist job chat
        await store.receive(\.delegate.jobChatUpdated)

        XCTAssertEqual(store.state.chatMessages.count, 2)
    }

    // MARK: - Clear Chat

    func testClearChat() async {
        var state = CuttleFeature.State()
        state.currentContext = .global
        state.chatMessages = [ChatMessage(role: .user, content: "test")]
        state.chatInput = "something"
        state.error = "some error"
        state.tokenUsage = AITokenUsage(inputTokens: 100, outputTokens: 200)
        state.acpSentSystemPrompt = true
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
        }
        store.exhaustivity = .off

        await store.send(.clearChat)

        XCTAssertTrue(store.state.chatMessages.isEmpty)
        XCTAssertEqual(store.state.chatInput, "")
        XCTAssertNil(store.state.error)
        XCTAssertEqual(store.state.tokenUsage, .zero)
        XCTAssertFalse(store.state.acpSentSystemPrompt)
    }

    // MARK: - Apply Suggestion

    func testApplySuggestionSendsMessage() async {
        var state = CuttleFeature.State()
        state.apiKey = "test-key"
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
            $0.claudeClient.chat = { _, _, _, _ in
                ("Response", AITokenUsage(inputTokens: 10, outputTokens: 20), nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.applySuggestion("Analyze my fit"))
        // applySuggestion dispatches sendMessage, which we need to receive
        await store.receive(\.sendMessage)
        await store.receive(\.aiResponseReceived)

        XCTAssertEqual(store.state.chatMessages.count, 2)
        XCTAssertEqual(store.state.chatMessages[0].content, "Analyze my fit")
    }

    // MARK: - Restore From Settings

    func testRestoreFromSettings() async {
        let interviewSession = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .assistant, content: "Interview chat")]
        )
        let globalSessions: [ChatSession] = [ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Saved")]
        )]
        let statusSessions = ["Interview": [interviewSession]]
        let store = TestStore(initialState: CuttleFeature.State()) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.restoreFromSettings(.status(.interview), globalSessions, statusSessions))

        XCTAssertEqual(store.state.currentContext, .status(.interview))
        XCTAssertEqual(store.state.globalChatSessions.count, 1)
        XCTAssertEqual(store.state.statusChatSessions["Interview"]?.count, 1)
    }

    func testRestoreGlobalContext() async {
        let globalSessions = [ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Global msg")]
        )]
        let store = TestStore(initialState: CuttleFeature.State()) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.restoreFromSettings(.global, globalSessions, [:]))

        XCTAssertEqual(store.state.currentContext, .global)
        XCTAssertEqual(store.state.globalChatSessions.count, 1)
    }

    // MARK: - Position At Drop Zone

    func testPositionAtDropZone() async {
        var state = CuttleFeature.State()
        state.currentContext = .global
        state.dropZones = [
            DropZone(id: "global", frame: CGRect(x: 100, y: 50, width: 80, height: 30), context: .global)
        ]
        let store = TestStore(initialState: state) { CuttleFeature() }

        await store.send(.positionAtDropZone) {
            $0.position = CGPoint(x: 140, y: 65)  // center of the drop zone
        }
    }

    // MARK: - Drop Zones Updated

    func testDropZonesUpdated() async {
        let zones = [
            DropZone(id: "global", frame: CGRect(x: 0, y: 0, width: 100, height: 40), context: .global)
        ]
        let store = TestStore(initialState: CuttleFeature.State()) { CuttleFeature() }

        await store.send(.dropZonesUpdated(zones)) {
            $0.dropZones = zones
            // Snaps to the docked zone (global) center
            $0.position = CGPoint(x: 50, y: 20)
        }
    }

    // MARK: - Window Size Changed

    func testWindowSizeChangedClampsPosition() async {
        var state = CuttleFeature.State()
        state.position = CGPoint(x: 900, y: 700)
        let store = TestStore(initialState: state) { CuttleFeature() }

        await store.send(.windowSizeChanged(CGSize(width: 800, height: 600))) {
            $0.windowSize = CGSize(width: 800, height: 600)
            $0.position = CGPoint(x: 776, y: 576)
        }
    }

    // MARK: - Chat Session Persistence

    func testSavePrunesOnContextSwitch() async {
        let messages = (0..<110).map { i in
            ChatMessage(role: .user, content: "Message \(i)")
        }
        let session = ChatSession(providerType: .claudeAPI, messages: messages)
        var state = CuttleFeature.State()
        state.currentContext = .global
        state.chatMessages = messages
        state.activeSessionID = session.id
        state.globalChatSessions = [session]
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
        }
        store.exhaustivity = .off

        await store.send(.switchContext(.status(.interview)))

        // Messages within the session should be pruned to 100
        XCTAssertEqual(store.state.globalChatSessions.count, 1)
        XCTAssertEqual(store.state.globalChatSessions[0].messages.count, 100)
        XCTAssertEqual(store.state.globalChatSessions[0].messages.first?.content, "Message 10")
        XCTAssertEqual(store.state.globalChatSessions[0].messages.last?.content, "Message 109")
    }

    // MARK: - CuttleContext Properties

    func testCuttleContextLabel() {
        XCTAssertEqual(CuttleContext.global.label, "All Jobs")
        XCTAssertEqual(CuttleContext.status(.interview).label, "Interview")
        XCTAssertEqual(CuttleContext.status(.rejected).label, "Rejected")
        XCTAssertEqual(CuttleContext.job(UUID()).label, "Job")
    }

    func testCuttleContextDisplayLabel() {
        let job = Self.jobA
        let jobs = [job, Self.jobB]

        XCTAssertEqual(CuttleContext.global.displayLabel(jobs: jobs), "All Jobs")
        XCTAssertEqual(CuttleContext.status(.interview).displayLabel(jobs: jobs), "Interview (1)")
        XCTAssertEqual(CuttleContext.status(.rejected).displayLabel(jobs: jobs), "Rejected (1)")
        XCTAssertEqual(CuttleContext.status(.wishlist).displayLabel(jobs: jobs), "Wishlist (0)")
        XCTAssertEqual(CuttleContext.job(job.id).displayLabel(jobs: jobs), "Alpha \u{2014} Engineer")
        // Job not found falls back
        XCTAssertEqual(CuttleContext.job(UUID()).displayLabel(jobs: jobs), "Job")
    }

    // MARK: - CuttleMood

    func testCuttleMoodAmplitudes() {
        XCTAssertEqual(CuttleMood.idle.amplitudeFrac, 0.08)
        XCTAssertEqual(CuttleMood.thinking.amplitudeFrac, 0.12)
        XCTAssertEqual(CuttleMood.listening.amplitudeFrac, 0.10)
        XCTAssertEqual(CuttleMood.transitioning.amplitudeFrac, 0.15)
    }

    // MARK: - CuttleContext Codable

    func testCuttleContextCodableRoundTrip() throws {
        let cases: [CuttleContext] = [
            .global,
            .status(.interview),
            .status(.rejected),
            .job(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        ]
        for context in cases {
            let data = try JSONEncoder().encode(context)
            let decoded = try JSONDecoder().decode(CuttleContext.self, from: data)
            XCTAssertEqual(decoded, context)
        }
    }

    // MARK: - CuttlePromptBuilder Edge Cases

    func testJobNotFoundFallsBackToGlobal() {
        let job = Self.jobA
        let bogusId = UUID(uuidString: "00000000-0000-0000-0000-FFFFFFFFFFFF")!
        let prompt = CuttlePromptBuilder.buildPrompt(
            context: .job(bogusId), jobs: [job], profile: UserProfile(), chatHistory: []
        )
        // Should fall back to global prompt
        XCTAssertTrue(prompt.contains("full job search dashboard"))
        XCTAssertTrue(prompt.contains("Alpha"))
    }

    func testStatusPromptForRejectedIncludesPatternHint() {
        let job = Self.jobB  // status: .rejected
        let prompt = CuttlePromptBuilder.buildPrompt(
            context: .status(.rejected), jobs: [job], profile: UserProfile(), chatHistory: []
        )
        XCTAssertTrue(prompt.contains("Rejected"))
        XCTAssertTrue(prompt.contains("Beta"))
        XCTAssertTrue(prompt.contains("patterns"))
    }

    func testStatusPromptForOfferIncludesNegotiationHint() {
        let job = JobApplication.mock(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!,
            company: "OfferCo", title: "Lead", status: .offer, salary: "$200k"
        )
        let prompt = CuttlePromptBuilder.buildPrompt(
            context: .status(.offer), jobs: [job], profile: UserProfile(), chatHistory: []
        )
        XCTAssertTrue(prompt.contains("OfferCo"))
        XCTAssertTrue(prompt.contains("$200k"))
        XCTAssertTrue(prompt.contains("compare"))
    }

    func testGlobalPromptIncludesUpcomingInterviews() {
        let futureDate = Date().addingTimeInterval(86400 * 3)
        let job = JobApplication.mock(
            company: "InterviewCo", title: "Dev", status: .interview,
            interviews: [InterviewRound(round: 1, type: "Technical", date: futureDate)]
        )
        let prompt = CuttlePromptBuilder.buildPrompt(
            context: .global, jobs: [job], profile: UserProfile(), chatHistory: []
        )
        XCTAssertTrue(prompt.contains("Upcoming Interviews"))
        XCTAssertTrue(prompt.contains("InterviewCo"))
    }

    func testChatHistoryTruncatesLongMessages() {
        let longMessage = String(repeating: "x", count: 500)
        let history = [ChatMessage(role: .user, content: longMessage)]
        let prompt = CuttlePromptBuilder.buildPrompt(
            context: .global, jobs: [], profile: UserProfile(), chatHistory: history
        )
        // Should contain truncated version (300 chars + "...")
        XCTAssertTrue(prompt.contains("..."))
        XCTAssertFalse(prompt.contains(longMessage))
    }

    // MARK: - Session Creation

    func testSendMessageCreatesSessionAutomatically() async {
        var state = CuttleFeature.State()
        state.apiKey = "test-key"
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
            $0.claudeClient.chat = { _, _, _, _ in
                ("Response", AITokenUsage(inputTokens: 10, outputTokens: 20), nil)
            }
        }
        store.exhaustivity = .off

        XCTAssertNil(store.state.activeSessionID)
        XCTAssertTrue(store.state.globalChatSessions.isEmpty)

        await store.send(.sendMessage("Hello"))
        await store.receive(\.aiResponseReceived)

        // A session should have been created and set as active
        XCTAssertNotNil(store.state.activeSessionID)
        XCTAssertEqual(store.state.globalChatSessions.count, 1)
        XCTAssertEqual(store.state.globalChatSessions[0].id, store.state.activeSessionID)
    }

    func testIdleSessionCreatesNewOnSend() async {
        // Create a session with a lastMessageAt over an hour ago
        let oldDate = Date(timeIntervalSinceNow: -7200)
        let oldSession = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Old msg")],
            lastMessageAt: oldDate
        )
        var state = CuttleFeature.State()
        state.apiKey = "test-key"
        state.globalChatSessions = [oldSession]
        state.activeSessionID = oldSession.id
        state.chatMessages = oldSession.messages
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.claudeClient.chat = { _, _, _, _ in
                ("Response", AITokenUsage(inputTokens: 10, outputTokens: 20), nil)
            }
            $0.date = .constant(Date())
        }
        store.exhaustivity = .off

        await store.send(.sendMessage("New message after long idle"))
        await store.receive(\.aiResponseReceived)

        // Should have created a second session (old one preserved, new one active)
        XCTAssertEqual(store.state.globalChatSessions.count, 2)
        XCTAssertNotEqual(store.state.activeSessionID, oldSession.id)
    }

    // MARK: - Session Selection

    func testSelectSessionSwitchesActiveSession() async {
        let session1 = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Session 1")]
        )
        let session2 = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Session 2")]
        )
        var state = CuttleFeature.State()
        state.globalChatSessions = [session1, session2]
        state.activeSessionID = session1.id
        state.chatMessages = session1.messages
        let store = TestStore(initialState: state) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.selectSession(session2.id))

        XCTAssertEqual(store.state.activeSessionID, session2.id)
        XCTAssertEqual(store.state.chatMessages.count, 1)
        XCTAssertEqual(store.state.chatMessages[0].content, "Session 2")
    }

    // MARK: - Session Deletion

    func testDeleteSessionFallsBackToAdjacentSession() async {
        let session1 = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Session 1")]
        )
        let session2 = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Session 2")]
        )
        var state = CuttleFeature.State()
        state.globalChatSessions = [session1, session2]
        state.activeSessionID = session2.id
        state.chatMessages = session2.messages
        let store = TestStore(initialState: state) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.deleteSession(session2.id))

        // Should fall back to session1
        XCTAssertEqual(store.state.activeSessionID, session1.id)
        XCTAssertEqual(store.state.chatMessages[0].content, "Session 1")
        XCTAssertEqual(store.state.globalChatSessions.count, 1)
    }

    func testDeleteLastSessionClearsChat() async {
        let session = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Only session")]
        )
        var state = CuttleFeature.State()
        state.globalChatSessions = [session]
        state.activeSessionID = session.id
        state.chatMessages = session.messages
        let store = TestStore(initialState: state) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.deleteSession(session.id))

        XCTAssertNil(store.state.activeSessionID)
        XCTAssertTrue(store.state.chatMessages.isEmpty)
        XCTAssertTrue(store.state.globalChatSessions.isEmpty)
    }

    // MARK: - Session Sidebar

    func testToggleSessionSidebar() async {
        let store = TestStore(initialState: CuttleFeature.State()) { CuttleFeature() }

        await store.send(.toggleSessionSidebar) {
            $0.isSessionSidebarVisible = true
        }

        await store.send(.toggleSessionSidebar) {
            $0.isSessionSidebarVisible = false
        }
    }

    // MARK: - Title Generation

    func testSessionTitleGeneratedWritesTitle() async {
        let session = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Test")]
        )
        var state = CuttleFeature.State()
        state.globalChatSessions = [session]
        state.activeSessionID = session.id
        let store = TestStore(initialState: state) { CuttleFeature() }

        await store.send(.sessionTitleGenerated(session.id, "  My Chat Title  ")) {
            $0.globalChatSessions[0].generatedTitle = "My Chat Title"
        }
    }

    func testSessionTitleGeneratedTruncatesAt40Chars() async {
        let session = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Test")]
        )
        var state = CuttleFeature.State()
        state.globalChatSessions = [session]
        let store = TestStore(initialState: state) { CuttleFeature() }

        let longTitle = String(repeating: "A", count: 60)
        await store.send(.sessionTitleGenerated(session.id, longTitle)) {
            $0.globalChatSessions[0].generatedTitle = String(repeating: "A", count: 40)
        }
    }

    // MARK: - Context Switch Cancels In-Flight

    func testContextSwitchClearsInFlightState() async {
        var state = CuttleFeature.State()
        state.currentContext = .global
        state.isLoading = true
        state.inFlightContext = .global
        state.inFlightSessionID = UUID()
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
        }
        store.exhaustivity = .off

        await store.send(.switchContext(.status(.offer)))

        XCTAssertFalse(store.state.isLoading)
        XCTAssertNil(store.state.inFlightContext)
        XCTAssertNil(store.state.inFlightSessionID)
        XCTAssertEqual(store.state.currentContext, .status(.offer))
    }

    // MARK: - Per-Context Session Pruning

    func testStartNewSessionPrunesWhenOverLimit() async {
        // Fill global sessions to 55 with old timestamps so idle threshold triggers new session
        let oldDate = Date(timeIntervalSinceNow: -7200)
        var state = CuttleFeature.State()
        state.apiKey = "test-key"
        state.currentContext = .global
        state.globalChatSessions = (0..<55).map { i in
            ChatSession(
                providerType: .claudeAPI,
                messages: [ChatMessage(role: .user, content: "Session \(i)")],
                lastMessageAt: oldDate
            )
        }
        state.activeSessionID = state.globalChatSessions.last?.id
        state.chatMessages = state.globalChatSessions.last?.messages ?? []
        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
            $0.claudeClient.chat = { _, _, _, _ in
                ("Response", AITokenUsage(inputTokens: 10, outputTokens: 20), nil)
            }
        }
        store.exhaustivity = .off

        await store.send(.sendMessage("New session trigger"))
        await store.receive(\.aiResponseReceived)

        // Old session synced + new session created, but pruned to 50
        XCTAssertLessThanOrEqual(store.state.globalChatSessions.count, 50)
    }

    // MARK: - Legacy Migration

    func testLegacyChatHistoryMigratesToSession() throws {
        // Simulate old JSON with chatHistory key
        let oldJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "company": "Acme",
            "title": "Engineer",
            "status": "Wishlist",
            "dateAdded": 0,
            "updatedAt": 0,
            "chatHistory": [
                {"id": "00000000-0000-0000-0000-000000000002", "role": "user", "content": "Hello", "timestamp": 0},
                {"id": "00000000-0000-0000-0000-000000000003", "role": "assistant", "content": "Hi!", "timestamp": 1}
            ]
        }
        """
        let data = oldJSON.data(using: .utf8)!
        let job = try JSONDecoder().decode(JobApplication.self, from: data)

        XCTAssertEqual(job.chatSessions.count, 1)
        XCTAssertEqual(job.chatSessions[0].messages.count, 2)
        XCTAssertEqual(job.chatSessions[0].providerName, "Claude API")
        XCTAssertEqual(job.chatSessions[0].providerType, .claudeAPI)
        XCTAssertEqual(job.chatSessions[0].messages[0].content, "Hello")
        XCTAssertEqual(job.chatSessions[0].messages[1].content, "Hi!")
    }

    func testLegacyEmptyChatHistoryMigratesToEmptySessions() throws {
        let oldJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "company": "Acme",
            "title": "Engineer",
            "status": "Wishlist",
            "dateAdded": 0,
            "updatedAt": 0,
            "chatHistory": []
        }
        """
        let data = oldJSON.data(using: .utf8)!
        let job = try JSONDecoder().decode(JobApplication.self, from: data)

        XCTAssertTrue(job.chatSessions.isEmpty)
    }

    // MARK: - Global Pruning

    func testPruneGlobalSessionsEvictsOldestWhenOverCap() async {
        var state = CuttleFeature.State()
        state.currentContext = .global
        // Create 210 global sessions (cap is 200), each with a distinct timestamp
        let baseDate = Date(timeIntervalSinceReferenceDate: 0)
        state.globalChatSessions = (0..<210).map { i in
            ChatSession(
                providerType: .claudeAPI,
                messages: [ChatMessage(role: .user, content: "Msg \(i)")],
                createdAt: baseDate.addingTimeInterval(Double(i)),
                lastMessageAt: baseDate.addingTimeInterval(Double(i))
            )
        }
        // Set active to the newest so it's protected from eviction
        state.activeSessionID = state.globalChatSessions.last?.id
        state.chatMessages = [ChatMessage(role: .user, content: "Active msg")]

        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
        }
        store.exhaustivity = .off

        // switchContext triggers saveChatHistory which calls pruneGlobalSessions
        await store.send(.switchContext(.status(.interview)))

        // Should be pruned to 200
        XCTAssertLessThanOrEqual(store.state.globalChatSessions.count, 200)
        // The active session should be preserved
        XCTAssertTrue(store.state.globalChatSessions.contains(where: { $0.id == state.activeSessionID }))
        // The oldest sessions should have been removed
        XCTAssertFalse(store.state.globalChatSessions.contains(where: { $0.messages.first?.content == "Msg 0" }))
    }

    func testMessagePruningWithinSessionCapsAt100() async {
        var state = CuttleFeature.State()
        state.currentContext = .global
        state.apiKey = "test-key"
        // Create a session with 110 messages
        let session = ChatSession(
            providerType: .claudeAPI,
            messages: (0..<110).map { ChatMessage(role: .user, content: "Msg \($0)") }
        )
        state.globalChatSessions = [session]
        state.activeSessionID = session.id
        state.chatMessages = session.messages

        let store = TestStore(initialState: state) {
            CuttleFeature()
        } withDependencies: {
            $0.date = .constant(Date())
        }
        store.exhaustivity = .off

        // switchContext triggers saveChatHistory -> syncCurrentSessionMessages which prunes
        await store.send(.switchContext(.status(.interview)))

        // The saved global session should be pruned to 100 messages
        if let savedSession = store.state.globalChatSessions.first(where: { $0.id == session.id }) {
            XCTAssertEqual(savedSession.messages.count, 100)
            XCTAssertEqual(savedSession.messages.first?.content, "Msg 10")
            XCTAssertEqual(savedSession.messages.last?.content, "Msg 109")
        } else {
            XCTFail("Session should still exist after context switch")
        }
    }

    // MARK: - Delete In-Flight Session

    func testDeleteInFlightSessionCancelsRequest() async {
        let session = ChatSession(
            providerType: .claudeAPI,
            messages: [ChatMessage(role: .user, content: "Pending")]
        )
        var state = CuttleFeature.State()
        state.globalChatSessions = [session]
        state.activeSessionID = session.id
        state.chatMessages = session.messages
        state.isLoading = true
        state.inFlightSessionID = session.id
        state.inFlightContext = .global
        let store = TestStore(initialState: state) { CuttleFeature() }
        store.exhaustivity = .off

        await store.send(.deleteSession(session.id))

        XCTAssertFalse(store.state.isLoading)
        XCTAssertNil(store.state.inFlightSessionID)
        XCTAssertNil(store.state.inFlightContext)
        XCTAssertTrue(store.state.globalChatSessions.isEmpty)
    }

    // MARK: - ChatSession Model

    func testProviderNameComputedFromType() {
        let claudeSession = ChatSession(providerType: .claudeAPI)
        XCTAssertEqual(claudeSession.providerName, "Claude API")

        let acpSession = ChatSession(providerType: .acpAgent)
        XCTAssertEqual(acpSession.providerName, "ACP Agent")

        let namedACP = ChatSession(providerType: .acpAgent, agentName: "My Custom Agent")
        XCTAssertEqual(namedACP.providerName, "My Custom Agent")
    }

    func testLegacySettingsChatHistoryMigratesToSessions() throws {
        let oldJSON = """
        {
            "globalChatHistory": [
                {"id": "00000000-0000-0000-0000-000000000001", "role": "user", "content": "Global msg", "timestamp": 0}
            ],
            "statusChatHistories": {
                "Interview": [
                    {"id": "00000000-0000-0000-0000-000000000002", "role": "assistant", "content": "Interview msg", "timestamp": 0}
                ]
            }
        }
        """
        let data = oldJSON.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.globalChatSessions.count, 1)
        XCTAssertEqual(settings.globalChatSessions[0].messages[0].content, "Global msg")
        XCTAssertEqual(settings.statusChatSessions["Interview"]?.count, 1)
        XCTAssertEqual(settings.statusChatSessions["Interview"]?[0].messages[0].content, "Interview msg")
    }
}

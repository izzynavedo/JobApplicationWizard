import ComposableArchitecture
import JobApplicationShared
import Foundation

@Reducer
public struct CuttleFeature {
    private enum CancelID { case aiRequest, titleGeneration }

    /// Maximum messages retained per context when saving chat history.
    private static let maxHistoryMessages = 100

    @ObservableState
    public struct State: Equatable {
        // Context
        public var currentContext: CuttleContext = .global
        /// Non-nil only while actively dragging over a drop zone; drives the glow overlay.
        public var pendingContext: CuttleContext? = nil

        // Position & drag
        public var position: CGPoint = CGPoint(x: 60, y: 120)
        public var dragOffset: CGSize = .zero
        public var isDragging: Bool = false

        // Expansion
        public var isExpanded: Bool = false

        // Chat state
        public var chatInput: String = ""
        public var chatMessages: [ChatMessage] = []
        public var isLoading: Bool = false
        public var error: String? = nil
        public var acpSentSystemPrompt: Bool = false
        public var tokenUsage: AITokenUsage = .zero

        // Mood
        public var mood: CuttleMood = .idle

        /// Context and session that own the current in-flight AI request.
        /// When the user docks elsewhere mid-request, these let us write
        /// the response back to the originating session's history.
        public var inFlightContext: CuttleContext? = nil
        public var inFlightSessionID: UUID? = nil

        // Drop zones reported by views
        public var dropZones: [DropZone] = []

        // Onboarding: temporarily pretend AI is connected so the chat UI is visible
        public var onboardingFakeAIReady: Bool = false

        // Read-only references synced from AppFeature
        public var apiKey: String = ""
        public var userProfile: UserProfile = UserProfile()
        public var jobs: [JobApplication] = []

        // Session management
        public var activeSessionID: UUID? = nil
        public var isSessionSidebarVisible: Bool = false

        // Persisted chat sessions (global and per-status)
        public var globalChatSessions: [ChatSession] = []
        public var statusChatSessions: [String: [ChatSession]] = [:]
        /// Local buffer for the current job's sessions (synced via delegate on save).
        public var activeJobSessions: [ChatSession] = []

        // ACP connection (shared)
        @SharedReader(.inMemory("acpConnection")) public var acpConnection = ACPConnectionState()

        // Window size for clamping
        public var windowSize: CGSize = .zero

        // Chat window size (synced from CuttleView for onboarding spotlight)
        public var chatSize: CGSize = CGSize(width: 380, height: 480)
        public var isResizing: Bool = false

        public init() {}
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        // Drag (with docking)
        case dragChanged(CGPoint)
        case dragEnded(CGPoint)
        // Drag (position only, no docking)
        case moveChanged(CGPoint)
        case moveEnded
        case dropZonesUpdated([DropZone])
        case windowSizeChanged(CGSize)
        // Expand/collapse
        case toggleExpanded
        case collapse
        // Context
        case switchContext(CuttleContext)
        // Chat
        case sendMessage(String)
        case aiResponseReceived(Result<(String, AITokenUsage, AgentActionBlock?), Error>)
        case clearChat
        case applySuggestion(String)
        // Sessions
        case toggleSessionSidebar
        case selectSession(UUID)
        case deleteSession(UUID)
        case sessionTitleGenerated(UUID, String)
        // Lifecycle
        case restoreFromSettings(CuttleContext, [ChatSession], [String: [ChatSession]])
        case positionAtDropZone
        // Delegate (parent actions)
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            /// Job-context sessions were updated; parent should persist to the job model.
            case jobChatUpdated(UUID, [ChatSession])
            /// Cuttle docked on a job; parent should select it in the detail pane.
            case contextChanged(CuttleContext)
            /// Agent proposed actions to apply to a job.
            case agentActionsReceived([AgentAction], String)
        }
    }

    @Dependency(\.claudeClient) var claudeClient
    @Dependency(\.acpClient) var acpClient
    @Dependency(\.date.now) var now

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            // MARK: - Drag

            case .dragChanged(let location):
                state.isDragging = true
                state.mood = .listening
                // Clamp Y to stay below the title bar drag area
                state.position = CGPoint(x: location.x, y: max(location.y, Self.topInset))

                // Check drop zone proximity using cursor position.
                // Prefer more specific contexts (job > status > global) when zones overlap.
                let tolerance: CGFloat = 20
                state.pendingContext = nil
                var bestZone: DropZone? = nil
                for zone in state.dropZones {
                    let expanded = zone.frame.insetBy(dx: -tolerance, dy: -tolerance)
                    if expanded.contains(location) {
                        if let current = bestZone {
                            // Prefer more specific: .job > .status > .global
                            if specificity(zone.context) > specificity(current.context) {
                                bestZone = zone
                            }
                        } else {
                            bestZone = zone
                        }
                    }
                }
                state.pendingContext = bestZone?.context
                return .none

            case .dragEnded:
                state.isDragging = false
                let pending = state.pendingContext
                let wasExpanded = state.isExpanded
                state.pendingContext = nil  // always clear; glow is drag-only

                if let pending {
                    // Always open chat when docking
                    state.isExpanded = true
                    return switchContextSilently(state: &state, to: pending)
                } else {
                    state.mood = .idle
                    if !wasExpanded {
                        clampPosition(state: &state)
                    }
                }
                return .none

            // MARK: - Move (no docking)

            case .moveChanged(let location):
                state.position = CGPoint(x: location.x, y: max(location.y, Self.topInset))
                return .none

            case .moveEnded:
                clampPosition(state: &state)
                return .none

            case .dropZonesUpdated(let zones):
                state.dropZones = zones
                // Track the docked card during scroll (when not dragging)
                if !state.isDragging {
                    snapToDropZone(state: &state, context: state.currentContext)
                }
                return .none

            case .windowSizeChanged(let size):
                state.windowSize = size
                clampPosition(state: &state)
                return .none

            // MARK: - Expand / Collapse

            case .toggleExpanded:
                state.isExpanded.toggle()
                return .none

            case .collapse:
                state.isExpanded = false
                return .none

            case .switchContext(let context):
                return switchContextSilently(state: &state, to: context)

            // MARK: - Chat

            case .sendMessage(let text):
                let rawInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawInput.isEmpty else { return .none }

                ensureActiveSession(state: &state)
                state.chatMessages.append(ChatMessage(role: .user, content: rawInput))
                state.chatInput = ""
                state.isLoading = true
                state.error = nil
                state.mood = .thinking
                state.inFlightContext = state.currentContext
                state.inFlightSessionID = state.activeSessionID

                // Build system prompt using history BEFORE the just-appended user message,
                // since the user message is sent separately in the messages array.
                let priorHistory = Array(state.chatMessages.dropLast())
                let currentProvider = state.acpConnection.aiProvider
                let systemPrompt = CuttlePromptBuilder.buildPrompt(
                    context: state.currentContext,
                    jobs: state.jobs,
                    profile: state.userProfile,
                    chatHistory: priorHistory,
                    aiProvider: currentProvider
                )
                let messages = state.chatMessages

                // Determine if tools should be included (only for job context with Claude API)
                let isJobContext: Bool
                if case .job = state.currentContext { isJobContext = true } else { isJobContext = false }

                if state.acpConnection.aiProvider == .acpAgent && state.acpConnection.isConnected {
                    let contextPrefix = state.acpSentSystemPrompt ? "" : systemPrompt + "\n\n"
                    state.acpSentSystemPrompt = true
                    let fullMessage = contextPrefix + rawInput
                    return .run { send in
                        await send(.aiResponseReceived(Result {
                            let (text, usage) = try await acpClient.sendPrompt(fullMessage, messages)
                            // ACP fallback: extract actions from text markers
                            let actionBlock = TextActionExtractor.extract(from: text)
                            let cleanText = actionBlock != nil ? TextActionExtractor.stripActions(from: text) : text
                            return (cleanText, usage, actionBlock)
                        }))
                    }
                    .cancellable(id: CancelID.aiRequest, cancelInFlight: true)
                } else {
                    let key = state.apiKey
                    let includeTools = isJobContext
                    return .run { send in
                        await send(.aiResponseReceived(Result {
                            try await claudeClient.chat(key, systemPrompt, messages, includeTools)
                        }))
                    }
                    .cancellable(id: CancelID.aiRequest, cancelInFlight: true)
                }

            case .aiResponseReceived(.success(let (text, usage, actionBlock))):
                state.inFlightContext = nil
                state.inFlightSessionID = nil
                state.isLoading = false
                state.mood = .idle
                state.tokenUsage = AITokenUsage(
                    inputTokens: state.tokenUsage.inputTokens + usage.inputTokens,
                    outputTokens: state.tokenUsage.outputTokens + usage.outputTokens
                )

                if !text.isEmpty {
                    state.chatMessages.append(ChatMessage(role: .assistant, content: text))
                }
                let saveEffect = saveChatHistory(state: &state)
                let titleEffect = maybeGenerateSessionTitle(state: &state)

                var effects: [Effect<Action>] = [saveEffect]
                if let titleEffect { effects.append(titleEffect) }

                if let block = actionBlock, !block.actions.isEmpty,
                   case .job = state.currentContext {
                    effects.append(.send(.delegate(.agentActionsReceived(block.actions, block.summary))))
                }
                return .merge(effects)

            case .aiResponseReceived(.failure(let error)):
                state.inFlightContext = nil
                state.inFlightSessionID = nil
                state.isLoading = false
                state.mood = .idle
                state.error = "\(type(of: error)): \(error.localizedDescription)"
                return saveChatHistory(state: &state)

            case .clearChat:
                // Cancel any in-flight request so its response doesn't land in the new session
                let cancelEffect = Effect<Action>.cancel(id: CancelID.aiRequest)
                // Archive current session (if non-empty) and start fresh
                let archiveEffect = saveChatHistory(state: &state)
                state.activeSessionID = nil
                state.chatMessages = []
                state.chatInput = ""
                state.error = nil
                state.tokenUsage = .zero
                state.acpSentSystemPrompt = false
                state.isLoading = false
                state.inFlightContext = nil
                state.inFlightSessionID = nil
                return .merge(cancelEffect, archiveEffect)

            case .applySuggestion(let prompt):
                state.chatInput = prompt
                return .send(.sendMessage(prompt))

            // MARK: - Lifecycle

            case .restoreFromSettings(let context, let globalSessions, let statusSessions):
                state.currentContext = context
                state.globalChatSessions = globalSessions
                state.statusChatSessions = statusSessions
                loadChatHistory(state: &state)
                return .none

            case .positionAtDropZone:
                snapToDropZone(state: &state, context: state.currentContext)
                return .none

            // MARK: - Sessions

            case .toggleSessionSidebar:
                state.isSessionSidebarVisible.toggle()
                return .none

            case .selectSession(let id):
                // Save current session, then load selected
                syncCurrentSessionMessages(state: &state)
                let sessions = currentSessions(state: state)
                if let session = sessions.first(where: { $0.id == id }) {
                    state.chatMessages = session.messages
                    state.activeSessionID = id
                    state.tokenUsage = .zero
                    state.error = nil
                    state.acpSentSystemPrompt = false
                }
                return saveSessions(state: &state)

            case .deleteSession(let id):
                // Cancel in-flight request if it belongs to the session being deleted
                var cancelEffect: Effect<Action> = .none
                if id == state.inFlightSessionID {
                    cancelEffect = .cancel(id: CancelID.aiRequest)
                    state.isLoading = false
                    state.inFlightContext = nil
                    state.inFlightSessionID = nil
                }

                let sessions = currentSessions(state: state)
                if id == state.activeSessionID {
                    // Switch to an adjacent session before deleting
                    if let idx = sessions.firstIndex(where: { $0.id == id }) {
                        let nextIdx = idx > 0 ? idx - 1 : (sessions.count > 1 ? idx + 1 : nil)
                        if let nextIdx {
                            let next = sessions[nextIdx]
                            state.chatMessages = next.messages
                            state.activeSessionID = next.id
                        } else {
                            // Last session; clear everything
                            state.chatMessages = []
                            state.activeSessionID = nil
                        }
                    }
                }
                state.tokenUsage = .zero
                state.error = nil
                state.acpSentSystemPrompt = false
                removeSession(state: &state, id: id)
                return .merge(cancelEffect, saveSessions(state: &state))

            case .sessionTitleGenerated(let sessionID, let title):
                // Write the generated title into the session wherever it lives
                let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                if let idx = state.globalChatSessions.firstIndex(where: { $0.id == sessionID }) {
                    state.globalChatSessions[idx].generatedTitle = trimmed
                }
                for (key, sessions) in state.statusChatSessions {
                    if let idx = sessions.firstIndex(where: { $0.id == sessionID }) {
                        state.statusChatSessions[key]?[idx].generatedTitle = trimmed
                    }
                }
                if let idx = state.activeJobSessions.firstIndex(where: { $0.id == sessionID }) {
                    state.activeJobSessions[idx].generatedTitle = trimmed
                }
                return .none

            case .delegate:
                return .none
            }
        }
    }

    // MARK: - Helpers

    /// Returns a specificity score for drop zone priority (higher = more specific).
    private func specificity(_ context: CuttleContext) -> Int {
        switch context {
        case .global: return 0
        case .status: return 1
        case .job: return 2
        }
    }

    private func switchContextSilently(state: inout State, to context: CuttleContext) -> Effect<Action> {
        // Cancel any in-flight AI request to avoid cross-context contamination
        let cancelEffect = Effect<Action>.cancel(id: CancelID.aiRequest)
        state.isLoading = false
        state.inFlightContext = nil
        state.inFlightSessionID = nil
        state.isExpanded = true

        // Save current history before switching
        let saveEffect = saveChatHistory(state: &state)

        state.pendingContext = nil
        state.currentContext = context
        state.acpSentSystemPrompt = false
        state.mood = .idle

        // Load history for new context
        loadChatHistory(state: &state)

        // Snap to zone
        snapToDropZone(state: &state, context: context)
        return .merge(cancelEffect, saveEffect, .send(.delegate(.contextChanged(context))))
    }

    private func snapToDropZone(state: inout State, context: CuttleContext) {
        if let zone = state.dropZones.first(where: { $0.context == context }) {
            state.position = CGPoint(x: zone.frame.midX, y: zone.frame.midY)
        }
    }

    /// Minimum Y to keep Cuttle below the title bar / toolbar drag area.
    private static let topInset: CGFloat = 52

    private func clampPosition(state: inout State) {
        let margin: CGFloat = 24
        if state.windowSize.width > 0 {
            state.position.x = max(margin, min(state.position.x, state.windowSize.width - margin))
        }
        if state.windowSize.height > 0 {
            state.position.y = max(Self.topInset, min(state.position.y, state.windowSize.height - margin))
        }
    }

    // MARK: - Session Helpers

    /// Maximum sessions retained per context.
    private static let maxSessions = 50
    /// Maximum sessions retained globally across all contexts.
    private static let maxGlobalSessions = 200

    /// Returns the display name for the current AI provider.
    private func resolveAgentName(state: State) -> String? {
        if state.acpConnection.aiProvider == .acpAgent {
            return state.acpConnection.connectedAgentName
        }
        return nil
    }

    /// Returns the sessions array for the current context.
    private func currentSessions(state: State) -> [ChatSession] {
        switch state.currentContext {
        case .global:
            return state.globalChatSessions
        case .status(let status):
            return state.statusChatSessions[status.rawValue] ?? []
        case .job:
            return state.activeJobSessions
        }
    }

    /// Time gap (in seconds) after which a new session is started automatically.
    private static let sessionIdleThreshold: TimeInterval = 3600  // 1 hour

    /// Ensures an active session exists. Starts a new one if there is no active
    /// session, or if the last message was more than 1 hour ago.
    private func ensureActiveSession(state: inout State) {
        let agentName = resolveAgentName(state: state)
        let providerType = state.acpConnection.aiProvider

        if let activeID = state.activeSessionID,
           let session = currentSessions(state: state).first(where: { $0.id == activeID }) {
            // Start a new session if the conversation has been idle for over an hour
            let lastActivity = session.lastMessageAt
            if now.timeIntervalSince(lastActivity) > Self.sessionIdleThreshold {
                syncCurrentSessionMessages(state: &state)
                startNewSession(state: &state, providerType: providerType, agentName: agentName)
            }
        } else {
            startNewSession(state: &state, providerType: providerType, agentName: agentName)
        }
    }

    /// Writes chatMessages back into the active session in the correct sessions array.
    private func syncCurrentSessionMessages(state: inout State) {
        guard let activeID = state.activeSessionID else { return }
        let pruned = Array(state.chatMessages.suffix(Self.maxHistoryMessages))
        let lastMessageAt = pruned.last?.timestamp ?? now

        mutateCurrentSessions(state: &state) { sessions in
            if let idx = sessions.firstIndex(where: { $0.id == activeID }) {
                sessions[idx].messages = pruned
                sessions[idx].lastMessageAt = lastMessageAt
            }
        }
    }

    /// Creates a new session, appends it to the current context, and sets it active.
    private func startNewSession(state: inout State, providerType: AIProvider, agentName: String? = nil) {
        let session = ChatSession(providerType: providerType, agentName: agentName, createdAt: now, lastMessageAt: now)
        state.activeSessionID = session.id
        state.chatMessages = []

        mutateCurrentSessions(state: &state) { sessions in
            sessions.append(session)
            // Prune oldest sessions
            if sessions.count > Self.maxSessions {
                sessions = Array(sessions.suffix(Self.maxSessions))
            }
        }
    }

    /// Removes a session by ID from the current context's sessions array.
    private func removeSession(state: inout State, id: UUID) {
        mutateCurrentSessions(state: &state) { sessions in
            sessions.removeAll { $0.id == id }
        }
    }

    /// Mutates the sessions array for the current context in place.
    private func mutateCurrentSessions(state: inout State, _ transform: (inout [ChatSession]) -> Void) {
        switch state.currentContext {
        case .global:
            transform(&state.globalChatSessions)
        case .status(let status):
            var sessions = state.statusChatSessions[status.rawValue] ?? []
            transform(&sessions)
            state.statusChatSessions[status.rawValue] = sessions
        case .job:
            transform(&state.activeJobSessions)
        }
    }

    /// Saves current chat session to the appropriate store.
    /// Returns a delegate effect for job-context so AppFeature can persist to the job model.
    private func saveChatHistory(state: inout State) -> Effect<Action> {
        syncCurrentSessionMessages(state: &state)
        pruneGlobalSessions(state: &state)
        return saveSessions(state: &state)
    }

    /// Prunes oldest sessions globally (across global + status contexts) when the
    /// total exceeds the global cap. Job sessions are excluded since they are
    /// managed per-job and persisted separately.
    private func pruneGlobalSessions(state: inout State) {
        var total = state.globalChatSessions.count
        for (_, sessions) in state.statusChatSessions {
            total += sessions.count
        }
        guard total > Self.maxGlobalSessions else { return }

        // Collect all sessions with their location, sorted by lastMessageAt
        struct SessionRef: Comparable {
            let lastMessageAt: Date
            let id: UUID
            let isGlobal: Bool
            let statusKey: String?
            static func < (lhs: SessionRef, rhs: SessionRef) -> Bool {
                lhs.lastMessageAt < rhs.lastMessageAt
            }
        }
        var refs: [SessionRef] = []
        for s in state.globalChatSessions {
            refs.append(SessionRef(lastMessageAt: s.lastMessageAt, id: s.id, isGlobal: true, statusKey: nil))
        }
        for (key, sessions) in state.statusChatSessions {
            for s in sessions {
                refs.append(SessionRef(lastMessageAt: s.lastMessageAt, id: s.id, isGlobal: false, statusKey: key))
            }
        }
        refs.sort()

        // Remove oldest until we are at the cap, but never remove the active session
        let toRemove = total - Self.maxGlobalSessions
        var removed = 0
        for ref in refs where removed < toRemove {
            guard ref.id != state.activeSessionID else { continue }
            if ref.isGlobal {
                state.globalChatSessions.removeAll { $0.id == ref.id }
            } else if let key = ref.statusKey {
                state.statusChatSessions[key]?.removeAll { $0.id == ref.id }
            }
            removed += 1
        }
    }

    /// Persists the sessions array for the current context.
    private func saveSessions(state: inout State) -> Effect<Action> {
        switch state.currentContext {
        case .global, .status:
            return .none
        case .job(let id):
            return .send(.delegate(.jobChatUpdated(id, state.activeJobSessions)))
        }
    }

    /// Loads the most recent session for the current context into chatMessages.
    private func loadChatHistory(state: inout State) {
        // For job contexts, copy sessions into local buffer
        if case .job(let id) = state.currentContext {
            state.activeJobSessions = state.jobs.first(where: { $0.id == id })?.chatSessions ?? []
        }

        let sessions = currentSessions(state: state)
        if let last = sessions.last {
            state.chatMessages = last.messages
            state.activeSessionID = last.id
        } else {
            state.chatMessages = []
            state.activeSessionID = nil
        }
        state.tokenUsage = .zero
        state.error = nil
    }

    // MARK: - Session Title Generation

    /// Number of user messages needed before requesting a title.
    private static let titleTriggerCount = 3

    /// If the active session has enough user messages and no title yet, fires a
    /// background LLM call to generate one. Returns nil if no call is needed.
    private func maybeGenerateSessionTitle(state: inout State) -> Effect<Action>? {
        guard let activeID = state.activeSessionID else { return nil }
        let sessions = currentSessions(state: state)
        guard let session = sessions.first(where: { $0.id == activeID }) else { return nil }

        // Already has a title, or not enough user messages yet
        if session.generatedTitle != nil { return nil }
        let userMessages = state.chatMessages.filter { $0.role == .user }
        guard userMessages.count >= Self.titleTriggerCount else { return nil }

        let snippets = userMessages.prefix(Self.titleTriggerCount).map { $0.content }
        let sessionID = activeID
        let apiKey = state.apiKey
        let useACP = state.acpConnection.aiProvider == .acpAgent && state.acpConnection.isConnected

        if useACP {
            let prompt = Self.titlePrompt(for: snippets)
            return .run { send in
                let (text, _) = try await acpClient.sendPrompt(prompt, [])
                await send(.sessionTitleGenerated(sessionID, text))
            } catch: { _, _ in }
            .cancellable(id: CancelID.titleGeneration, cancelInFlight: true)
        } else if !apiKey.isEmpty {
            let systemPrompt = "You name chat sessions. Respond with only a short title (2-4 words), nothing else."
            let messages = [ChatMessage(role: .user, content: Self.titlePrompt(for: snippets))]
            return .run { send in
                let (text, _, _) = try await claudeClient.chat(apiKey, systemPrompt, messages, false)
                await send(.sessionTitleGenerated(sessionID, text))
            } catch: { _, _ in }
            .cancellable(id: CancelID.titleGeneration, cancelInFlight: true)
        }
        return nil
    }

    private static func titlePrompt(for userMessages: [String]) -> String {
        let numbered = userMessages.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return "Give this chat session a short title (2-4 words). Only respond with the title, nothing else.\n\nUser messages:\n\(numbered)"
    }
}

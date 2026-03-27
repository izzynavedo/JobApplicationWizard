import Foundation
import SwiftUI
import UIKit
import ComposableArchitecture
import JobApplicationShared
import UserNotifications
import AuthenticationServices
import os.log

private let syncLog = Logger(subsystem: "com.zsparks.JobApplicationWizardiOS", category: "Sync")

@Reducer
struct iOSAppFeature {
    @ObservableState
    struct State: Equatable {
        var jobs: IdentifiedArrayOf<JobApplication> = []
        var settings: AppSettings = AppSettings()
        var searchQuery: String = ""
        var filterStatus: JobStatus? = nil
        var path = NavigationPath()
        var isLoading = true
        var importError: String? = nil
        var isSyncEnabled = false
        var isSyncing = false
        var lastSyncDate: Date? = nil
        var syncError: String? = nil
        var syncRetryCount: Int = 0
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case jobsLoaded([JobApplication])
        case settingsLoaded(AppSettings)
        case loadFailed
        case moveJob(UUID, JobStatus)
        case toggleFavorite(UUID)
        case addJob(JobApplication)
        case addNote(UUID, Note)
        case deleteNote(UUID, UUID)
        case deleteJob(UUID)
        case searchQueryChanged(String)
        case filterStatusChanged(JobStatus?)
        case scheduleInterviewNotifications
        case importData(Data)
        case importCompleted(Result<AppDataExport, Error>)
        case exportRequested
        case dismissImportError
        // Sync
        case syncCheckAuth
        case syncSignIn
        case syncAuthSucceeded
        case syncSignOut
        case syncNow
        case syncCompleted(Result<SyncState, Error>)
        case syncConflict
        case scenePhaseChanged(ScenePhase)
        case dismissSyncError
    }

    private enum SyncDebounceID { case sync }

    @Dependency(\.sharedPersistence) var persistence
    @Dependency(\.syncStorageClient) var syncStorage
    @Dependency(\.baseStateClient) var baseState

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none

            case .onAppear:
                // Load jobs and settings first (priority), then sync in background
                return .merge(
                    .run { send in
                        do {
                            let jobs = try await persistence.loadJobs()
                            syncLog.info("Loaded \(jobs.count) jobs from disk")
                            await send(.jobsLoaded(jobs))
                        } catch {
                            syncLog.error("Failed to load jobs: \(error.localizedDescription)")
                            await send(.loadFailed)
                        }
                        do {
                            let settings = try await persistence.loadSettings()
                            await send(.settingsLoaded(settings))
                        } catch {
                            syncLog.warning("Failed to load settings, using defaults")
                        }
                    },
                    // Defer changelog load and auto-sync so UI renders first
                    .run { send in
                        // Small delay to let the UI settle
                        try? await Task.sleep(for: .milliseconds(500))
                        await send(.syncCheckAuth)
                    }
                )

            case .jobsLoaded(let jobs):
                state.jobs = IdentifiedArray(uniqueElements: jobs)
                state.isLoading = false
                return .send(.scheduleInterviewNotifications)

            case .settingsLoaded(let settings):
                state.settings = settings
                return .none

            case .loadFailed:
                state.isLoading = false
                return .none

            case .moveJob(let id, let newStatus):
                state.jobs[id: id]?.status = newStatus
                state.jobs[id: id]?.updatedAt = Date()
                return .merge(saveJobs(state.jobs), debouncedSync(state))

            case .toggleFavorite(let id):
                state.jobs[id: id]?.isFavorite.toggle()
                state.jobs[id: id]?.updatedAt = Date()
                return .merge(saveJobs(state.jobs), debouncedSync(state))

            case .addJob(let job):
                state.jobs.append(job)
                return .merge(saveJobs(state.jobs), debouncedSync(state))

            case .addNote(let jobId, let note):
                state.jobs[id: jobId]?.noteCards.append(note)
                state.jobs[id: jobId]?.updatedAt = Date()
                return .merge(saveJobs(state.jobs), debouncedSync(state))

            case .deleteNote(let jobId, let noteId):
                state.jobs[id: jobId]?.noteCards.removeAll { $0.id == noteId }
                state.jobs[id: jobId]?.updatedAt = Date()
                return .merge(saveJobs(state.jobs), debouncedSync(state))

            case .deleteJob(let id):
                state.jobs.remove(id: id)
                return .merge(saveJobs(state.jobs), debouncedSync(state))

            case .searchQueryChanged(let query):
                state.searchQuery = query
                return .none

            case .filterStatusChanged(let status):
                state.filterStatus = status
                return .none

            case .scheduleInterviewNotifications:
                let interviews = state.jobs.flatMap { job in
                    job.interviews
                        .filter { !$0.completed && $0.date != nil }
                        .map { (job, $0) }
                }
                return .run { _ in
                    await scheduleNotifications(for: interviews)
                }

            case .importData(let data):
                return .run { send in
                    do {
                        let export = try persistence.importAllData(data)
                        await send(.importCompleted(.success(export)))
                    } catch {
                        await send(.importCompleted(.failure(error)))
                    }
                }

            case .importCompleted(.success(let export)):
                state.jobs = IdentifiedArray(uniqueElements: export.jobs)
                state.settings = export.settings
                return saveJobs(state.jobs)

            case .importCompleted(.failure(let error)):
                state.importError = error.localizedDescription
                return .none

            case .exportRequested:
                return .none // Handled by the view via ShareLink

            case .dismissImportError:
                state.importError = nil
                return .none

            // MARK: - Sync Actions

            case .syncCheckAuth:
                guard GoogleDriveSecrets.isConfigured else { return .none }
                return .run { [syncStorage] send in
                    let authenticated = await syncStorage.isAuthenticated()
                    syncLog.info("Auth check on launch: \(authenticated)")
                    if authenticated {
                        await send(.syncAuthSucceeded)
                    }
                }

            case .syncSignIn:
                syncLog.info("User tapped Sign In")
                return .run { [syncStorage] send in
                    do {
                        try await syncStorage.authenticate()
                        syncLog.info("OAuth completed successfully")
                        await send(.syncAuthSucceeded)
                    } catch let error as ASWebAuthenticationSessionError
                                where error.code == .canceledLogin {
                        let authenticated = await syncStorage.isAuthenticated()
                        syncLog.info("OAuth cancelled, but authenticated=\(authenticated)")
                        if authenticated {
                            await send(.syncAuthSucceeded)
                        }
                    } catch {
                        syncLog.error("OAuth failed: \(error.localizedDescription)")
                        await send(.syncCompleted(.failure(error)))
                    }
                }

            case .syncAuthSucceeded:
                syncLog.info("Sync auth succeeded, enabling sync")
                state.isSyncEnabled = true
                return .send(.syncNow)

            case .syncSignOut:
                syncLog.info("User signed out of sync")
                syncStorage.signOut()
                state.isSyncEnabled = false
                state.lastSyncDate = nil
                return .none

            case .syncNow:
                state.isSyncing = true
                state.syncError = nil
                let lastChange = state.jobs.map(\.updatedAt).max() ?? Date()
                let localState = SyncState(
                    lastModified: lastChange,
                    jobs: Array(state.jobs),
                    settings: state.settings
                )
                return .concatenate(
                    .cancel(id: SyncDebounceID.sync),
                    .run { [syncStorage, baseState] send in
                        final class TaskRef: @unchecked Sendable {
                            var id: UIBackgroundTaskIdentifier = .invalid
                        }
                        let taskRef = TaskRef()
                        taskRef.id = await UIApplication.shared.beginBackgroundTask {
                            UIApplication.shared.endBackgroundTask(taskRef.id)
                            taskRef.id = .invalid
                        }
                        defer {
                            if taskRef.id != .invalid {
                                UIApplication.shared.endBackgroundTask(taskRef.id)
                            }
                        }

                        // 1. Read remote
                        let remote = try await syncStorage.read()
                        let base = await baseState.load()

                        // 2. Merge
                        let merged: SyncState
                        if let (remoteData, remoteVersion) = remote {
                            let remoteState = try JSONDecoder().decode(SyncState.self, from: remoteData)
                            guard remoteState.version <= SyncState.currentVersion else {
                                throw SyncStorageError.storageError("Remote state version \(remoteState.version) is newer than supported version \(SyncState.currentVersion). Please update the app.")
                            }
                            let result = StateMerger.merge(base: base, local: localState, remote: remoteState)
                            switch result {
                            case .clean(let s): merged = s
                            case .resolved(let s): merged = s
                            }

                            // 3. Write back (conditional on version), skip if nothing changed
                            if merged.jobs == remoteState.jobs && merged.settings == remoteState.settings {
                                try? await baseState.save(merged)
                                try? await baseState.saveVersion(remoteVersion)
                            } else {
                                let mergedData = try JSONEncoder().encode(merged)
                                let newVersion = try await syncStorage.write(mergedData, remoteVersion)
                                try? await baseState.save(merged)
                                try? await baseState.saveVersion(newVersion)
                            }
                        } else {
                            // No remote state yet: upload local as initial
                            merged = localState
                            let data = try JSONEncoder().encode(merged)
                            let newVersion = try await syncStorage.write(data, nil)
                            try? await baseState.save(merged)
                            try? await baseState.saveVersion(newVersion)
                        }

                        await send(.syncCompleted(.success(merged)))
                    } catch: { error, send in
                        if let storageError = error as? SyncStorageError, case .conflict = storageError {
                            await send(.syncConflict)
                        } else {
                            await send(.syncCompleted(.failure(error)))
                        }
                    }
                )

            case .syncCompleted(.success(let merged)):
                state.isSyncing = false
                state.isSyncEnabled = true
                state.syncRetryCount = 0
                state.lastSyncDate = Date()
                // Apply merged state
                state.jobs = IdentifiedArray(uniqueElements: merged.jobs)
                state.settings = merged.settings
                syncLog.info("Sync completed: \(merged.jobs.count) jobs")
                return .merge(saveJobs(state.jobs), saveSettings(state.settings))

            case .syncCompleted(.failure(let error)):
                state.isSyncing = false
                state.syncError = error.localizedDescription
                state.syncRetryCount = 0
                syncLog.error("Sync failed: \(error.localizedDescription)")
                // Auto-clear error after 5 seconds
                return .run { send in
                    try? await Task.sleep(for: .seconds(5))
                    await send(.dismissSyncError)
                }

            case .syncConflict:
                state.syncRetryCount += 1
                if state.syncRetryCount > 3 {
                    state.syncError = "Sync conflict could not be resolved after multiple retries."
                    state.isSyncing = false
                    state.syncRetryCount = 0
                    return .none
                }
                let delay = Double(state.syncRetryCount) * 1.0
                return .run { send in
                    try await Task.sleep(for: .seconds(delay))
                    await send(.syncNow)
                }

            case .dismissSyncError:
                state.syncError = nil
                return .none

            case .scenePhaseChanged(let phase):
                if phase == .background && state.isSyncEnabled {
                    return .concatenate(
                        .cancel(id: SyncDebounceID.sync),
                        .send(.syncNow)
                    )
                }
                return .none
            }
        }
    }

    private func saveJobs(_ jobs: IdentifiedArrayOf<JobApplication>) -> Effect<Action> {
        .run { _ in
            try await persistence.saveJobs(Array(jobs))
        }
    }

    private func saveSettings(_ settings: AppSettings) -> Effect<Action> {
        .run { [persistence] _ in
            try? await persistence.saveSettings(settings)
        }
    }

    private func debouncedSync(_ state: State) -> Effect<Action> {
        guard state.isSyncEnabled else { return .none }
        return .run { send in
            try await Task.sleep(for: .seconds(5))
            await send(.syncNow)
        }
        .cancellable(id: SyncDebounceID.sync, cancelInFlight: true)
    }
}

// MARK: - Filtered Jobs

extension iOSAppFeature.State {
    var filteredJobs: IdentifiedArrayOf<JobApplication> {
        var result = jobs
        if let filter = filterStatus {
            result = result.filter { $0.status == filter }
        }
        if !searchQuery.isEmpty {
            let query = searchQuery.lowercased()
            result = result.filter {
                $0.company.lowercased().contains(query)
                || $0.title.lowercased().contains(query)
                || $0.location.lowercased().contains(query)
            }
        }
        return result
    }
}

// MARK: - Interview Notifications

private func scheduleNotifications(
    for interviews: [(JobApplication, InterviewRound)]
) async {
    let center = UNUserNotificationCenter.current()
    let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    guard granted == true else { return }

    // Remove only interview notifications (prefixed with "interview-")
    let pending = await center.pendingNotificationRequests()
    let interviewIds = pending.filter { $0.identifier.hasPrefix("interview-") }.map(\.identifier)
    center.removePendingNotificationRequests(withIdentifiers: interviewIds)

    let now = Date()
    for (job, interview) in interviews {
        guard let interviewDate = interview.date, interviewDate > now else { continue }

        // 1 hour before
        let hourBefore = interviewDate.addingTimeInterval(-3600)
        if hourBefore > now {
            let content = UNMutableNotificationContent()
            content.title = "Interview in 1 hour"
            content.body = "\(interview.type) with \(job.company)"
            if !interview.interviewers.isEmpty {
                content.body += " (\(interview.interviewers))"
            }
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: hourBefore.timeIntervalSince(now),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "interview-1h-\(interview.id)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }

        // 1 day before
        let dayBefore = interviewDate.addingTimeInterval(-86400)
        if dayBefore > now {
            let content = UNMutableNotificationContent()
            content.title = "Interview tomorrow"
            content.body = "\(interview.type) with \(job.company)"
            content.sound = .default

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: dayBefore.timeIntervalSince(now),
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: "interview-1d-\(interview.id)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}

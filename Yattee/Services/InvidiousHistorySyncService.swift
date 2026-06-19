//
//  InvidiousHistorySyncService.swift
//  Yattee
//
//  Syncs watched state and playback positions with the signed-in Invidious
//  account. Watched state uses the stock /api/v1/auth/history endpoints;
//  resume positions use the shorts-filter fork's /api/v1/auth/positions.
//
//  Pushes happen during playback (debounced) and on completion. A one-shot
//  pull seeds local state: watched IDs upgrade existing WatchEntry rows to
//  finished, and positions are cached in memory and used as a resume fallback
//  for videos that have no local WatchEntry yet (duration is known at play
//  time, so no fabricated WatchEntry metadata is needed). This is independent
//  of the iCloud watch-history sync.
//

import Foundation

@MainActor
final class InvidiousHistorySyncService {
    private let invidiousAPI: InvidiousAPI
    private let credentialsManager: InvidiousCredentialsManager
    private let instancesManager: InstancesManager
    private let settingsManager: SettingsManager
    private let dataManager: DataManager

    /// Positions from the last pull, plus any we've pushed this session.
    private var serverPositions: [String: Double] = [:]
    /// Debounce bookkeeping for position pushes.
    private var lastPushedAt: [String: Date] = [:]
    private let minPushInterval: TimeInterval = 5

    /// Periodic pull while the app is foregrounded.
    private var periodicSyncTimer: Timer?
    private let periodicSyncInterval: TimeInterval = 300
    /// When the last pull ran, used to throttle foreground-triggered syncs.
    private var lastSyncAt: Date?
    private let minForegroundSyncInterval: TimeInterval = 60

    init(
        invidiousAPI: InvidiousAPI,
        credentialsManager: InvidiousCredentialsManager,
        instancesManager: InstancesManager,
        settingsManager: SettingsManager,
        dataManager: DataManager
    ) {
        self.invidiousAPI = invidiousAPI
        self.credentialsManager = credentialsManager
        self.instancesManager = instancesManager
        self.settingsManager = settingsManager
        self.dataManager = dataManager
    }

    private var enabled: Bool {
        settingsManager.saveWatchHistory && settingsManager.syncWatchHistoryWithInvidiousAccount
    }

    /// Logs why the sync gate is closed, so silent no-ops are diagnosable.
    private func logDisabledReason(_ operation: String) {
        guard !enabled else { return }
        let reason: String
        if !settingsManager.saveWatchHistory {
            reason = "saveWatchHistory is off"
        } else {
            reason = "syncWatchHistoryWithInvidiousAccount toggle is off (Privacy settings)"
        }
        LoggingService.shared.info(
            "Invidious history sync skipped (\(operation)): \(reason)",
            category: .api
        )
    }

    /// Resolves the signed-in Invidious instance and SID, mirroring
    /// InvidiousSubscriptionProvider.getAuthenticatedInstance(). Logs why
    /// resolution failed so silent no-ops are diagnosable.
    private func authenticatedInstance(_ operation: String) -> (Instance, String)? {
        let account = settingsManager.subscriptionAccount
        let instance: Instance?
        if let instanceID = account.instanceID {
            instance = instancesManager.instances.first { $0.id == instanceID && $0.isEnabled }
        } else {
            instance = instancesManager.instances.first { $0.type == .invidious && $0.isEnabled }
        }
        guard let instance else {
            LoggingService.shared.info(
                "Invidious history sync skipped (\(operation)): no enabled Invidious instance " +
                    "(subscriptionAccount.type=\(account.type), instanceID=\(account.instanceID?.uuidString ?? "nil"))",
                category: .api
            )
            return nil
        }
        guard let sid = credentialsManager.sid(for: instance) else {
            LoggingService.shared.info(
                "Invidious history sync skipped (\(operation)): not signed in to \(instance.url.absoluteString)",
                category: .api
            )
            return nil
        }
        return (instance, sid)
    }

    // MARK: - Push

    /// Pushes a resume position. Debounced per video unless `force` is set.
    func pushPosition(videoID: String, seconds: Double, force: Bool = false) {
        guard enabled else { logDisabledReason("pushPosition"); return }
        guard seconds.isFinite, seconds >= 0,
              let (instance, sid) = authenticatedInstance("pushPosition") else { return }
        if !force, let last = lastPushedAt[videoID], Date().timeIntervalSince(last) < minPushInterval {
            return
        }
        lastPushedAt[videoID] = Date()
        serverPositions[videoID] = seconds
        Task {
            do {
                try await invidiousAPI.setPlaybackPosition(videoID: videoID, seconds: seconds, instance: instance, sid: sid)
            } catch {
                LoggingService.shared.error(
                    "Invidious position push failed for \(videoID)",
                    category: .api,
                    details: Self.describe(error)
                )
            }
        }
    }

    func markWatched(videoID: String) {
        guard enabled else { logDisabledReason("markWatched"); return }
        guard let (instance, sid) = authenticatedInstance("markWatched") else { return }
        Task {
            do {
                try await invidiousAPI.markWatched(videoID: videoID, instance: instance, sid: sid)
            } catch {
                LoggingService.shared.error(
                    "Invidious markWatched failed for \(videoID)",
                    category: .api,
                    details: Self.describe(error)
                )
            }
        }
    }

    /// Describes an API error, calling out the fork-only positions endpoint
    /// when a 404 comes back (stock Invidious lacks /api/v1/auth/positions).
    private static func describe(_ error: Error) -> String {
        if case APIError.httpError(let statusCode, let message) = error {
            if statusCode == 404 {
                return "HTTP 404 — endpoint missing. /api/v1/auth/positions requires the " +
                    "shorts-filter Invidious fork; stock Invidious does not support position sync."
            }
            return "HTTP \(statusCode): \(message)"
        }
        if case APIError.unauthorized = error {
            return "unauthorized — SID rejected or expired; sign in to the instance again."
        }
        return String(describing: error)
    }

    // MARK: - Periodic refresh

    /// Starts the periodic foreground refresh timer. Does not sync immediately —
    /// callers trigger their own immediate sync (forced or throttled) as needed.
    /// Idempotent — safe to call repeatedly.
    func startPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: periodicSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sync() }
        }
    }

    /// Stops periodic refresh. Call when the app enters the background. iOS
    /// suspends timers in the background anyway; this makes it explicit and
    /// avoids a redundant fire on resume.
    func stopPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
    }

    /// Syncs only if enough time has passed since the last pull, so rapid
    /// foreground transitions don't trigger redundant requests.
    func syncIfDue() async {
        if let last = lastSyncAt, Date().timeIntervalSince(last) < minForegroundSyncInterval { return }
        await sync()
    }

    // MARK: - Pull

    /// Fetches watched IDs and positions, seeding local state. The two requests
    /// run concurrently since they're independent.
    func sync() async {
        guard enabled else { logDisabledReason("sync"); return }
        guard let (instance, sid) = authenticatedInstance("sync") else { return }
        lastSyncAt = Date()
        async let watchedTask = invidiousAPI.watchHistory(instance: instance, sid: sid)
        async let positionsTask = invidiousAPI.playbackPositions(instance: instance, sid: sid)
        var watched: [String] = []
        do {
            watched = try await watchedTask
        } catch {
            LoggingService.shared.error(
                "Invidious watch-history pull failed",
                category: .api,
                details: Self.describe(error)
            )
        }
        var positions: [String: Double] = [:]
        do {
            positions = try await positionsTask
        } catch {
            LoggingService.shared.error(
                "Invidious positions pull failed",
                category: .api,
                details: Self.describe(error)
            )
        }
        serverPositions = positions
        dataManager.markFinishedFromSync(videoIDs: Set(watched))
        LoggingService.shared.info(
            "Invidious history sync: \(watched.count) watched, \(positions.count) positions from \(instance.url.absoluteString)",
            category: .api
        )
    }

    // MARK: - Resume fallback

    /// A synced resume position for a video with no local WatchEntry.
    func cachedPosition(for videoID: String) -> TimeInterval? {
        guard enabled else { return nil }
        return serverPositions[videoID]
    }
}

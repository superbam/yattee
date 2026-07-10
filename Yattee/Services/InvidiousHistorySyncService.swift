//
//  InvidiousHistorySyncService.swift
//  Yattee
//
//  Syncs watched state and playback positions with the signed-in Invidious
//  account. Watched state uses the stock /api/v1/auth/history endpoints;
//  resume positions use the shorts-filter fork's /api/v1/auth/positions.
//
//  When enabled, the server is the source of truth in both directions:
//  pushes happen during playback (debounced) and on completion/manual mark;
//  pulls fully mirror local WatchEntry.isFinished to the server's watched
//  list (marking AND unmarking), and resume position prefers the synced
//  value over local (see `resumePosition(for:localProgress:)`) rather than
//  merely filling in when there's no local WatchEntry yet. This is
//  independent of the iCloud watch-history sync.
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
    /// Videos already marked watched this session, so the periodic
    /// threshold check doesn't re-POST every tick for the rest of playback.
    private var thresholdMarkedVideoIDs: Set<String> = []

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

    /// Resolves the signed-in Invidious instance and SID. History sync has no
    /// necessary relationship to the subscription account (subscriptions may
    /// live on Piped, a different Invidious instance, or the local account),
    /// so it can't just mirror InvidiousSubscriptionProvider.getAuthenticatedInstance()
    /// the way it used to — that made history sync silently no-op whenever the
    /// subscription account wasn't this exact Invidious login. Instead, prefer
    /// the subscription account's instance when it *is* Invidious (the common
    /// case), then fall back to any other enabled Invidious instance that has
    /// stored credentials. Logs why resolution failed so silent no-ops are
    /// diagnosable.
    private func authenticatedInstance(_ operation: String) -> (Instance, String)? {
        let account = settingsManager.subscriptionAccount
        var candidates = instancesManager.instances.filter { $0.type == .invidious && $0.isEnabled }
        if account.type == .invidious, let instanceID = account.instanceID,
           let index = candidates.firstIndex(where: { $0.id == instanceID }) {
            let preferred = candidates.remove(at: index)
            candidates.insert(preferred, at: 0)
        }
        guard let instance = candidates.first(where: { credentialsManager.sid(for: $0) != nil }) else {
            LoggingService.shared.info(
                "Invidious history sync skipped (\(operation)): no enabled Invidious instance with stored credentials " +
                    "(\(candidates.count) enabled Invidious instance(s) checked)",
                category: .api
            )
            return nil
        }
        guard let sid = credentialsManager.sid(for: instance) else { return nil }
        return (instance, sid)
    }

    /// Records a definitive fork-detection result learned from a real API
    /// response (not just the add-time/status-probe checks), so future calls
    /// can skip wasted round trips once we know for certain an instance
    /// doesn't support position sync — and so an instance that gets upgraded
    /// to the fork starts getting synced without the user re-adding it.
    private func recordForkDetection(_ instance: Instance, isFork: Bool) {
        guard instance.isShortsFilterFork != isFork else { return }
        var updated = instance
        updated.isShortsFilterFork = isFork
        instancesManager.update(updated)
    }

    // MARK: - Push

    /// Pushes a resume position. Debounced per video unless `force` is set.
    func pushPosition(videoID: String, seconds: Double, force: Bool = false) {
        guard enabled else { logDisabledReason("pushPosition"); return }
        guard seconds.isFinite, seconds >= 0,
              let (instance, sid) = authenticatedInstance("pushPosition"),
              instance.likelySupportsPositionSync else { return }
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

    /// Pushes an unwatched state, e.g. from the manual "Mark Unwatched" action.
    /// Needed so a manual local unmark isn't undone by the next sync pull,
    /// which now mirrors the server list exactly in both directions. Also
    /// clears the server-side resume position — otherwise the next open
    /// still resumes from the old position via `resumePosition`, defeating
    /// the point of unwatching.
    func markUnwatched(videoID: String) {
        guard enabled else { logDisabledReason("markUnwatched"); return }
        guard let (instance, sid) = authenticatedInstance("markUnwatched") else { return }
        thresholdMarkedVideoIDs.remove(videoID)
        serverPositions[videoID] = nil
        Task {
            do {
                try await invidiousAPI.markUnwatched(videoID: videoID, instance: instance, sid: sid)
            } catch {
                LoggingService.shared.error(
                    "Invidious markUnwatched failed for \(videoID)",
                    category: .api,
                    details: Self.describe(error)
                )
            }
            guard instance.likelySupportsPositionSync else { return }
            do {
                try await invidiousAPI.deletePlaybackPosition(videoID: videoID, instance: instance, sid: sid)
            } catch {
                LoggingService.shared.error(
                    "Invidious deletePlaybackPosition failed for \(videoID)",
                    category: .api,
                    details: Self.describe(error)
                )
            }
        }
    }

    /// Marks watched once playback crosses `invidiousMarkWatchedThresholdPercent`,
    /// so server-side history reflects normal viewing (stopping before the
    /// literal end, skipping the outro, switching videos) instead of requiring
    /// true end-of-file. Called from the periodic progress-save tick, so this
    /// guards against re-POSTing on every subsequent tick once the threshold
    /// is crossed. Natural end-of-file still calls `markWatched` directly as
    /// an unconditional backstop.
    func markWatchedIfThresholdReached(videoID: String, progress: Double) {
        guard enabled, progress.isFinite else { return }
        guard !thresholdMarkedVideoIDs.contains(videoID) else { return }
        let threshold = Double(settingsManager.invidiousMarkWatchedThresholdPercent) / 100
        guard progress >= threshold else { return }
        thresholdMarkedVideoIDs.insert(videoID)
        markWatched(videoID: videoID)
    }

    /// Describes an API error, calling out the fork-only positions endpoint
    /// when a 404 comes back (stock Invidious lacks /api/v1/auth/positions).
    private static func describe(_ error: Error) -> String {
        if case APIError.httpError(let statusCode, let message) = error {
            if statusCode == 404 {
                return "HTTP 404 — endpoint missing. /api/v1/auth/positions requires the " +
                    "shorts-filter Invidious fork; stock Invidious does not support position sync."
            }
            return "HTTP \(statusCode): \(message ?? "no message")"
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
        async let positionsResult = fetchPositions(instance: instance, sid: sid)
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
        let positions = await positionsResult
        serverPositions = positions
        dataManager.reconcileFinishedFromSync(watchedVideoIDs: Set(watched))
        LoggingService.shared.info(
            "Invidious history sync: \(watched.count) watched, \(positions.count) positions from \(instance.url.absoluteString)",
            category: .api
        )
        // Seed full history rows for account-watched videos this device has
        // never seen, so they appear in History (not just as watched badges).
        await hydrateWatchedEntries(watchedIDs: watched, instance: instance)
    }

    /// Fetches the bulk positions map, skipping the request entirely once the
    /// instance is confirmed not to support it. This is also where fork
    /// support gets definitively confirmed or ruled out: a success means the
    /// instance is fork-enabled, a 404 means it isn't — either way the result
    /// is persisted so later calls (push/fresh-fetch/delete) can trust the
    /// flag instead of guessing. (playback-sync)
    private func fetchPositions(instance: Instance, sid: String) async -> [String: Double] {
        guard instance.likelySupportsPositionSync else { return [:] }
        do {
            let result = try await invidiousAPI.playbackPositions(instance: instance, sid: sid)
            recordForkDetection(instance, isFork: true)
            return result
        } catch APIError.httpError(404, _) {
            recordForkDetection(instance, isFork: false)
            return [:]
        } catch {
            LoggingService.shared.error(
                "Invidious positions pull failed",
                category: .api,
                details: Self.describe(error)
            )
            return [:]
        }
    }

    // MARK: - Watched-entry hydration

    /// Bounded concurrency for the one-time metadata backfill, so a large first
    /// sync doesn't hammer the instance.
    private let maxHydrationConcurrency = 4
    /// Cap per sync run — a safety valve against a runaway account; the rest is
    /// picked up on the next sync since the IDs still lack a local entry.
    private let maxHydrationPerSync = 300

    /// Fetches metadata for account-watched videos that have no local
    /// WatchEntry and creates finished history rows for them. Failures (e.g. a
    /// video the instance can't resolve) are skipped and retried on the next
    /// sync. Steady state is a no-op once every watched video has a local row.
    private func hydrateWatchedEntries(watchedIDs: [String], instance: Instance) async {
        let missing = dataManager.videoIDsWithoutWatchEntry(among: watchedIDs)
        guard !missing.isEmpty else { return }
        let toFetch = Array(missing.prefix(maxHydrationPerSync))
        LoggingService.shared.info(
            "Invidious history sync: hydrating \(toFetch.count) watched videos missing locally",
            category: .api
        )

        var fetched: [Video] = []
        var index = 0
        while index < toFetch.count {
            let end = min(index + maxHydrationConcurrency, toFetch.count)
            let batch = Array(toFetch[index..<end])
            index = end
            await withTaskGroup(of: Video?.self) { group in
                for id in batch {
                    let api = invidiousAPI
                    group.addTask {
                        try? await api.video(id: id, instance: instance)
                    }
                }
                for await video in group {
                    if let video { fetched.append(video) }
                }
            }
        }

        dataManager.createFinishedEntriesFromSync(videos: fetched)
        LoggingService.shared.info(
            "Invidious history sync: created \(fetched.count) watched history rows from metadata " +
                "(\(toFetch.count - fetched.count) failed, will retry next sync)",
            category: .api
        )
    }

    // MARK: - Resume resolution

    /// Resolves the resume position for a video: the Invidious-synced server
    /// position when sync is enabled and available (the source of truth),
    /// otherwise `localProgress`. Callers deciding where to resume playback
    /// should route through this instead of reading local watch progress
    /// directly and treating it as final — otherwise a position set on
    /// another device can never win over a local value.
    func resumePosition(for video: Video, localProgress: TimeInterval?) async -> TimeInterval? {
        guard case .global = video.id.source else { return localProgress }
        let synced = await freshPosition(for: video.id.videoID)
        return synced ?? localProgress
    }

    /// Blocking lookup for the load path: fetches the freshest server position
    /// for one video so first-open resume reflects another device immediately,
    /// rather than waiting for the next background pull. Prefers the lightweight
    /// single-video endpoint; falls back to a full positions pull on instances
    /// that lack it, and to the cached value if the network fails entirely.
    /// Updates the cache so the badge/list paths see the fresh value too.
    func freshPosition(for videoID: String) async -> TimeInterval? {
        guard enabled, let (instance, sid) = authenticatedInstance("freshPosition"),
              instance.likelySupportsPositionSync else {
            return serverPositions[videoID]
        }
        do {
            let seconds = try await invidiousAPI.playbackPosition(videoID: videoID, instance: instance, sid: sid)
            recordForkDetection(instance, isFork: true)
            serverPositions[videoID] = seconds
            return seconds
        } catch APIError.httpError(404, _) {
            // Single-video endpoint missing doesn't necessarily mean "not the
            // fork" — could be an older fork build predating that route — so
            // fall back to the bulk pull rather than concluding non-support
            // here. `fetchPositions` is what actually records the definitive
            // fork detection, from the bulk endpoint's result. We already
            // know support is at least "likely" (checked above), so this
            // still attempts the bulk call rather than short-circuiting.
            let positions = await fetchPositions(instance: instance, sid: sid)
            serverPositions = positions
            return positions[videoID]
        } catch {
            // Timeout / network / other — don't pile on another request; load
            // the video now using the last cached position.
            return serverPositions[videoID]
        }
    }
}

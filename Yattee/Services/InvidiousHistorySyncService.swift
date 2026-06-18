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

    /// Resolves the signed-in Invidious instance and SID, mirroring
    /// InvidiousSubscriptionProvider.getAuthenticatedInstance().
    private func authenticatedInstance() -> (Instance, String)? {
        let account = settingsManager.subscriptionAccount
        let instance: Instance?
        if let instanceID = account.instanceID {
            instance = instancesManager.instances.first { $0.id == instanceID && $0.isEnabled }
        } else {
            instance = instancesManager.instances.first { $0.type == .invidious && $0.isEnabled }
        }
        guard let instance, let sid = credentialsManager.sid(for: instance) else { return nil }
        return (instance, sid)
    }

    // MARK: - Push

    /// Pushes a resume position. Debounced per video unless `force` is set.
    func pushPosition(videoID: String, seconds: Double, force: Bool = false) {
        guard enabled, seconds.isFinite, seconds >= 0,
              let (instance, sid) = authenticatedInstance() else { return }
        if !force, let last = lastPushedAt[videoID], Date().timeIntervalSince(last) < minPushInterval {
            return
        }
        lastPushedAt[videoID] = Date()
        serverPositions[videoID] = seconds
        Task {
            try? await invidiousAPI.setPlaybackPosition(videoID: videoID, seconds: seconds, instance: instance, sid: sid)
        }
    }

    func markWatched(videoID: String) {
        guard enabled, let (instance, sid) = authenticatedInstance() else { return }
        Task {
            try? await invidiousAPI.markWatched(videoID: videoID, instance: instance, sid: sid)
        }
    }

    // MARK: - Pull

    /// Fetches watched IDs and positions once, seeding local state.
    func sync() async {
        guard enabled, let (instance, sid) = authenticatedInstance() else { return }
        let watched = (try? await invidiousAPI.watchHistory(instance: instance, sid: sid)) ?? []
        let positions = (try? await invidiousAPI.playbackPositions(instance: instance, sid: sid)) ?? [:]
        serverPositions = positions
        dataManager.markFinishedFromSync(videoIDs: Set(watched))
        LoggingService.shared.info(
            "Invidious history sync: \(watched.count) watched, \(positions.count) positions",
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

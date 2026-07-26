//
//  NotRecommendService.swift
//  Yattee
//
//  FORK (norecommend): the signed-in Invidious account's "don't recommend"
//  list for videos and channels.
//
//  The server excludes blocked entries from the Discover feed, and from
//  `recommendedVideos` on video detail when the request carries the session
//  cookie. Everything else — search, channel tabs, trending, popular — isn't
//  per-user server-side, so this service keeps the list in memory and
//  callers filter as rows are built. Filtering on render rather than on
//  fetch means newly blocked items disappear from already-loaded lists
//  without a refetch.
//
//  The list lives on one Invidious account, so it does not exist for
//  logged-out users and is not a local block list — nothing is filtered
//  when no fork instance is signed in.
//

import Foundation

@MainActor
@Observable
final class NotRecommendService {
    // MARK: - Dependencies

    private let invidiousAPI: InvidiousAPI
    private let credentialsManager: InvidiousCredentialsManager
    private let instancesManager: InstancesManager
    private let settingsManager: SettingsManager

    // MARK: - State

    private(set) var videos: Set<String> = []
    private(set) var channels: Set<String> = []

    /// Videos ∪ channels, so `isBlocked` is one hash lookup on the render
    /// path instead of two. Video IDs and UCIDs can't collide (11 chars vs
    /// `UC` + 22), so merging them is safe.
    private var blocked: Set<String> = []

    /// Nil until the first successful load. Distinguishes "no blocked items"
    /// from "never loaded", which the settings screen needs in order to show
    /// a spinner rather than an empty state.
    private(set) var lastLoadedAt: Date?

    /// True once we've confirmed the signed-in instance doesn't have the
    /// fork API (404). Suppresses the UI entirely rather than surfacing
    /// errors on stock Invidious.
    private(set) var isUnavailable = false

    private var isLoading = false

    // MARK: - Initialization

    init(
        invidiousAPI: InvidiousAPI,
        credentialsManager: InvidiousCredentialsManager,
        instancesManager: InstancesManager,
        settingsManager: SettingsManager
    ) {
        self.invidiousAPI = invidiousAPI
        self.credentialsManager = credentialsManager
        self.instancesManager = instancesManager
        self.settingsManager = settingsManager

        // Signing in/out or switching instances changes whose list applies.
        NotificationCenter.default.addObserver(
            forName: .instancesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    // MARK: - Availability

    /// Resolves the Invidious instance whose account owns the list. Mirrors
    /// `InvidiousHistorySyncService.authenticatedInstance`: prefer the
    /// subscription account's instance when it's Invidious, then fall back
    /// to any enabled Invidious instance with stored credentials.
    ///
    /// Gated on `isShortsFilterFork != false` — unknown counts as worth
    /// trying, so an instance added before detection ran still works, and a
    /// confirmed-stock one is skipped.
    private func authenticatedInstance() -> (Instance, String)? {
        let account = settingsManager.subscriptionAccount
        var candidates = instancesManager.instances.filter {
            $0.type == .invidious && $0.isEnabled && $0.isShortsFilterFork != false
        }
        if account.type == .invidious, let instanceID = account.instanceID,
           let index = candidates.firstIndex(where: { $0.id == instanceID }) {
            let preferred = candidates.remove(at: index)
            candidates.insert(preferred, at: 0)
        }
        guard let instance = candidates.first(where: { credentialsManager.sid(for: $0) != nil }),
              let sid = credentialsManager.sid(for: instance) else {
            return nil
        }
        return (instance, sid)
    }

    /// Whether to offer the feature at all. False when logged out, when no
    /// fork instance is configured, or once the endpoint has 404'd.
    var isAvailable: Bool {
        !isUnavailable && authenticatedInstance() != nil
    }

    // MARK: - Queries

    /// True if this video or its channel is blocked. Called per row while
    /// lists render, so it stays a single set lookup.
    func isBlocked(videoID: String?, channelID: String?) -> Bool {
        guard !blocked.isEmpty else { return false }
        if let videoID, blocked.contains(videoID) { return true }
        if let channelID, blocked.contains(channelID) { return true }
        return false
    }

    func isBlocked(_ video: Video) -> Bool {
        isBlocked(videoID: video.id.videoID, channelID: video.author.id)
    }

    /// Whether these IDs are shaped like something the server will accept,
    /// so callers can hide an action rather than offer one that no-ops.
    func canBlock(videoID: String) -> Bool { isValidID(videoID, isVideo: true) }
    func canBlock(channelID: String) -> Bool { isValidID(channelID, isVideo: false) }

    /// Removes blocked entries from a list of videos.
    func filtered(_ videos: [Video]) -> [Video] {
        guard !blocked.isEmpty else { return videos }
        return videos.filter { !isBlocked($0) }
    }

    // MARK: - Loading

    /// Loads the list for the current account. Safe to call repeatedly.
    func refresh() async {
        guard !isLoading else { return }
        guard let (instance, sid) = authenticatedInstance() else {
            // Logged out or no fork instance — drop any previous account's
            // list so its entries don't keep filtering the current session.
            reset()
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let list = try await invidiousAPI.notRecommended(instance: instance, sid: sid)
            apply(list)
            isUnavailable = false
            lastLoadedAt = Date()
        } catch APIError.notFound {
            // Stock Invidious: feature off, not an error. Record it so the
            // instance stops being asked and the UI hides itself.
            reset()
            isUnavailable = true
            recordForkDetection(instance, isFork: false)
        } catch {
            LoggingService.shared.error(
                "Failed to load don't-recommend list",
                category: .api,
                details: error.localizedDescription
            )
        }
    }

    private func apply(_ list: NotRecommendedList) {
        videos = Set(list.videos)
        channels = Set(list.channels)
        blocked = videos.union(channels)
    }

    private func reset() {
        videos = []
        channels = []
        blocked = []
        lastLoadedAt = nil
    }

    /// Mirrors `InvidiousHistorySyncService.recordForkDetection`: a definitive
    /// answer from a real API call is worth persisting so other fork-only
    /// features skip their round trips too.
    private func recordForkDetection(_ instance: Instance, isFork: Bool) {
        guard instance.isShortsFilterFork != isFork else { return }
        var updated = instance
        updated.isShortsFilterFork = isFork
        instancesManager.update(updated)
    }

    // MARK: - Mutations

    /// Blocks a video. Updates local state first so the row disappears
    /// immediately, and rolls back if the request fails.
    @discardableResult
    func blockVideo(_ videoID: String) async -> Bool {
        await mutate(id: videoID, isVideo: true, blocking: true)
    }

    @discardableResult
    func unblockVideo(_ videoID: String) async -> Bool {
        await mutate(id: videoID, isVideo: true, blocking: false)
    }

    @discardableResult
    func blockChannel(_ channelID: String) async -> Bool {
        await mutate(id: channelID, isVideo: false, blocking: true)
    }

    @discardableResult
    func unblockChannel(_ channelID: String) async -> Bool {
        await mutate(id: channelID, isVideo: false, blocking: false)
    }

    /// The server validates these and 400s on a mismatch, so checking here
    /// avoids optimistically showing a change that can never land.
    private func isValidID(_ id: String, isVideo: Bool) -> Bool {
        let pattern = isVideo ? "^[a-zA-Z0-9_-]{11}$" : "^UC[a-zA-Z0-9_-]{22}$"
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    private func mutate(id: String, isVideo: Bool, blocking: Bool) async -> Bool {
        guard isValidID(id, isVideo: isVideo),
              let (instance, sid) = authenticatedInstance() else { return false }

        let previousVideos = videos
        let previousChannels = channels
        let previousBlocked = blocked

        // Optimistic: the mutations are idempotent, so a retry after a
        // failed rollback is always safe.
        if blocking {
            if isVideo { videos.insert(id) } else { channels.insert(id) }
            blocked.insert(id)
        } else {
            if isVideo { videos.remove(id) } else { channels.remove(id) }
            blocked.remove(id)
        }

        do {
            switch (isVideo, blocking) {
            case (true, true):
                try await invidiousAPI.notRecommendVideo(videoID: id, instance: instance, sid: sid)
            case (true, false):
                try await invidiousAPI.recommendVideo(videoID: id, instance: instance, sid: sid)
            case (false, true):
                try await invidiousAPI.notRecommendChannel(channelID: id, instance: instance, sid: sid)
            case (false, false):
                try await invidiousAPI.recommendChannel(channelID: id, instance: instance, sid: sid)
            }
            return true
        } catch {
            videos = previousVideos
            channels = previousChannels
            blocked = previousBlocked
            LoggingService.shared.error(
                "Failed to update don't-recommend list",
                category: .api,
                details: error.localizedDescription
            )
            return false
        }
    }

    /// Clears the whole list.
    @discardableResult
    func clearAll() async -> Bool {
        guard let (instance, sid) = authenticatedInstance() else { return false }

        let previousVideos = videos
        let previousChannels = channels
        let previousBlocked = blocked
        reset()
        lastLoadedAt = Date()

        do {
            try await invidiousAPI.clearNotRecommended(instance: instance, sid: sid)
            return true
        } catch {
            videos = previousVideos
            channels = previousChannels
            blocked = previousBlocked
            LoggingService.shared.error(
                "Failed to clear don't-recommend list",
                category: .api,
                details: error.localizedDescription
            )
            return false
        }
    }
}

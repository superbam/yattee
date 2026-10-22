//
//  InvidiousPlaylistSyncService.swift
//  Yattee
//
//  Two-way sync between the signed-in Invidious account's playlists and local
//  playlists (playlist-sync).
//
//  Account playlists are mirrored as ordinary LocalPlaylists so every existing
//  playlist screen, the "add to playlist" sheet and playback queueing work
//  unchanged. A per-device link table maps each mirrored LocalPlaylist to its
//  Invidious playlist ID and remembers the video IDs as of the last successful
//  sync. Each sync does a three-way merge per playlist against that snapshot:
//
//    local adds/removes   = local  vs snapshot  -> pushed to the account
//    remote adds/removes  = remote vs snapshot  -> applied locally
//
//  so additions AND removals propagate in both directions, offline edits are
//  picked up on the next sync, and nothing is deleted just because it is
//  missing on one side.
//
//  Scope:
//  - Only playlists created by this service (mirrored from the account, or
//    created in Yattee while sync is on) are linked. Pre-existing local
//    playlists are never uploaded or touched.
//  - Only YouTube videos sync; other items in a linked playlist stay local.
//  - Linked playlists are not queued to CloudKit (see DataManager+InvidiousPlaylistSync).
//

import Foundation

@MainActor
final class InvidiousPlaylistSyncService {
    struct Link: Codable {
        var instanceID: UUID
        /// nil until the playlist has been created on the account.
        var playlistID: String?
        /// YouTube video IDs as of the last fully successful sync.
        var baseVideoIDs: [String]
        var baseTitle: String
        var baseDescription: String
    }

    private struct PendingDelete: Codable, Hashable {
        var instanceID: UUID
        var playlistID: String
    }

    private let invidiousAPI: InvidiousAPI
    private let credentialsManager: InvidiousCredentialsManager
    private let instancesManager: InstancesManager
    private let settingsManager: SettingsManager
    private let dataManager: DataManager

    private static let linksKey = "invidiousPlaylistSync.links"
    private static let pendingDeletesKey = "invidiousPlaylistSync.pendingDeletes"

    /// Keyed by LocalPlaylist.id.uuidString.
    private var links: [String: Link]
    /// Account playlists deleted locally whose remote delete hasn't succeeded
    /// yet; also stops the pull from resurrecting them.
    private var pendingDeletes: Set<PendingDelete>

    private var isSyncing = false
    private var needsResync = false
    private var pushTask: Task<Void, Never>?
    private let pushDebounce: Duration = .seconds(2)

    private var periodicSyncTimer: Timer?
    private let periodicSyncInterval: TimeInterval = 300
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
        let defaults = UserDefaults.standard
        self.links = defaults.data(forKey: Self.linksKey)
            .flatMap { try? JSONDecoder().decode([String: Link].self, from: $0) } ?? [:]
        self.pendingDeletes = defaults.data(forKey: Self.pendingDeletesKey)
            .flatMap { try? JSONDecoder().decode(Set<PendingDelete>.self, from: $0) } ?? []
    }

    private var enabled: Bool { settingsManager.syncPlaylistsWithInvidiousAccount }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(links), forKey: Self.linksKey)
        defaults.set(try? JSONEncoder().encode(pendingDeletes), forKey: Self.pendingDeletesKey)
    }

    /// Same resolution rules as the history sync: prefer the subscription
    /// account's Invidious instance, else any enabled Invidious instance with
    /// stored credentials.
    private func authenticatedInstance() -> (Instance, String)? {
        let account = settingsManager.subscriptionAccount
        var candidates = instancesManager.instances.filter { $0.type == .invidious && $0.isEnabled }
        if account.type == .invidious, let instanceID = account.instanceID,
           let index = candidates.firstIndex(where: { $0.id == instanceID }) {
            candidates.insert(candidates.remove(at: index), at: 0)
        }
        for instance in candidates {
            if let sid = credentialsManager.sid(for: instance) { return (instance, sid) }
        }
        return nil
    }

    private func log(_ message: String, details: String? = nil, error: Bool = false) {
        if error {
            LoggingService.shared.error("Invidious playlist sync: \(message)", category: .api, details: details)
        } else {
            LoggingService.shared.info("Invidious playlist sync: \(message)", category: .api)
        }
    }

    // MARK: - Local change hooks (called from DataManager)

    /// Whether a local playlist is managed by this service. Independent of the
    /// toggle so a mirrored playlist never leaks into CloudKit if the toggle is
    /// switched off.
    func isLinked(_ playlist: LocalPlaylist) -> Bool {
        links[playlist.id.uuidString] != nil
    }

    /// Registers a playlist just created in Yattee to be created on the
    /// account. Returns false (leaving it a normal local playlist) when sync is
    /// off or no signed-in Invidious instance is available.
    @discardableResult
    func registerNewLocalPlaylist(_ playlist: LocalPlaylist) -> Bool {
        guard enabled, let (instance, _) = authenticatedInstance() else { return false }
        links[playlist.id.uuidString] = Link(
            instanceID: instance.id,
            playlistID: nil,
            baseVideoIDs: [],
            baseTitle: playlist.title,
            baseDescription: playlist.playlistDescription ?? ""
        )
        persist()
        schedulePush()
        return true
    }

    func localPlaylistDeleted(id: UUID) {
        guard let link = links.removeValue(forKey: id.uuidString) else { return }
        if enabled, let remoteID = link.playlistID {
            pendingDeletes.insert(PendingDelete(instanceID: link.instanceID, playlistID: remoteID))
        }
        persist()
        schedulePush()
    }

    func localPlaylistChanged() {
        schedulePush()
    }

    /// Debounced so a burst of edits (e.g. adding several videos) becomes one sync.
    private func schedulePush() {
        guard enabled else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self, pushDebounce] in
            try? await Task.sleep(for: pushDebounce)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: - Periodic refresh

    func startPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: periodicSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sync() }
        }
    }

    func stopPeriodicSync() {
        periodicSyncTimer?.invalidate()
        periodicSyncTimer = nil
    }

    func syncIfDue() async {
        if let last = lastSyncAt, Date().timeIntervalSince(last) < minForegroundSyncInterval { return }
        await sync()
    }

    // MARK: - Sync

    /// Runs a full two-way sync. Calls made while a sync is running are
    /// coalesced into one follow-up run.
    func sync() async {
        guard enabled else { return }
        if isSyncing {
            needsResync = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsResync = false
            guard enabled, let (instance, sid) = authenticatedInstance() else { return }
            lastSyncAt = Date()
            await runSync(instance: instance, sid: sid)
        } while needsResync
    }

    private func runSync(instance: Instance, sid: String) async {
        await flushPendingDeletes(instance: instance, sid: sid)

        let remote: [InvidiousAccountPlaylist]
        do {
            remote = try await invidiousAPI.accountPlaylists(instance: instance, sid: sid)
        } catch {
            log("could not list account playlists", details: String(describing: error), error: true)
            return
        }
        let remoteByID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pendingDeleteIDs = Set(pendingDeletes.filter { $0.instanceID == instance.id }.map(\.playlistID))

        // Playlists created in this run may not be in the list fetched above.
        var created = Set<String>()

        // Linked playlists on this instance.
        for (key, link) in links where link.instanceID == instance.id {
            guard let uuid = UUID(uuidString: key), let playlist = dataManager.playlist(forID: uuid) else {
                // Deleted locally by some other path (e.g. data reset). Drop the
                // link only; the account playlist is re-mirrored below.
                links[key] = nil
                continue
            }
            do {
                var link = link
                if link.playlistID == nil {
                    link.playlistID = try await invidiousAPI.createAccountPlaylist(
                        title: playlist.title,
                        description: playlist.playlistDescription,
                        privacy: "private",
                        instance: instance,
                        sid: sid
                    )
                    link.baseTitle = playlist.title
                    link.baseDescription = playlist.playlistDescription ?? ""
                    links[key] = link
                    persist()
                    created.insert(link.playlistID ?? "")
                    log("created \"\(playlist.title)\" on \(instance.url.absoluteString)")
                }
                guard let remoteID = link.playlistID else { continue }
                let summary = remoteByID[remoteID]
                    ?? (created.contains(remoteID)
                        ? InvidiousAccountPlaylist(id: remoteID, title: link.baseTitle, description: link.baseDescription, videoCount: 0)
                        : nil)
                guard let summary else {
                    // Deleted on the account: remove the local mirror.
                    log("\"\(playlist.title)\" was deleted on the account; removing locally")
                    dataManager.deleteMirroredPlaylist(playlist)
                    links[key] = nil
                    continue
                }
                links[key] = try await merge(playlist: playlist, link: link, summary: summary, instance: instance, sid: sid)
            } catch {
                log("sync of \"\(playlist.title)\" failed; will retry", details: String(describing: error), error: true)
            }
        }

        // Account playlists with no local mirror yet.
        let linkedRemoteIDs = Set(links.values.filter { $0.instanceID == instance.id }.compactMap(\.playlistID))
        for summary in remote where !linkedRemoteIDs.contains(summary.id) && !pendingDeleteIDs.contains(summary.id) {
            do {
                let entries = try await invidiousAPI.accountPlaylistEntries(id: summary.id, instance: instance, sid: sid)
                let playlist = dataManager.createMirroredPlaylist(
                    title: summary.title,
                    description: summary.description?.isEmpty == false ? summary.description : nil,
                    videos: entries.map(\.video)
                )
                links[playlist.id.uuidString] = Link(
                    instanceID: instance.id,
                    playlistID: summary.id,
                    baseVideoIDs: entries.map { $0.video.id.videoID },
                    baseTitle: summary.title,
                    baseDescription: summary.description ?? ""
                )
                log("mirrored \"\(summary.title)\" (\(entries.count) videos)")
            } catch {
                log("could not mirror \"\(summary.title)\"", details: String(describing: error), error: true)
            }
        }

        persist()
    }

    private func flushPendingDeletes(instance: Instance, sid: String) async {
        for pending in pendingDeletes where pending.instanceID == instance.id {
            do {
                try await invidiousAPI.deleteAccountPlaylist(id: pending.playlistID, instance: instance, sid: sid)
                pendingDeletes.remove(pending)
                log("deleted \(pending.playlistID) on the account")
            } catch APIError.httpError(404, _) {
                pendingDeletes.remove(pending)
            } catch {
                log("could not delete \(pending.playlistID) on the account; will retry", details: String(describing: error), error: true)
            }
        }
        persist()
    }

    // MARK: - Merge

    private func merge(
        playlist: LocalPlaylist,
        link: Link,
        summary: InvidiousAccountPlaylist,
        instance: Instance,
        sid: String
    ) async throws -> Link {
        var link = link
        let entries = try await invidiousAPI.accountPlaylistEntries(id: summary.id, instance: instance, sid: sid)
        let remoteIDs = entries.map { $0.video.id.videoID }
        let remoteSet = Set(remoteIDs)
        let localIDs = playlist.sortedItems.filter(\.isYouTubeVideo).map(\.videoID)
        let localSet = Set(localIDs)
        let base = Set(link.baseVideoIDs)

        let localAdds = localIDs.filter { !base.contains($0) && !remoteSet.contains($0) }
        let localRemoves = base.subtracting(localSet).intersection(remoteSet)
        var seenRemoteAdds = Set<String>()
        let remoteAdds = entries.map(\.video).filter {
            let id = $0.id.videoID
            return !base.contains(id) && !localSet.contains(id) && seenRemoteAdds.insert(id).inserted
        }
        let remoteRemoves = base.subtracting(remoteSet).intersection(localSet)

        // Title / description: remote wins when both changed.
        let remoteDescription = summary.description ?? ""
        let localDescription = playlist.playlistDescription ?? ""
        var metadata: (title: String, description: String?)?
        var metadataPushFailed = false
        if summary.title != link.baseTitle || remoteDescription != link.baseDescription {
            if summary.title != playlist.title || remoteDescription != localDescription {
                metadata = (summary.title, remoteDescription.isEmpty ? nil : remoteDescription)
            }
            link.baseTitle = summary.title
            link.baseDescription = remoteDescription
        } else if playlist.title != link.baseTitle || localDescription != link.baseDescription {
            do {
                try await invidiousAPI.updateAccountPlaylist(
                    id: summary.id,
                    title: playlist.title,
                    description: playlist.playlistDescription,
                    instance: instance,
                    sid: sid
                )
                link.baseTitle = playlist.title
                link.baseDescription = localDescription
            } catch {
                metadataPushFailed = true
                log("could not push metadata of \"\(playlist.title)\"", details: String(describing: error), error: true)
            }
        }

        // Push local changes to the account.
        var pushFailed = metadataPushFailed
        for videoID in localAdds {
            do {
                try await invidiousAPI.addVideoToAccountPlaylist(playlistID: summary.id, videoID: videoID, instance: instance, sid: sid)
            } catch {
                pushFailed = true
                log("could not add \(videoID) to \"\(playlist.title)\"", details: String(describing: error), error: true)
            }
        }
        for videoID in localRemoves {
            for entry in entries where entry.video.id.videoID == videoID {
                do {
                    try await invidiousAPI.removeVideoFromAccountPlaylist(playlistID: summary.id, indexId: entry.indexId, instance: instance, sid: sid)
                } catch APIError.httpError(404, _) {
                    continue
                } catch {
                    pushFailed = true
                    log("could not remove \(videoID) from \"\(playlist.title)\"", details: String(describing: error), error: true)
                }
            }
        }

        // Apply remote changes locally.
        if metadata != nil || !remoteAdds.isEmpty || !remoteRemoves.isEmpty || remoteIDs != localIDs {
            dataManager.applyMirroredChanges(
                to: playlist,
                metadata: metadata,
                removingVideoIDs: remoteRemoves,
                adding: remoteAdds,
                order: remoteIDs + localAdds
            )
        }

        if !pushFailed {
            link.baseVideoIDs = playlist.sortedItems.filter(\.isYouTubeVideo).map(\.videoID)
        }
        let changes = localAdds.count + localRemoves.count + remoteAdds.count + remoteRemoves.count
        if changes > 0 {
            log("\"\(playlist.title)\": pushed +\(localAdds.count)/-\(localRemoves.count), pulled +\(remoteAdds.count)/-\(remoteRemoves.count)")
        }
        return link
    }
}

//
//  DataManager+InvidiousPlaylistSync.swift
//  Yattee
//
//  Fork addition (playlist-sync): SwiftData side of Invidious account playlist
//  sync. These helpers deliberately do NOT queue CloudKit changes: a mirrored
//  playlist's source of truth is the Invidious account, and every device
//  mirrors it independently, so also syncing it through iCloud would create
//  duplicate playlists/items on devices that mirror the account themselves.
//  See InvidiousPlaylistSyncService.
//

import Foundation
import SwiftData

extension LocalPlaylistItem {
    /// Whether this item is a YouTube video, i.e. something an Invidious
    /// playlist can hold. PeerTube, local-file and extracted items never sync.
    var isYouTubeVideo: Bool {
        sourceRawValue == "global" && (globalProvider ?? ContentSource.youtubeProvider) == ContentSource.youtubeProvider
    }
}

extension DataManager {
    /// Creates a local playlist mirroring an Invidious playlist.
    func createMirroredPlaylist(title: String, description: String?, videos: [Video]) -> LocalPlaylist {
        let playlist = LocalPlaylist(title: title, description: description)
        modelContext.insert(playlist)
        for video in videos {
            playlist.addVideo(video)
        }
        save()
        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
        return playlist
    }

    /// Applies remote changes to a mirrored playlist: optional new metadata,
    /// removals and additions of YouTube videos, then re-orders items to follow
    /// `order` (the account's order). Items not in `order` (non-YouTube items,
    /// or videos waiting to be pushed) keep their relative order after it.
    func applyMirroredChanges(
        to playlist: LocalPlaylist,
        metadata: (title: String, description: String?)?,
        removingVideoIDs: Set<String>,
        adding videos: [Video],
        order: [String]
    ) {
        if let metadata {
            playlist.title = metadata.title
            playlist.playlistDescription = metadata.description
        }

        for item in playlist.sortedItems where item.isYouTubeVideo && removingVideoIDs.contains(item.videoID) {
            playlist.items?.removeAll { $0.id == item.id }
            modelContext.delete(item)
        }

        for video in videos where !playlist.contains(videoID: video.id.videoID) {
            playlist.addVideo(video)
        }

        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = playlist.sortedItems.enumerated().sorted { lhs, rhs in
            let l = lhs.element.isYouTubeVideo ? position[lhs.element.videoID] : nil
            let r = rhs.element.isYouTubeVideo ? position[rhs.element.videoID] : nil
            switch (l, r) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }
        for (index, entry) in reordered.enumerated() where entry.element.sortOrder != index {
            entry.element.sortOrder = index
        }

        playlist.updatedAt = Date()
        save()
        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
    }

    /// Deletes a mirrored playlist whose remote counterpart is gone.
    func deleteMirroredPlaylist(_ playlist: LocalPlaylist) {
        modelContext.delete(playlist)
        save()
        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
    }
}

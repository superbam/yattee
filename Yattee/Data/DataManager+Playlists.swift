//
//  DataManager+Playlists.swift
//  Yattee
//
//  Local playlist operations for DataManager.
//

import Foundation
import SwiftData

extension DataManager {
    // MARK: - Local Playlists

    /// Creates a new local playlist.
    /// - Parameter syncToInvidious: FORK (playlist-sync): when the Invidious
    ///   playlist sync is on, also create the playlist on the account. Pass
    ///   false for playlists that are copies of existing account playlists.
    func createPlaylist(title: String, description: String? = nil, syncToInvidious: Bool = true) -> LocalPlaylist {
        let playlist = LocalPlaylist(title: title, description: description)
        modelContext.insert(playlist)
        save()

        // FORK (playlist-sync): account-managed playlists skip CloudKit.
        let managedByAccount = syncToInvidious && (invidiousPlaylistSync?.registerNewLocalPlaylist(playlist) ?? false)
        if !managedByAccount {
            // Queue for CloudKit sync
            cloudKitSync?.queuePlaylistSave(playlist)
        }
        
        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
        return playlist
    }

    /// Updates a playlist's title and description.
    func updatePlaylist(_ playlist: LocalPlaylist, title: String, description: String?) {
        playlist.title = title
        playlist.playlistDescription = description
        playlist.updatedAt = Date()
        save()

        // Queue for CloudKit sync (FORK playlist-sync: account-managed playlists skip it)
        if invidiousPlaylistSync?.isLinked(playlist) == true {
            invidiousPlaylistSync?.localPlaylistChanged()
        } else {
            cloudKitSync?.queuePlaylistSave(playlist)
        }

        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
    }

    /// Deletes a local playlist.
    func deletePlaylist(_ playlist: LocalPlaylist) {
        let playlistID = playlist.id
        let itemIDs = playlist.sortedItems.map { $0.id }
        let managedByAccount = invidiousPlaylistSync?.isLinked(playlist) == true

        modelContext.delete(playlist)
        save()

        // FORK (playlist-sync): deleting an account-managed playlist deletes it on the account.
        if managedByAccount {
            invidiousPlaylistSync?.localPlaylistDeleted(id: playlistID)
        } else {
            // Queue playlist and all its items for CloudKit deletion
            cloudKitSync?.queuePlaylistDelete(playlistID: playlistID)
            for itemID in itemIDs {
                cloudKitSync?.queuePlaylistItemDelete(itemID: itemID)
            }
        }

        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
    }

    /// Gets all local playlists.
    func playlists() -> [LocalPlaylist] {
        let descriptor = FetchDescriptor<LocalPlaylist>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            LoggingService.shared.logCloudKitError("Failed to fetch playlists", error: error)
            return []
        }
    }
    
    /// Gets a playlist by its ID.
    func playlist(forID id: UUID) -> LocalPlaylist? {
        let descriptor = FetchDescriptor<LocalPlaylist>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    /// Gets a playlist item by its ID.
    func playlistItem(forID id: UUID) -> LocalPlaylistItem? {
        let descriptor = FetchDescriptor<LocalPlaylistItem>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
    
    /// Inserts a playlist into the database.
    /// Used by CloudKitSyncEngine for applying remote playlists.
    func insertPlaylist(_ playlist: LocalPlaylist) {
        // Check for duplicates
        let id = playlist.id
        let descriptor = FetchDescriptor<LocalPlaylist>(
            predicate: #Predicate { $0.id == id }
        )
        
        do {
            let existing = try modelContext.fetch(descriptor)
            if existing.isEmpty {
                modelContext.insert(playlist)
                save()
            }
        } catch {
            // Insert anyway if we can't check
            modelContext.insert(playlist)
            save()
        }
    }
    
    /// Inserts a playlist item into the database.
    /// Used by CloudKitSyncEngine for applying remote playlist items.
    func insertPlaylistItem(_ item: LocalPlaylistItem) {
        // Check for duplicates
        let id = item.id
        let descriptor = FetchDescriptor<LocalPlaylistItem>(
            predicate: #Predicate { $0.id == id }
        )
        
        do {
            let existing = try modelContext.fetch(descriptor)
            if existing.isEmpty {
                modelContext.insert(item)
                save()
            }
        } catch {
            // Insert anyway if we can't check
            modelContext.insert(item)
            save()
        }
    }
    
    /// Deletes a playlist item.
    /// Used by CloudKitSyncEngine for applying remote deletions.
    func deletePlaylistItem(_ item: LocalPlaylistItem) {
        modelContext.delete(item)
        save()
    }

    /// Adds a video to a playlist.
    func addToPlaylist(_ video: Video, playlist: LocalPlaylist) {
        guard !playlist.contains(videoID: video.id.videoID) else {
            return
        }
        playlist.addVideo(video)
        save()

        // Queue for CloudKit sync (will sync playlist and all items)
        // FORK (playlist-sync): account-managed playlists sync via Invidious instead.
        if invidiousPlaylistSync?.isLinked(playlist) == true {
            invidiousPlaylistSync?.localPlaylistChanged()
        } else {
            cloudKitSync?.queuePlaylistSave(playlist)
        }
        
        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
    }
    
    /// Removes a video from a playlist.
    func removeVideoFromPlaylist(at index: Int, playlist: LocalPlaylist) {
        guard index < playlist.sortedItems.count else { return }
        let item = playlist.sortedItems[index]
        let itemID = item.id
        
        // Remove from playlist
        playlist.removeVideo(at: index)
        save()
        
        // Queue updated playlist for CloudKit sync
        // FORK (playlist-sync): account-managed playlists sync via Invidious instead.
        if invidiousPlaylistSync?.isLinked(playlist) == true {
            modelContext.delete(item)
            save()
            invidiousPlaylistSync?.localPlaylistChanged()
        } else {
            cloudKitSync?.queuePlaylistSave(playlist)

            // Also delete the orphaned item from CloudKit
            cloudKitSync?.queuePlaylistItemDelete(itemID: itemID)
        }
        
        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
    }
}

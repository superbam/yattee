//
//  DataManager+InvidiousHistorySync.swift
//  Yattee
//
//  Fork addition (playback-sync): SwiftData side of Invidious account watch
//  sync. Kept in its own file so it doesn't conflict when merging upstream
//  changes to DataManager+WatchHistory.swift. See InvidiousHistorySyncService.
//

import Foundation
import SwiftData

extension DataManager {
    /// Marks existing watch entries as finished for the given video IDs.
    ///
    /// Used by Invidious account sync: the server only knows *which* videos are
    /// watched (no metadata), so this only upgrades rows that already exist
    /// locally — it never creates blank, metadata-less entries that would
    /// clutter the history UI. Saves once and notifies observers only if a row
    /// actually changed.
    func markFinishedFromSync(videoIDs: Set<String>) {
        guard !videoIDs.isEmpty else { return }
        let ids = Array(videoIDs)
        let descriptor = FetchDescriptor<WatchEntry>(
            predicate: #Predicate { ids.contains($0.videoID) }
        )

        do {
            let entries = try modelContext.fetch(descriptor)
            var changed = false
            for entry in entries where !entry.isFinished {
                entry.isFinished = true
                entry.finishedAt = Date()
                changed = true
            }
            if changed {
                save()
                NotificationCenter.default.post(name: .watchHistoryDidChange, object: nil)
            }
        } catch {
            LoggingService.shared.logCloudKitError("Failed to mark synced watched entries", error: error)
        }
    }

    /// Of the given video IDs, returns those that have *no* local WatchEntry.
    /// Used by Invidious account sync to decide which watched videos still need
    /// their metadata fetched and hydrated into full history rows.
    func videoIDsWithoutWatchEntry(among videoIDs: [String]) -> [String] {
        guard !videoIDs.isEmpty else { return [] }
        let ids = videoIDs
        let descriptor = FetchDescriptor<WatchEntry>(
            predicate: #Predicate { ids.contains($0.videoID) }
        )
        do {
            let existing = Set(try modelContext.fetch(descriptor).map(\.videoID))
            return videoIDs.filter { !existing.contains($0) }
        } catch {
            LoggingService.shared.logCloudKitError("Failed to fetch existing watch entries", error: error)
            return []
        }
    }

    /// Creates finished WatchEntry rows from metadata fetched for account-watched
    /// videos that had no local entry. Re-checks existence inside the write so a
    /// concurrent insert (e.g. the user opening one mid-sync) can't duplicate a
    /// row. Saves once and notifies observers only if something was added.
    func createFinishedEntriesFromSync(videos: [Video]) {
        guard !videos.isEmpty else { return }
        let ids = videos.map { $0.id.videoID }
        let descriptor = FetchDescriptor<WatchEntry>(
            predicate: #Predicate { ids.contains($0.videoID) }
        )
        let existing = (try? modelContext.fetch(descriptor)).map { Set($0.map(\.videoID)) } ?? []

        var changed = false
        for video in videos where !existing.contains(video.id.videoID) {
            let entry = WatchEntry.from(video: video)
            entry.markAsFinished()
            modelContext.insert(entry)
            changed = true
        }
        if changed {
            save()
            NotificationCenter.default.post(name: .watchHistoryDidChange, object: nil)
        }
    }
}

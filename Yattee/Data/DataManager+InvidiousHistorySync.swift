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
}

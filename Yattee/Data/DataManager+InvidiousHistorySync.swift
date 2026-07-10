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
    /// Fully mirrors local finished-state to the Invidious account's watched
    /// list: marks finished any video present in `watchedVideoIDs`, and
    /// unmarks any locally-finished video that's absent from it. Scoped to
    /// YouTube/global entries only (`sourceRawValue == "global"`,
    /// `globalProvider == "youtube"`) — the only content Invidious can have
    /// an opinion on — so PeerTube, local-folder, and extracted-URL entries
    /// are never touched. Doesn't create new rows for videos missing locally;
    /// see `createFinishedEntriesFromSync` for that. Saves once and notifies
    /// observers only if something actually changed.
    func reconcileFinishedFromSync(watchedVideoIDs: Set<String>) {
        let descriptor = FetchDescriptor<WatchEntry>(
            predicate: #Predicate { $0.sourceRawValue == "global" && $0.globalProvider == "youtube" }
        )

        do {
            let entries = try modelContext.fetch(descriptor)
            var changed = false
            for entry in entries {
                let shouldBeFinished = watchedVideoIDs.contains(entry.videoID)
                if shouldBeFinished, !entry.isFinished {
                    entry.isFinished = true
                    entry.finishedAt = Date()
                    changed = true
                } else if !shouldBeFinished, entry.isFinished {
                    entry.isFinished = false
                    entry.finishedAt = nil
                    changed = true
                }
            }
            if changed {
                save()
                NotificationCenter.default.post(name: .watchHistoryDidChange, object: nil)
            }
        } catch {
            LoggingService.shared.logCloudKitError("Failed to reconcile synced watched entries", error: error)
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

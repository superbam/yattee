//
//  DownloadManager+OfflineSponsorBlock.swift
//  Yattee
//
//  FORK (offline-sponsorblock): captures SponsorBlock segments at download time
//  so sponsor skipping works while offline.
//
//  All fork logic for this feature lives here. The only inline edits in upstream
//  files are: the `sponsorSegments` field on `Download`, the injected
//  `sponsorBlockAPI`/`sponsorBlockSettings` properties + setter on
//  `DownloadManager`, a single `captureSponsorSegments` call in
//  `completeMultiFileDownload` (DownloadManager+Execution), and the playback-time
//  load in `PlayerService.play()`. All are tagged `// FORK (offline-sponsorblock)`.
//

import Foundation

#if !os(tvOS)

extension DownloadManager {
    /// Fetches SponsorBlock segments for a video at download time so they can be
    /// persisted alongside the media and used for skipping while offline.
    ///
    /// Returns `nil` (rather than throwing) whenever segments can't or shouldn't
    /// be captured — SponsorBlock disabled, not a YouTube video, missing
    /// dependencies, or a network failure — so it never blocks or fails a
    /// download. All categories are fetched regardless of the user's current
    /// enabled set; the player filters by enabled categories at playback time,
    /// so changing category preferences later still works offline.
    func captureSponsorSegments(for videoID: VideoID) async -> [SponsorBlockSegment]? {
        guard let settings = sponsorBlockSettings, settings.sponsorBlockEnabled else { return nil }

        // SponsorBlock only has data for YouTube (global-source) videos.
        guard case .global = videoID.source else { return nil }

        guard let api = sponsorBlockAPI else { return nil }

        if let url = URL(string: settings.sponsorBlockAPIURL) {
            await api.setBaseURL(url)
        }

        do {
            let segments = try await api.segments(
                for: videoID.videoID,
                categories: Set(SponsorBlockCategory.allCases)
            )
            guard !segments.isEmpty else { return nil }
            LoggingService.shared.logDownload(
                "[Downloads] Captured \(segments.count) SponsorBlock segments for offline use",
                details: "video: \(videoID.id)"
            )
            return segments
        } catch {
            // Non-fatal: download proceeds without offline segments.
            LoggingService.shared.logDownloadError(
                "[Downloads] SponsorBlock capture failed (continuing without offline segments)",
                error: error
            )
            return nil
        }
    }

    /// Fetches SponsorBlock segments in the background and stores them on the
    /// completed download record, without delaying download completion. Called
    /// once a download finishes; does nothing if segments can't be captured or
    /// the record is gone (e.g. deleted before the fetch returned).
    func captureAndStoreSponsorSegments(for downloadID: UUID, videoID: VideoID) {
        Task { [weak self] in
            guard let self else { return }
            guard let segments = await self.captureSponsorSegments(for: videoID) else { return }
            guard let index = self.completedDownloads.firstIndex(where: { $0.id == downloadID }) else { return }
            self.completedDownloads[index].sponsorSegments = segments
            self.saveDownloads()
        }
    }
}

#endif

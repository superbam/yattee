//
//  DownloadManager+StreamRefresh.swift
//  Yattee
//
//  Refreshes expired stream URLs for queued, paused and in-flight downloads.
//

import Foundation

#if !os(tvOS)

extension DownloadManager {
    func setStreamRefreshDependencies(contentService: ContentService, instancesManager: InstancesManager) {
        streamRefreshContentService = contentService
        streamRefreshInstancesManager = instancesManager
    }

    /// Asks the instance for fresh stream URLs and swaps them into the download.
    ///
    /// Stored googlevideo links expire after a few hours, so a download that was queued,
    /// paused or failed earlier gets HTTP 403 when it is resumed. The same format and
    /// quality are looked up again so the download keeps the file type it was created with.
    /// - Returns: `true` if the download now has fresh URLs.
    @discardableResult
    func refreshStreamURLs(for downloadID: UUID) async -> Bool {
        guard let download = activeDownloads.first(where: { $0.id == downloadID }),
              let contentService = streamRefreshContentService,
              let instancesManager = streamRefreshInstancesManager,
              let instance = instancesManager.instance(for: download.videoID.source) else {
            return false
        }

        let streams: [Stream]
        do {
            if case .extracted(_, let originalURL) = download.videoID.source {
                streams = try await contentService.extractURL(originalURL, instance: instance).streams
            } else {
                streams = try await contentService.videoWithProxyStreamsAndCaptionsAndStoryboards(
                    id: download.videoID.videoID,
                    instance: instance
                ).streams
            }
        } catch {
            LoggingService.shared.logDownloadError(
                "[Downloads] Could not refresh stream URLs: \(download.videoID.id)",
                error: error
            )
            return false
        }

        let needsSeparateAudio = download.audioStreamURL != nil
        let videoCandidates = streams.filter { !$0.isAudioOnly && $0.isVideoOnly == needsSeparateAudio }
        guard let videoStream = videoCandidates.first(where: { $0.format == download.formatID && $0.qualityLabel == download.quality })
                ?? videoCandidates.first(where: { $0.qualityLabel == download.quality }) else {
            LoggingService.shared.logDownloadError(
                "[Downloads] No matching stream to refresh: \(download.videoID.id)",
                error: DownloadError.noStreamAvailable
            )
            return false
        }

        var audioURL: URL?
        if needsSeparateAudio {
            guard let audioStream = selectBestAudioStream(from: streams, preferredLanguage: download.audioLanguage) else {
                return false
            }
            audioURL = audioStream.url
        }

        // The download may have been cancelled or finished while the request was in flight.
        guard let index = activeDownloads.firstIndex(where: { $0.id == downloadID }) else {
            return false
        }
        activeDownloads[index].streamURL = videoStream.url
        activeDownloads[index].audioStreamURL = audioURL
        activeDownloads[index].httpHeaders = videoStream.httpHeaders
        saveDownloads()

        LoggingService.shared.logDownload(
            "[Downloads] Refreshed stream URLs: \(download.videoID.id)",
            details: "quality: \(download.quality), format: \(download.formatID)"
        )
        return true
    }

    /// Handles an expired-link response: fetches fresh URLs, then restarts the video and
    /// audio transfers once. The caller must already have inserted `downloadID` into
    /// `refreshingLinkDownloadIDs` so the errors from the other in-flight task are ignored.
    func refreshLinksAndRestart(downloadID: UUID) async {
        refreshedLinkDownloadIDs.insert(downloadID)
        LoggingService.shared.logDownload("[Downloads] Link rejected, refreshing stream URLs")

        let refreshed = await refreshStreamURLs(for: downloadID)
        refreshingLinkDownloadIDs.remove(downloadID)

        guard let index = activeDownloads.firstIndex(where: { $0.id == downloadID }),
              activeDownloads[index].status == .downloading else {
            return
        }

        videoTasks.removeValue(forKey: downloadID)?.cancel()
        audioTasks.removeValue(forKey: downloadID)?.cancel()

        guard refreshed else {
            failDownload(downloadID: downloadID, message: String(localized: "downloads.error.linkExpired"))
            return
        }

        activeDownloads[index].resumeData = nil
        activeDownloads[index].audioResumeData = nil
        activeDownloads[index].retryCount = 0
        saveDownloads()
        await startDownload(for: downloadID)
    }

    /// Marks a download failed and moves on to the next queued one.
    func failDownload(downloadID: UUID, message: String) {
        guard let index = activeDownloads.firstIndex(where: { $0.id == downloadID }) else { return }

        batchDownloadIDs.remove(downloadID)
        refreshedLinkDownloadIDs.remove(downloadID)
        videoTasks.removeValue(forKey: downloadID)?.cancel()
        audioTasks.removeValue(forKey: downloadID)?.cancel()
        captionTasks.removeValue(forKey: downloadID)?.cancel()

        activeDownloads[index].status = .failed
        activeDownloads[index].error = message
        LoggingService.shared.logDownloadError("Failed: \(activeDownloads[index].videoID.id) — \(message)")
        saveDownloads()
        notifyDownloadFinishedInBackground(title: activeDownloads[index].title, failed: true)

        Task { await startNextDownloadIfNeeded() }
    }
}

#endif

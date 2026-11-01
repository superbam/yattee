//
//  DownloadError.swift
//  Yattee
//
//  Error types for download operations.
//

import Foundation

enum DownloadError: LocalizedError {
    case notSupported
    case alreadyDownloading
    case alreadyDownloaded
    case noStreamAvailable
    case downloadFailed(String)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "Downloads are not supported on this platform."
        case .alreadyDownloading:
            return "This video is already downloading."
        case .alreadyDownloaded:
            return "This video has already been downloaded."
        case .noStreamAvailable:
            return "No downloadable stream available."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .httpStatus(let status):
            return "Download failed: Server returned HTTP \(status)"
        }
    }

    /// Whether the server rejected the stored link itself (expired or invalid
    /// signature), as opposed to a transient failure. Retrying the same URL can't succeed.
    var isExpiredLink: Bool {
        if case .httpStatus(let status) = self {
            return status == 403 || status == 404 || status == 410
        }
        return false
    }
}

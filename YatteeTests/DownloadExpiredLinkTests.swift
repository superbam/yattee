//
//  DownloadExpiredLinkTests.swift
//  YatteeTests
//

import Testing
@testable import Yattee

@Suite("DownloadError")
struct DownloadExpiredLinkTests {
    @Test("Link-rejection statuses are treated as expired links", arguments: [403, 404, 410])
    func expiredLinkStatuses(status: Int) {
        #expect(DownloadError.httpStatus(status).isExpiredLink)
    }

    @Test("Transient failures are not treated as expired links", arguments: [429, 500, 502, 503])
    func transientStatuses(status: Int) {
        #expect(!DownloadError.httpStatus(status).isExpiredLink)
    }

    @Test("Other errors are not expired links")
    func otherErrors() {
        #expect(!DownloadError.downloadFailed("timeout").isExpiredLink)
        #expect(!DownloadError.noStreamAvailable.isExpiredLink)
    }

    @Test("HTTP status keeps the message the UI already showed")
    func message() {
        #expect(DownloadError.httpStatus(403).errorDescription == "Download failed: Server returned HTTP 403")
    }
}

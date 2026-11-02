//
//  UnresolvableVideoTrackerTests.swift
//  YatteeTests
//
//  History sync should stop retrying videos that can never resolve, but keep retrying
//  anything that might just be a network or server hiccup.
//

import Foundation
import Testing
@testable import Yattee

@Suite("UnresolvableVideoTracker")
struct UnresolvableVideoTrackerTests {
    private func makeTracker(clock: @escaping () -> Date) -> UnresolvableVideoTracker {
        let suite = "UnresolvableVideoTrackerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return UnresolvableVideoTracker(defaults: defaults, key: "test", now: clock)
    }

    @Test("Deleted, private and gated videos are permanent failures")
    func permanentFailures() {
        #expect(UnresolvableVideoTracker.isPermanent(APIError.notFound(nil)))
        #expect(UnresolvableVideoTracker.isPermanent(APIError.httpError(statusCode: 404, message: nil)))
        #expect(UnresolvableVideoTracker.isPermanent(
            APIError.httpError(statusCode: 500, message: "Sign in if you've been granted access to this video")))
        #expect(UnresolvableVideoTracker.isPermanent(APIError.serverError("Video unavailable")))
    }

    @Test("Network and server hiccups are not permanent")
    func transientFailures() {
        #expect(!UnresolvableVideoTracker.isPermanent(APIError.timeout))
        #expect(!UnresolvableVideoTracker.isPermanent(APIError.noConnection))
        #expect(!UnresolvableVideoTracker.isPermanent(APIError.cancelled))
        #expect(!UnresolvableVideoTracker.isPermanent(APIError.httpError(statusCode: 500, message: "Internal Server Error")))
        #expect(!UnresolvableVideoTracker.isPermanent(APIError.httpError(statusCode: 502, message: nil)))
        #expect(!UnresolvableVideoTracker.isPermanent(APIError.rateLimited(retryAfter: nil)))
        #expect(!UnresolvableVideoTracker.isPermanent(URLError(.notConnectedToInternet)))
    }

    @Test("A recorded video is skipped, others are not")
    func skipsRecorded() {
        let tracker = makeTracker { Date() }
        tracker.record(["dead1234567"])
        #expect(tracker.shouldSkip("dead1234567"))
        #expect(!tracker.shouldSkip("other123456"))
    }

    @Test("A skipped video is tried again after a week")
    func retriesAfterAWeek() {
        var current = Date(timeIntervalSince1970: 1_000_000)
        let tracker = makeTracker { current }
        tracker.record(["dead1234567"])

        current = current.addingTimeInterval(UnresolvableVideoTracker.retryInterval - 60)
        #expect(tracker.shouldSkip("dead1234567"))

        current = current.addingTimeInterval(120)
        #expect(!tracker.shouldSkip("dead1234567"))
    }

    @Test("Recording nothing changes nothing")
    func emptyRecord() {
        let tracker = makeTracker { Date() }
        tracker.record([])
        #expect(!tracker.shouldSkip("anything1234"))
    }
}

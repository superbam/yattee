//
//  UnresolvableVideoTracker.swift
//  Yattee
//
//  Remembers videos the instance can never resolve (deleted, private, members-only) so
//  history sync stops asking about them on every sync.
//

import Foundation

struct UnresolvableVideoTracker {
    /// How long a video stays skipped before it is tried again (it may have been restored).
    static let retryInterval: TimeInterval = 7 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, key: String = "invidiousHistoryUnresolvableVideos", now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.key = key
        self.now = now
    }

    /// Whether this failure is permanent, as opposed to a network or server hiccup that a
    /// later sync could get past.
    static func isPermanent(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .notFound:
            return true
        case .httpError(let statusCode, let message):
            return statusCode == 404 || (statusCode == 500 && looksUnavailable(message))
        case .serverError(let message):
            return looksUnavailable(message)
        default:
            return false
        }
    }

    private static func looksUnavailable(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return ["sign in", "unavailable", "private", "members", "removed", "deleted", "not available", "age-restricted"]
            .contains { message.contains($0) }
    }

    func shouldSkip(_ videoID: String) -> Bool {
        guard let recorded = load()[videoID] else { return false }
        return now().timeIntervalSince1970 - recorded < Self.retryInterval
    }

    func record(_ videoIDs: [String]) {
        guard !videoIDs.isEmpty else { return }
        var entries = load()
        let stamp = now().timeIntervalSince1970
        for id in videoIDs { entries[id] = stamp }
        // Drop expired entries so the list can't grow without bound.
        entries = entries.filter { stamp - $0.value < Self.retryInterval }
        defaults.set(entries, forKey: key)
    }

    private func load() -> [String: TimeInterval] {
        defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
    }
}

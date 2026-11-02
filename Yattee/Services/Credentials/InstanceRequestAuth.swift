//
//  InstanceRequestAuth.swift
//  Yattee
//
//  Supplies the reverse-proxy Basic auth header for requests that don't go through an
//  API client (thumbnails, storyboards, captions). Only the hostname of an instance that
//  is currently reached through its external address is ever authorized, so the
//  credentials are never sent anywhere else.
//

import Foundation

final class InstanceRequestAuth: @unchecked Sendable {
    static let shared = InstanceRequestAuth()

    private let lock = NSLock()
    private var headersByHost: [String: String] = [:]

    private init() {}

    /// Replaces the full host → header table.
    func update(_ headersByHost: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        self.headersByHost = headersByHost
    }

    func authorizationHeader(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return headersByHost[host]
    }

    /// A request for `url` carrying the proxy credentials when its host needs them.
    func request(for url: URL) -> URLRequest {
        authorized(URLRequest(url: url))
    }

    func authorized(_ request: URLRequest) -> URLRequest {
        guard let url = request.url,
              request.value(forHTTPHeaderField: "Authorization") == nil,
              let header = authorizationHeader(for: url) else { return request }
        var request = request
        request.setValue(header, forHTTPHeaderField: "Authorization")
        return request
    }
}

//
//  SourceStatusRefresher.swift
//  Yattee
//
//  FORK (sources-status): live status probing for the sources list.
//  While SourcesListView is visible it periodically probes every enabled
//  source so online/offline/auth badges stay current when the list is left
//  open. Instance results are written through the existing (previously
//  unused) InstancesManager status plumbing; network file-source results
//  are tracked here.
//

import Foundation

/// Probes configured sources and keeps their displayed status fresh.
///
/// Driven by a `.task` on `SourcesListView`, so probing runs only while the
/// sources list is actually on screen and stops when it disappears.
@MainActor
@Observable
final class SourceStatusRefresher {
    // MARK: - Dependencies

    private let httpClient: HTTPClient
    private let httpClientFactory: HTTPClientFactory
    private let webDAVClient: WebDAVClient
    private let smbClient: SMBClient
    private weak var instancesManager: InstancesManager?
    private weak var mediaSourcesManager: MediaSourcesManager?
    private weak var basicAuthCredentialsManager: BasicAuthCredentialsManager?

    // MARK: - State

    /// Network file sources (WebDAV/SMB) that failed their last probe.
    private(set) var offlineFileSourceIDs: Set<UUID> = []
    private(set) var lastRefreshed: Date?
    private var isRefreshing = false
    /// True while a `runWhileVisible` loop is active (sources list on screen).
    private var isLoopActive = false

    /// Lazily created client that accepts self-signed certificates, shared
    /// across probes of instances with `allowInvalidCertificates` set.
    private var laxClient: HTTPClient?

    // MARK: - Tuning

    /// How often to re-probe while the sources list stays visible.
    static let refreshInterval: Duration = .seconds(30)
    /// Per-probe timeout — short so one dead server doesn't stall the sweep.
    private static let probeTimeout: TimeInterval = 10

    // MARK: - Initialization

    init(
        httpClient: HTTPClient,
        httpClientFactory: HTTPClientFactory,
        webDAVClient: WebDAVClient,
        smbClient: SMBClient,
        instancesManager: InstancesManager,
        mediaSourcesManager: MediaSourcesManager,
        basicAuthCredentialsManager: BasicAuthCredentialsManager
    ) {
        self.httpClient = httpClient
        self.httpClientFactory = httpClientFactory
        self.webDAVClient = webDAVClient
        self.smbClient = smbClient
        self.instancesManager = instancesManager
        self.mediaSourcesManager = mediaSourcesManager
        self.basicAuthCredentialsManager = basicAuthCredentialsManager

        // Re-probe immediately when a source is added or edited from the
        // open list, instead of waiting for the next 30s tick.
        NotificationCenter.default.addObserver(
            forName: .instancesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isLoopActive else { return }
                await self.refreshAll()
            }
        }
    }

    // MARK: - Refresh Loop

    /// Probes immediately, then keeps re-probing until the surrounding
    /// `.task` is cancelled (i.e. the sources list disappears).
    func runWhileVisible() async {
        isLoopActive = true
        defer { isLoopActive = false }
        while !Task.isCancelled {
            await refreshAll()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// One full sweep over all enabled sources, probed concurrently.
    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let instances = instancesManager?.enabledInstances ?? []
        let fileSources = (mediaSourcesManager?.networkSources ?? []).filter(\.isEnabled)
        guard !instances.isEmpty || !fileSources.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for instance in instances {
                group.addTask { await self.probe(instance) }
            }
            for source in fileSources {
                group.addTask { await self.probe(source) }
            }
        }
        lastRefreshed = Date()
    }

    // MARK: - Instance Probing

    private func probe(_ instance: Instance) async {
        var headers: [String: String]?
        if let auth = basicAuthCredentialsManager?.basicAuthHeader(for: instance) {
            headers = ["Authorization": auth]
        }
        let endpoint = GenericEndpoint(
            path: Self.probePath(for: instance.type),
            headers: headers,
            timeout: Self.probeTimeout
        )

        do {
            let data = try await client(for: instance).fetchData(endpoint, baseURL: instance.url)
            instancesManager?.clearStatus(for: instance)
            if instance.type == .invidious {
                refreshForkDetection(for: instance, statsData: data)
            }
        } catch APIError.unauthorized {
            let hasCredentials = basicAuthCredentialsManager?.hasCredentials(for: instance) ?? false
            instancesManager?.updateStatus(hasCredentials ? .authFailed : .authRequired, for: instance)
        } catch {
            // Maps timeouts/no-connection/URL errors to .offline and ignores
            // HTTP-level errors (the server responded, so it's reachable).
            instancesManager?.updateStatusFromError(error, for: instance)
        }
    }

    /// Keeps `Instance.isShortsFilterFork` current from the `/api/v1/stats`
    /// body already fetched for the reachability probe — no extra request.
    /// (playback-sync)
    private func refreshForkDetection(for instance: Instance, statsData: Data) {
        guard let stats = try? JSONDecoder().decode(InstanceDetectorModels.InvidiousStats.self, from: statsData) else { return }
        let isFork = stats.software?.branch == "shorts-filter"
        guard instance.isShortsFilterFork != isFork else { return }
        var updated = instance
        updated.isShortsFilterFork = isFork
        instancesManager?.update(updated)
    }

    /// Cheapest known always-available endpoint per backend type.
    private static func probePath(for type: InstanceType) -> String {
        switch type {
        case .invidious: return "/api/v1/stats"
        case .piped: return "/healthcheck"
        case .peertube: return "/api/v1/config"
        case .yatteeServer: return "/info"
        }
    }

    private func client(for instance: Instance) -> HTTPClient {
        guard instance.allowInvalidCertificates else { return httpClient }
        if let laxClient { return laxClient }
        let created = httpClientFactory.createClient(allowInvalidCertificates: true)
        laxClient = created
        return created
    }

    // MARK: - File Source Probing

    private func probe(_ source: MediaSource) async {
        guard let mediaSourcesManager else { return }

        // A missing password already shows its own badge; probing would just
        // fail with an auth error and mislabel the source as offline.
        guard !mediaSourcesManager.needsPassword(for: source) else {
            offlineFileSourceIDs.remove(source.id)
            return
        }

        let password = mediaSourcesManager.password(for: source)
        do {
            switch source.type {
            case .webdav:
                _ = try await webDAVClient.testConnection(source: source, password: password)
            case .smb:
                _ = try await smbClient.testConnection(source: source, password: password)
            case .localFolder:
                return
            }
            offlineFileSourceIDs.remove(source.id)
        } catch {
            offlineFileSourceIDs.insert(source.id)
        }
    }
}

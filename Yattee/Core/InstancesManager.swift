//
//  InstancesManager.swift
//  Yattee
//
//  Manages configured backend instances with iCloud sync.
//

import Foundation
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import SwiftUI

/// Status of an instance's connectivity and authentication.
enum InstanceStatus: Equatable {
    /// Instance is online and working.
    case online
    /// Instance is offline or unreachable.
    case offline
    /// Instance requires authentication but credentials are not provided.
    case authRequired
    /// Instance authentication failed (wrong credentials).
    case authFailed
}

/// Manages the list of configured backend instances with iCloud sync.
@MainActor
@Observable
final class InstancesManager {
    // MARK: - Storage

    private let localDefaults = UserDefaults.standard
    private let ubiquitousStore = NSUbiquitousKeyValueStore.default
    private let instancesKey = "configuredInstances"
    private let activeInstanceKey = "activeInstanceID"
    private let externalAddressKey = "externalAddressInstanceIDs"

    // MARK: - Address Selection State

    private var pathMonitor: NWPathMonitor?
    private var addressRefreshTask: Task<Void, Never>?
    private var pendingScheduledRefresh = false

    // MARK: - Dependencies

    private weak var settingsManager: SettingsManager?

    // MARK: - State

    /// The configured instances exactly as stored and synced to iCloud (home address in `url`).
    private var storedInstances: [Instance] = []

    /// IDs of instances currently reached through their external address. Device-local:
    /// whether the home network is reachable depends on where this device is right now.
    private(set) var externalAddressInstanceIDs: Set<UUID> = []

    /// The instances as the rest of the app should use them: for any instance whose home
    /// address is unreachable, `url` is swapped to its external address. Identity (`id`)
    /// is unchanged, so logins, feeds and sync state are shared between both addresses.
    var instances: [Instance] {
        storedInstances.map(resolved)
    }

    private(set) var activeInstanceID: UUID?

    /// Current status of each instance, keyed by instance ID.
    private(set) var instanceStatuses: [UUID: InstanceStatus] = [:]

    /// IDs of Invidious instances currently reporting degraded YouTube access
    /// (fork-only `/api/v1/health`). Kept separate from `instanceStatuses`
    /// since an instance can be reachable (`.online`) while YouTube access
    /// through it is degraded — these are orthogonal, not mutually exclusive.
    private(set) var youtubeAccessDegradedInstanceIDs: Set<UUID> = []

    // MARK: - Initialization

    init(settingsManager: SettingsManager? = nil) {
        self.settingsManager = settingsManager

        loadInstances()
        loadActiveInstance()
        loadExternalAddressSelection()

        // Listen for external changes from iCloud
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleiCloudChange()
            }
        }
    }

    /// Starts watching for the network changing so the home/external choice stays current.
    /// Called once the app environment has finished wiring everything up.
    func startAddressMonitoring() {
        guard pathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleAddressRefresh(afterSeconds: 1)
            }
        }
        monitor.start(queue: DispatchQueue(label: "stream.yattee.instances.path"))
        pathMonitor = monitor

        #if canImport(UIKit)
        let foreground = UIApplication.willEnterForegroundNotification
        #else
        let foreground = NSApplication.didBecomeActiveNotification
        #endif
        NotificationCenter.default.addObserver(forName: foreground, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAddressSelection()
            }
        }

        refreshAddressSelection()
    }

    /// Sets the settings manager reference for checking iCloud sync status.
    func setSettingsManager(_ manager: SettingsManager) {
        self.settingsManager = manager
    }

    /// Whether iCloud sync is currently enabled.
    private var iCloudSyncEnabled: Bool {
        settingsManager?.iCloudSyncEnabled ?? false
    }

    /// Whether instance sync is enabled (requires both master toggle and category toggle).
    private var instanceSyncEnabled: Bool {
        iCloudSyncEnabled && (settingsManager?.syncInstances ?? true)
    }

    /// Handles external iCloud changes by replacing local data with iCloud data.
    private func handleiCloudChange() {
        // Only process iCloud changes if instance sync is enabled
        guard instanceSyncEnabled else { return }

        guard let iCloudData = ubiquitousStore.data(forKey: instancesKey),
              let iCloudInstances = try? JSONDecoder().decode([Instance].self, from: iCloudData) else {
            return
        }

        // Replace local instances with iCloud data, but keep each instance's
        // own locally-detected fork status rather than taking whatever another
        // device last pushed.
        storedInstances = preservingLocallyDetectedForkStatus(in: iCloudInstances)
        // Save to local defaults for offline access
        localDefaults.set(iCloudData, forKey: instancesKey)

        // Update sync time
        settingsManager?.updateLastSyncTime()
    }

    /// `isShortsFilterFork` is probed independently by every device (see
    /// `Instance.isShortsFilterFork`'s "self-heals" doc) rather than being
    /// user configuration — it shouldn't travel through iCloud sync at all.
    /// Without this, two devices whose probes land at different times (e.g.
    /// one hasn't detected the fork yet, or its probe failed) keep echoing
    /// their own `isShortsFilterFork` back and forth through iCloud, forever
    /// stomping the other's confirmed value and permanently hiding Discover
    /// even though the instance really is a fork and the user really is
    /// logged in. Only bootstraps from iCloud when this device has no
    /// determination of its own yet (a fresh install, before its first probe).
    private func preservingLocallyDetectedForkStatus(in incoming: [Instance]) -> [Instance] {
        let localByID = Dictionary(uniqueKeysWithValues: storedInstances.map { ($0.id, $0) })
        return incoming.map { instance in
            guard let local = localByID[instance.id] else { return instance }
            var merged = instance
            merged.isShortsFilterFork = local.isShortsFilterFork ?? instance.isShortsFilterFork
            return merged
        }
    }

    /// Syncs local data to iCloud (called when enabling iCloud sync).
    /// Only syncs if instance sync is enabled.
    func syncToiCloud() {
        guard instanceSyncEnabled else { return }

        guard let data = try? JSONEncoder().encode(storedInstances) else { return }
        ubiquitousStore.set(data, forKey: instancesKey)
        ubiquitousStore.synchronize()
        settingsManager?.updateLastSyncTime()
    }

    /// Replaces local data with iCloud data (called when enabling iCloud sync).
    /// Only replaces if instance sync is enabled.
    func replaceWithiCloudData() {
        guard instanceSyncEnabled else { return }

        ubiquitousStore.synchronize()

        guard let iCloudData = ubiquitousStore.data(forKey: instancesKey),
              let iCloudInstances = try? JSONDecoder().decode([Instance].self, from: iCloudData) else {
            // No iCloud data exists, sync local data to iCloud
            syncToiCloud()
            return
        }

        // Replace local with iCloud data
        storedInstances = preservingLocallyDetectedForkStatus(in: iCloudInstances)
        localDefaults.set(iCloudData, forKey: instancesKey)
        settingsManager?.updateLastSyncTime()
    }

    // MARK: - Public Methods

    func add(_ instance: Instance) {
        storedInstances.append(instance)
        saveInstances()
        refreshAddressSelection()
    }

    func remove(_ instance: Instance) {
        storedInstances.removeAll { $0.id == instance.id }
        externalAddressInstanceIDs.remove(instance.id)

        // Clear active instance if it was the removed one
        if activeInstanceID == instance.id {
            activeInstanceID = nil
            localDefaults.removeObject(forKey: activeInstanceKey)
        }

        saveInstances()
    }

    func update(_ instance: Instance) {
        if let index = storedInstances.firstIndex(where: { $0.id == instance.id }) {
            var updated = instance
            // Callers usually edit a copy from `instances`, whose `url` may be the external
            // address. Don't let that overwrite the configured home address.
            if resolved(storedInstances[index]).url == instance.url {
                updated.url = storedInstances[index].url
            }
            storedInstances[index] = updated
            saveInstances()
            refreshAddressSelection()
        }
    }

    /// The instance exactly as configured (home address in `url`), for editing.
    func storedInstance(id: UUID) -> Instance? {
        storedInstances.first { $0.id == id }
    }

    /// Alias for add method to maintain consistency.
    func addInstance(_ instance: Instance) {
        add(instance)
    }

    /// Toggles the enabled state of an instance.
    func toggleEnabled(_ instance: Instance) {
        if let index = storedInstances.firstIndex(where: { $0.id == instance.id }) {
            var updated = storedInstances[index]
            updated.isEnabled.toggle()
            storedInstances[index] = updated
            saveInstances()
        }
    }

    /// Records whether an instance sits behind HTTP Basic Auth.
    /// Persisted (and synced to iCloud) so missing Keychain credentials can be
    /// detected after a reinstall.
    func setUsesBasicAuth(_ value: Bool, for instance: Instance) {
        guard let index = storedInstances.firstIndex(where: { $0.id == instance.id }),
              storedInstances[index].usesBasicAuth != value else { return }
        storedInstances[index].usesBasicAuth = value
        saveInstances()
    }

    /// Records whether the user has logged into an account on an instance.
    /// Persisted (and synced to iCloud) so missing Keychain credentials can be
    /// detected after a reinstall.
    func setUsesAccountLogin(_ value: Bool, for instance: Instance) {
        guard let index = storedInstances.firstIndex(where: { $0.id == instance.id }),
              storedInstances[index].usesAccountLogin != value else { return }
        storedInstances[index].usesAccountLogin = value
        saveInstances()
    }

    /// Sets the given instance as the primary (first) instance.
    func setPrimary(_ instance: Instance) {
        LoggingService.shared.debug("[InstancesManager] setPrimary called for: \(instance.displayName)", category: .general)
        LoggingService.shared.debug("[InstancesManager] Current instances: \(instances.map { $0.displayName })", category: .general)

        guard let index = storedInstances.firstIndex(where: { $0.id == instance.id }) else {
            LoggingService.shared.debug("[InstancesManager] Instance not found in list", category: .general)
            return
        }

        if index == 0 {
            LoggingService.shared.debug("[InstancesManager] Instance already at index 0, skipping", category: .general)
            return
        }

        LoggingService.shared.debug("[InstancesManager] Moving instance from index \(index) to 0", category: .general)
        // Move to front
        let removed = storedInstances.remove(at: index)
        storedInstances.insert(removed, at: 0)
        saveInstances()
        LoggingService.shared.debug("[InstancesManager] After move: \(instances.map { $0.displayName })", category: .general)
    }

    // MARK: - Computed Properties

    var enabledInstances: [Instance] {
        instances.filter(\.isEnabled)
    }

    var youtubeInstances: [Instance] {
        instances.filter(\.isYouTubeInstance)
    }

    var peertubeInstances: [Instance] {
        instances.filter(\.isPeerTubeInstance)
    }

    var yatteeServerInstances: [Instance] {
        instances.filter(\.isYatteeServerInstance)
    }

    var hasYouTubeInstances: Bool {
        instances.contains { $0.isYouTubeInstance }
    }

    var hasPeerTubeInstances: Bool {
        instances.contains { $0.isPeerTubeInstance }
    }

    var hasYatteeServerInstances: Bool {
        instances.contains { $0.isYatteeServerInstance }
    }

    var invidiousPipedInstances: [Instance] {
        instances.filter { $0.type == .invidious || $0.type == .piped }
    }

    var hasInvidiousPipedInstances: Bool {
        instances.contains { $0.type == .invidious || $0.type == .piped }
    }

    var enabledYatteeServerInstances: [Instance] {
        yatteeServerInstances.filter(\.isEnabled)
    }

    /// Selects an enabled instance appropriate for the given video's content source.
    /// - For PeerTube videos: prefers the exact instance, falls back to any PeerTube instance
    /// - For YouTube/extracted content: uses YouTube-capable instance (Invidious, Piped, Yattee Server)
    func instance(for video: Video) -> Instance? {
        instance(for: video.id.source)
    }

    /// Selects an enabled instance appropriate for the given content source.
    /// - For PeerTube content: prefers the exact instance, falls back to any PeerTube instance
    /// - For extracted content: requires Yattee Server (only backend with yt-dlp)
    /// - For YouTube content: uses YouTube-capable instance (Invidious, Piped, Yattee Server)
    func instance(for contentSource: ContentSource) -> Instance? {
        switch contentSource {
        case .federated(let provider, let instanceURL) where provider == ContentSource.peertubeProvider:
            // PeerTube content - prefer the exact instance, fall back to any PeerTube instance
            return enabledInstances.first { $0.url.host == instanceURL.host }
                ?? enabledInstances.first(where: \.isPeerTubeInstance)
        case .extracted:
            // Extracted content requires Yattee Server (yt-dlp)
            return yatteeServerInstances.first
        case .global, .federated:
            // YouTube content - prefer Yattee Server, fall back to other YouTube-capable instances
            return enabledYatteeServerInstances.first
                ?? enabledInstances.first(where: \.isYouTubeInstance)
        }
    }

    /// Disables all Yattee Server instances except the specified one.
    func disableOtherYatteeServerInstances(except instanceID: UUID) {
        for instance in enabledYatteeServerInstances where instance.id != instanceID {
            var updated = instance
            updated.isEnabled = false
            update(updated)
        }
    }

    // MARK: - Instance Status

    /// Returns the current status of an instance.
    func status(for instance: Instance) -> InstanceStatus {
        instanceStatuses[instance.id] ?? .online
    }

    /// Updates the status of an instance.
    func updateStatus(_ status: InstanceStatus, for instance: Instance) {
        instanceStatuses[instance.id] = status
    }

    /// Updates status based on an API error.
    func updateStatusFromError(_ error: Error, for instance: Instance) {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                updateStatus(.authFailed, for: instance)
            case .noConnection, .timeout:
                updateStatus(.offline, for: instance)
                if instance.externalURL != nil { scheduleAddressRefresh(afterSeconds: 1) }
            default:
                // Don't change status for other errors
                break
            }
        } else {
            // Generic network errors
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                updateStatus(.offline, for: instance)
                if instance.externalURL != nil { scheduleAddressRefresh(afterSeconds: 1) }
            }
        }
    }

    /// Clears the status of an instance (resets to online).
    func clearStatus(for instance: Instance) {
        instanceStatuses.removeValue(forKey: instance.id)
    }

    /// Returns whether an instance is currently reporting degraded YouTube access.
    func youtubeAccessDegraded(for instance: Instance) -> Bool {
        youtubeAccessDegradedInstanceIDs.contains(instance.id)
    }

    /// Records the latest YouTube-access health for an instance.
    func setYouTubeAccessDegraded(_ degraded: Bool, for instance: Instance) {
        if degraded {
            youtubeAccessDegradedInstanceIDs.insert(instance.id)
        } else {
            youtubeAccessDegradedInstanceIDs.remove(instance.id)
        }
    }

    /// Instances that have auth issues (need attention).
    var instancesWithAuthIssues: [Instance] {
        instances.filter { instanceStatuses[$0.id] == .authFailed || instanceStatuses[$0.id] == .authRequired }
    }

    /// The currently active instance for browsing content.
    /// Falls back to the first enabled instance if no active instance is set.
    var activeInstance: Instance? {
        if let id = activeInstanceID,
           let instance = enabledInstances.first(where: { $0.id == id }) {
            return instance
        }
        return enabledInstances.first
    }

    /// Sets the given instance as the active instance for browsing.
    func setActive(_ instance: Instance) {
        guard enabledInstances.contains(where: { $0.id == instance.id }) else { return }
        activeInstanceID = instance.id
        saveActiveInstance()
        NotificationCenter.default.post(name: .activeInstanceDidChange, object: nil)
    }

    /// Clears the active instance, falling back to the first enabled instance.
    func clearActiveInstance() {
        activeInstanceID = nil
        localDefaults.removeObject(forKey: activeInstanceKey)
        NotificationCenter.default.post(name: .activeInstanceDidChange, object: nil)
    }

    // MARK: - Address Selection

    /// The instance as the app should use it right now (see `instances`).
    private func resolved(_ instance: Instance) -> Instance {
        guard externalAddressInstanceIDs.contains(instance.id),
              let external = instance.externalURL else { return instance }
        return instance.withURL(external)
    }

    private func loadExternalAddressSelection() {
        let strings = localDefaults.stringArray(forKey: externalAddressKey) ?? []
        externalAddressInstanceIDs = Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private func saveExternalAddressSelection() {
        localDefaults.set(externalAddressInstanceIDs.map(\.uuidString), forKey: externalAddressKey)
    }

    /// Re-checks right away which address each dual-address instance should use.
    func refreshAddressSelection() {
        addressRefreshTask?.cancel()
        addressRefreshTask = Task { [weak self] in
            await self?.performAddressSelection()
        }
    }

    /// Debounced variant for noisy triggers (network changes, repeated request errors).
    private func scheduleAddressRefresh(afterSeconds delay: Double) {
        guard !pendingScheduledRefresh else { return }
        pendingScheduledRefresh = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.pendingScheduledRefresh = false
            self.refreshAddressSelection()
        }
    }

    private func performAddressSelection() async {
        let candidates = storedInstances.filter { $0.externalURL != nil && $0.isEnabled }
        var active = externalAddressInstanceIDs.intersection(Set(storedInstances.compactMap { $0.externalURL != nil ? $0.id : nil }))

        for instance in candidates {
            let wasExternal = active.contains(instance.id)
            var homeReachable = await Self.isReachable(instance.url, type: instance.type)
            // A single failed probe on a good connection shouldn't flip the address.
            if !homeReachable, !wasExternal {
                try? await Task.sleep(for: .seconds(1))
                homeReachable = await Self.isReachable(instance.url, type: instance.type)
            }
            if Task.isCancelled { return }
            if homeReachable { active.remove(instance.id) } else { active.insert(instance.id) }
        }

        guard active != externalAddressInstanceIDs else { return }

        externalAddressInstanceIDs = active
        saveExternalAddressSelection()
        LoggingService.shared.info(
            "Instance addresses changed: \(active.count) using external address",
            category: .general
        )
        NotificationCenter.default.post(name: .instancesDidChange, object: nil)
        NotificationCenter.default.post(name: .activeInstanceDidChange, object: nil)
    }

    /// Whether the home address answers as the real server (not just any device that
    /// happens to share the address on another network).
    nonisolated private static func isReachable(_ url: URL, type: InstanceType) async -> Bool {
        let path = type == .invidious ? "/api/v1/stats" : (type == .piped ? "/healthcheck" : "")
        guard let probeURL = URL(string: path, relativeTo: url)?.absoluteURL else { return false }

        var request = URLRequest(url: probeURL)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            switch type {
            case .invidious, .piped: return http.statusCode == 200 || http.statusCode == 401
            default: return true
            }
        } catch {
            return false
        }
    }

    // MARK: - Private Methods

    private func loadInstances() {
        // Only load from local defaults - never automatically pull from iCloud
        // User must explicitly enable iCloud sync to get iCloud data
        if let data = localDefaults.data(forKey: instancesKey),
           let decoded = try? JSONDecoder().decode([Instance].self, from: data) {
            storedInstances = decoded
        }
    }

    private func saveInstances() {
        guard let data = try? JSONEncoder().encode(storedInstances) else { return }

        // Always write to local storage
        localDefaults.set(data, forKey: instancesKey)

        // Only write to iCloud if instance sync is enabled
        if instanceSyncEnabled {
            ubiquitousStore.set(data, forKey: instancesKey)
            settingsManager?.updateLastSyncTime()
        }

        NotificationCenter.default.post(name: .instancesDidChange, object: nil)
    }

    private func loadActiveInstance() {
        if let idString = localDefaults.string(forKey: activeInstanceKey),
           let uuid = UUID(uuidString: idString) {
            activeInstanceID = uuid
        }
    }

    private func saveActiveInstance() {
        if let id = activeInstanceID {
            localDefaults.set(id.uuidString, forKey: activeInstanceKey)
        } else {
            localDefaults.removeObject(forKey: activeInstanceKey)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let instancesDidChange = Notification.Name("stream.yattee.instancesDidChange")
    static let activeInstanceDidChange = Notification.Name("stream.yattee.activeInstanceDidChange")
}

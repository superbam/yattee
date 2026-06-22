//
//  SettingsManager+ShortsSync.swift
//  Yattee
//
//  Fork additions: settings for Shorts filtering (shorts-filter) and Invidious
//  account watch sync (playback-sync). Kept in their own file so they don't
//  conflict when merging upstream changes to SettingsManager+General.swift.
//  The backing `_hideShorts` / `_syncWatchHistoryWithInvidiousAccount` storage
//  lives in SettingsManager.swift (stored properties can't go in extensions).
//

import Foundation

extension SettingsManager {
    /// Whether to hide Shorts from feeds, search, and channel video lists.
    /// Detection prefers the backend's authoritative `isShort` flag, falling
    /// back to a length heuristic. Stored locally (not iCloud-synced). Default false.
    var hideShorts: Bool {
        get {
            if let cached = _hideShorts { return cached }
            let value = localDefaults.bool(forKey: "hideShorts")
            _hideShorts = value
            return value
        }
        set {
            _hideShorts = newValue
            localDefaults.set(newValue, forKey: "hideShorts")
        }
    }

    /// Whether to sync watch history and playback position with the signed-in
    /// Invidious account (requires the shorts-filter fork's positions endpoint).
    /// Synced across devices via iCloud (when settings sync is enabled), so
    /// enabling it once follows the account. The instance sign-in (SID) is still
    /// per device unless carried by iCloud Keychain. Default false. The backing
    /// `_syncWatchHistoryWithInvidiousAccount` storage lives in SettingsManager.
    var syncWatchHistoryWithInvidiousAccount: Bool {
        get {
            if let cached = _syncWatchHistoryWithInvidiousAccount { return cached }
            let value = bool(for: .syncWatchHistoryWithInvidiousAccount, default: false)
            _syncWatchHistoryWithInvidiousAccount = value
            return value
        }
        set {
            _syncWatchHistoryWithInvidiousAccount = newValue
            set(newValue, for: .syncWatchHistoryWithInvidiousAccount)
        }
    }

    /// Whether the iOS OS-level background refresh task should be scheduled.
    /// True when video notifications need it, OR when Invidious history sync is
    /// on — so playback sync keeps running in the background even if the user
    /// has notifications disabled. (playback-sync)
    var backgroundRefreshShouldBeScheduled: Bool {
        backgroundNotificationsEnabled || (saveWatchHistory && syncWatchHistoryWithInvidiousAccount)
    }
}

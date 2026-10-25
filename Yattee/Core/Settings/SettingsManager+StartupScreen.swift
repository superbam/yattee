//
//  SettingsManager+StartupScreen.swift
//  Yattee
//
//  Startup-screen picker support for tvOS (startup-screen).
//
//  The sidebar's startup tab only accepts items that are visible in the
//  sidebar, and Feed / Discover are hidden by default, so they could never be
//  chosen. This offers them too and makes the chosen item visible.
//

import Foundation

extension SettingsManager {
    /// Items offered as the startup screen: everything visible in the sidebar
    /// plus Subscriptions, Feed and Discover (shown on demand).
    func startupScreenChoices() -> [SidebarMainItem] {
        let alwaysOffered: [SidebarMainItem] = [.subscriptions, .feed, .discover]
        let excluded: Set<SidebarMainItem> = [.settings, .openURL, .remoteControl]
        let candidates = Set(visibleSidebarMainItems()).union(alwaysOffered).subtracting(excluded)
        return sidebarMainItemOrder.filter { candidates.contains($0) && $0.isAvailableOnCurrentPlatform }
    }

    /// Sets the startup screen, revealing the item in the sidebar first when it
    /// is hidden so the startup screen can't silently fall back to Home.
    func chooseStartupScreen(_ item: SidebarMainItem) {
        var visibility = sidebarMainItemVisibility
        if !(item.isRequired || (visibility[item] ?? true)) {
            visibility[item] = true
            sidebarMainItemVisibility = visibility
        }
        sidebarStartupTab = item
    }
}

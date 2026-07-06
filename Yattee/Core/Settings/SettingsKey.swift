//
//  SettingsKey.swift
//  Yattee
//
//  Keys used for storing settings in UserDefaults and iCloud.
//

import Foundation

/// Keys for storing settings values.
/// Used internally by SettingsManager for persistence.
enum SettingsKey: String, CaseIterable {
    // General
    case theme
    case accentColor
    case showWatchedCheckmark

    // Playback
    case preferredQuality
    case cellularQuality
    case autoplay
    case backgroundPlayback
    case dashEnabled
    case preferredAudioLanguage
    case preferredSubtitlesLanguage
    case resumeAction
    case tvOSMenuButtonClosesVideo
    case allowSoftwareDecodedFormats

    // SponsorBlock
    case sponsorBlockEnabled
    case sponsorBlockCategories
    case sponsorBlockAPIURL

    // Return YouTube Dislike
    case returnYouTubeDislikeEnabled

    // DeArrow
    case deArrowEnabled
    case deArrowReplaceTitles
    case deArrowReplaceThumbnails
    case deArrowAPIURL
    case deArrowThumbnailAPIURL

    // Short link resolution
    case resolveShortLinksEnabled

    // Platform-specific
    case macPlayerMode
    case playerSheetAutoResize
    case listStyle

    // Feed
    case feedCacheValidityMinutes

    // Player
    case keepPlayerPinned
    case hapticFeedbackEnabled
    case hapticFeedbackIntensity
    case inAppOrientationLock
    case rotateToMatchAspectRatio
    case preferPortraitBrowsing

    // Home
    case homeShortcutOrder
    case homeShortcutVisibility
    case homeShortcutLayout
    case homeSectionOrder
    case homeSectionVisibility
    case homeSectionItemsLimit
    case homeSectionLayout

    // Top Shelf (tvOS)
    case topShelfSections

    // Tab Bar (compact size class)
    case tabBarItemOrder
    case tabBarItemVisibility
    case tabBarStartupTab

    // Sidebar
    case sidebarMainItemOrder
    case sidebarMainItemVisibility
    case sidebarStartupTab

    // tvOS: dedicated shortcut for making Subscriptions the launch tab.
    // Not local-only, so the toggle itself follows the account via iCloud;
    // the remembered prior startup tab is local-only bookkeeping for undo.
    case tvOSOpenToSubscriptionsAtLaunch
    case tvOSStartupTabBeforeSubscriptionsDefault
    case sidebarSourcesEnabled
    case sidebarSourceSort
    case sidebarSourcesLimitEnabled
    case sidebarMaxSources
    case sidebarChannelsEnabled
    case sidebarMaxChannels
    case sidebarChannelSort
    case sidebarChannelsLimitEnabled
    case sidebarPlaylistsEnabled
    case sidebarMaxPlaylists
    case sidebarPlaylistSort
    case sidebarPlaylistsLimitEnabled

    // Remote Control
    case remoteControlCustomDeviceName
    case remoteControlHideWhenBackgrounded

    // Advanced
    case showAdvancedStreamDetails
    case showPlayerAreaDebug
    case showTVDebugButton
    case verboseMPVLogging
    case verboseRemoteControlLogging
    case mpvBufferSeconds
    case mpvUseEDLStreams
    case zoomTransitionsEnabled
    case tvMatchDisplayFrameRate
    case tvMatchDisplayDynamicRange

    // Details panel
    case floatingDetailsPanelSide // Landscape only - which side the panel appears on
    case floatingDetailsPanelWidth // Resizable panel width in wide layout
    case landscapeDetailsPanelVisible
    case landscapeDetailsPanelPinned

    // Player Controls
    case activeControlsPresetID

    // Video Swipe Actions
    case videoSwipeActionOrder
    case videoSwipeActionVisibility

    // Onboarding
    case onboardingCompleted

    // FORK (playback-sync): Invidious account watch-history / position sync
    // toggle. Not platform-specific and not local-only, so it syncs across
    // devices via iCloud and enabling it once follows the account.
    case syncWatchHistoryWithInvidiousAccount
    // FORK (playback-sync): percentage of a video that must be watched before
    // it's marked watched on the Invidious account. Follows the same sync
    // rules as the toggle above.
    case invidiousMarkWatchedThresholdPercent

    /// Whether this key should have platform-specific prefixes.
    /// Platform-specific keys are stored under a `iOS.` / `macOS.` / `tvOS.` prefix
    /// in both UserDefaults and iCloud, so each platform family syncs independently.
    var isPlatformSpecific: Bool {
        switch self {
        case .preferredQuality, .cellularQuality, .allowSoftwareDecodedFormats, .macPlayerMode, .listStyle,
             // Home layout — different UI paradigms per platform
             .homeShortcutOrder, .homeShortcutVisibility, .homeShortcutLayout,
             .homeSectionOrder, .homeSectionVisibility, .homeSectionItemsLimit, .homeSectionLayout,
             // Top Shelf — tvOS only
             .topShelfSections,
             // Tab bar (compact size class) layout
             .tabBarItemOrder, .tabBarItemVisibility, .tabBarStartupTab,
             // Sidebar layout/selection
             .sidebarMainItemOrder, .sidebarMainItemVisibility, .sidebarStartupTab,
             .tvOSOpenToSubscriptionsAtLaunch, .tvOSStartupTabBeforeSubscriptionsDefault,
             .sidebarSourcesEnabled, .sidebarSourceSort, .sidebarSourcesLimitEnabled, .sidebarMaxSources,
             .sidebarChannelsEnabled, .sidebarMaxChannels, .sidebarChannelSort, .sidebarChannelsLimitEnabled,
             .sidebarPlaylistsEnabled, .sidebarMaxPlaylists, .sidebarPlaylistSort, .sidebarPlaylistsLimitEnabled,
             // Player details panel — iOS/iPadOS only, different on other platforms
             .floatingDetailsPanelSide, .floatingDetailsPanelWidth,
             .landscapeDetailsPanelVisible, .landscapeDetailsPanelPinned,
             // Video swipe actions — touch-gesture feature
             .videoSwipeActionOrder, .videoSwipeActionVisibility:
            return true
        default:
            return false
        }
    }

    /// Whether this key should only be stored locally (not synced to iCloud).
    /// Used for device-specific settings like custom device name for remote control.
    var isLocalOnly: Bool {
        switch self {
        case .remoteControlCustomDeviceName, .remoteControlHideWhenBackgrounded,
             .activeControlsPresetID,  // Per-device preset selection
             .onboardingCompleted,  // Per-device onboarding state
             .tvOSStartupTabBeforeSubscriptionsDefault:  // Internal undo bookkeeping, not a user-facing setting
            return true
        default:
            return false
        }
    }
}

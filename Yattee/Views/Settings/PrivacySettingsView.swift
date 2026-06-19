//
//  PrivacySettingsView.swift
//  Yattee
//
//  Privacy settings including incognito mode and history retention.
//

import SwiftUI

struct PrivacySettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    private let historyRetentionOptions: [Int] = [0, 30, 60, 90, 180, 365]
    private let searchHistoryLimitOptions: [Int] = [10, 15, 25, 50, 100]

    var body: some View {
        SettingsFormContainer {
            incognitoSection
            historySection
            searchSection
        }
        #if !os(tvOS)
        .navigationTitle(String(localized: "settings.privacy.title"))
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private var incognitoSection: some View {
        if let settingsManager = appEnvironment?.settingsManager {
            SettingsFormSection(footer: "settings.privacy.incognito.footer") {
                Toggle(isOn: Bindable(settingsManager).incognitoModeEnabled) {
                    Label {
                        Text(String(localized: "settings.behavior.incognitoMode"))
                    } icon: {
                        #if os(macOS)
                        Image("incognito")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                        #else
                        Image("incognito")
                        #endif
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if let settingsManager = appEnvironment?.settingsManager {
            SettingsFormSection("settings.behavior.historyRetention.header", footer: "settings.behavior.historyRetention.footer") {
                Toggle(
                    String(localized: "settings.privacy.saveWatchHistory"),
                    isOn: Bindable(settingsManager).saveWatchHistory
                )

                if !(appEnvironment?.invidiousCredentialsManager.loggedInInstanceIDs.isEmpty ?? true) {
                    Toggle(
                        "Sync history and playback position with Invidious account",
                        isOn: Bindable(settingsManager).syncWatchHistoryWithInvidiousAccount
                    )
                    .disabled(!settingsManager.saveWatchHistory)
                    .onChange(of: settingsManager.syncWatchHistoryWithInvidiousAccount) { _, isOn in
                        guard let historySync = appEnvironment?.invidiousHistorySync else { return }
                        if isOn {
                            // Pull immediately so the account's state appears
                            // without waiting for the next foreground/timer tick,
                            // then keep it fresh periodically.
                            Task { await historySync.sync() }
                            historySync.startPeriodicSync()
                        } else {
                            historySync.stopPeriodicSync()
                        }
                        #if os(iOS)
                        // Keep the OS background-refresh task in sync with the
                        // setting so playback sync runs in the background even
                        // when video notifications are off. (playback-sync)
                        if settingsManager.backgroundRefreshShouldBeScheduled {
                            appEnvironment?.backgroundRefreshManager.scheduleIOSBackgroundRefresh()
                        } else {
                            appEnvironment?.backgroundRefreshManager.cancelIOSBackgroundRefresh()
                        }
                        #endif
                    }
                }

                PlatformMenuPicker(
                    String(localized: "settings.behavior.historyRetention"),
                    selection: Binding(
                        get: { settingsManager.historyRetentionDays },
                        set: { settingsManager.historyRetentionDays = $0 }
                    )
                ) {
                    ForEach(historyRetentionOptions, id: \.self) { days in
                        Text(labelForHistoryRetentionDays(days))
                            .tag(days)
                    }
                }
            }
        }
    }

    private func labelForHistoryRetentionDays(_ days: Int) -> String {
        switch days {
        case 0:
            return String(localized: "settings.behavior.historyRetention.never")
        case 365:
            return String(localized: "settings.behavior.historyRetention.year")
        default:
            return String(localized: "settings.behavior.historyRetention.days \(days)")
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if let settingsManager = appEnvironment?.settingsManager {
            SettingsFormSection("settings.behavior.searchHistoryLimit.header", footer: "settings.behavior.searchHistoryLimit.footer") {
                Toggle(
                    String(localized: "settings.privacy.saveRecentSearches"),
                    isOn: Bindable(settingsManager).saveRecentSearches
                )

                Toggle(
                    String(localized: "settings.privacy.saveRecentChannels"),
                    isOn: Bindable(settingsManager).saveRecentChannels
                )

                Toggle(
                    String(localized: "settings.privacy.saveRecentPlaylists"),
                    isOn: Bindable(settingsManager).saveRecentPlaylists
                )

                PlatformMenuPicker(
                    String(localized: "settings.behavior.searchHistoryLimit"),
                    selection: Binding(
                        get: { settingsManager.searchHistoryLimit },
                        set: { settingsManager.searchHistoryLimit = $0 }
                    )
                ) {
                    ForEach(searchHistoryLimitOptions, id: \.self) { limit in
                        Text(String(localized: "settings.behavior.searchHistoryLimit.queries \(limit)"))
                            .tag(limit)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PrivacySettingsView()
    }
    .appEnvironment(.preview)
}

//
//  NotRecommendSettingsView.swift
//  Yattee
//
//  FORK (norecommend): manages the signed-in Invidious account's
//  don't-recommend list, so a mis-tap in a context menu is recoverable
//  without leaving the app.
//
//  The API returns bare video IDs and channel UCIDs with no titles, so rows
//  show the identifier and resolve a display name in the background where
//  the instance can supply one.
//

import SwiftUI

struct NotRecommendSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    @State private var isLoading = false
    @State private var showingClearConfirmation = false
    /// Resolved display names keyed by video ID / UCID, filled in as
    /// lookups land. Absent entries just render as their identifier.
    @State private var titles: [String: String] = [:]

    private var service: NotRecommendService? { appEnvironment?.notRecommendService }

    private var blockedVideos: [String] {
        (service?.videos).map { $0.sorted() } ?? []
    }

    private var blockedChannels: [String] {
        (service?.channels).map { $0.sorted() } ?? []
    }

    private var isEmpty: Bool {
        blockedVideos.isEmpty && blockedChannels.isEmpty
    }

    var body: some View {
        SettingsFormContainer {
            if isLoading && service?.lastLoadedAt == nil {
                SettingsFormSection {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            } else if isEmpty {
                SettingsFormSection(footer: "settings.notRecommend.empty.footer") {
                    Text(String(localized: "settings.notRecommend.empty"))
                        .foregroundStyle(.secondary)
                }
            } else {
                if !blockedChannels.isEmpty {
                    SettingsFormSection("settings.notRecommend.channels.header") {
                        ForEach(blockedChannels, id: \.self) { channelID in
                            row(id: channelID, systemImage: "person.slash") {
                                await service?.unblockChannel(channelID)
                            }
                        }
                    }
                }

                if !blockedVideos.isEmpty {
                    SettingsFormSection("settings.notRecommend.videos.header") {
                        ForEach(blockedVideos, id: \.self) { videoID in
                            row(id: videoID, systemImage: "play.slash") {
                                await service?.unblockVideo(videoID)
                            }
                        }
                    }
                }

                SettingsFormSection(footer: "settings.notRecommend.clearAll.footer") {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Text(String(localized: "settings.notRecommend.clearAll"))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        #if !os(tvOS)
        .navigationTitle(String(localized: "settings.notRecommend.title"))
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            isLoading = true
            await service?.refresh()
            isLoading = false
            await resolveTitles()
        }
        .alert(
            String(localized: "settings.notRecommend.clearAll.confirm.title"),
            isPresented: $showingClearConfirmation
        ) {
            Button(String(localized: "common.cancel"), role: .cancel) {}
            Button(String(localized: "settings.notRecommend.clearAll"), role: .destructive) {
                Task { await service?.clearAll() }
            }
        } message: {
            Text(String(localized: "settings.notRecommend.clearAll.confirm.message"))
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(id: String, systemImage: String, remove: @escaping () async -> Void) -> some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(titles[id] ?? id)
                        .lineLimit(1)
                    if titles[id] != nil {
                        Text(id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await remove() }
            } label: {
                Text(String(localized: "settings.notRecommend.allowAgain"))
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Title Resolution

    /// Best-effort: the list endpoint returns identifiers only. Failures are
    /// silent — the row falls back to showing the raw ID, which is still
    /// enough to remove the right entry.
    private func resolveTitles() async {
        guard let appEnvironment,
              let instance = appEnvironment.instancesManager.instances.first(where: {
                  $0.type == .invidious && $0.isEnabled
              }) else { return }

        let contentService = appEnvironment.contentService

        for channelID in blockedChannels where titles[channelID] == nil {
            if let channel = try? await contentService.channel(id: channelID, instance: instance) {
                titles[channelID] = channel.name
            }
        }

        for videoID in blockedVideos where titles[videoID] == nil {
            if let video = try? await contentService.video(id: videoID, instance: instance) {
                titles[videoID] = video.title
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        NotRecommendSettingsView()
    }
    .appEnvironment(.preview)
}

# Fork changes (com.bammcm.yattee)

This fork of `yattee/yattee` (branch `rewrite/v2`) adds four things and rebrands
the bundle identifier. This file is the **merge checklist**: when pulling
upstream, re-apply / re-verify the inline edits listed under "Upstream files
touched". All fork-only logic lives in new files (no merge risk there).

Every inline edit in an upstream file is tagged with a `// FORK:` (or
`// FORK (feature):`) comment — run `git grep "FORK"` to find them all.

## Features

1. **Server-driven Shorts filtering** — `Video.isShort` is read from the backend
   (the `shorts-filter` Invidious fork's `isShort` JSON field; Piped's own flag),
   falling back to a ≤60s length heuristic. A global **Hide Shorts** setting and a
   per-list **Videos / Shorts / All** segmented selector use it.
2. **Invidious account playback sync** — watched state (`/api/v1/auth/history`)
   and resume position (the `shorts-filter` fork's `/api/v1/auth/positions`) sync
   with the signed-in Invidious account. Independent of the existing iCloud sync.
3. **Bundle-ID rebrand** — `stream.yattee.app` → `com.bammcm.yattee` for signing,
   plus `icloud-container-environment = Production` for TestFlight.
4. **Offline SponsorBlock** (iOS/macOS) — when a video is downloaded, its
   SponsorBlock segments are fetched and persisted on the `Download` record, so
   sponsor skipping works during offline playback. Captured in the background at
   download completion (never blocks completion); loaded at play time for
   downloaded videos (where the normal online fetch is skipped). All categories
   are stored; the player filters by enabled categories at playback time.

## New files (fork-owned, conflict-free)

- `Yattee/Services/InvidiousHistorySyncService.swift` — push/pull coordinator.
- `Yattee/Data/DataManager+InvidiousHistorySync.swift` — `markFinishedFromSync`.
- `Yattee/Core/Settings/SettingsManager+ShortsSync.swift` — `hideShorts` &
  `syncWatchHistoryWithInvidiousAccount` accessors.
- `Yattee/Models/Navigation/FeedVideoKind.swift` — All/Videos/Shorts enum.
- `Yattee/Services/Downloads/DownloadManager+OfflineSponsorBlock.swift` —
  `captureSponsorSegments` (fetch) + `captureAndStoreSponsorSegments` (background
  patch of the completed record). All offline-SponsorBlock logic lives here.

## Upstream files touched (re-verify on merge)

| File | Change | Tag |
|------|--------|-----|
| `Yattee/Models/Video.swift` | `isShort: Bool` property + init param/assignment | — |
| `Yattee/Services/API/InvidiousAPI.swift` | `isShort` in `InvidiousVideo`/`InvidiousRecommendedVideo` `toVideo`; 6 history/position methods (must stay — `httpClient` is file-private) | `FORK` |
| `Yattee/Services/API/PipedAPI.swift` | thread `isShort` into two `toVideo` builders | — |
| `Yattee/Core/SettingsManager.swift` | two backing `_` stored vars (must stay — stored props can't be in extensions) | `FORK` |
| `Yattee/Services/Player/PlayerService.swift` | `invidiousHistorySync` property + setter; push in `saveProgress`/`saveProgressAndSync`, `markWatched` in `saveProgressAsCompleted`, resume fallback in `play()`; **offline-sponsorblock**: load persisted segments (+ online fallback) in the downloaded-stream branch of `play()` | `FORK` |
| `Yattee/Core/AppEnvironment.swift` | construct + inject `InvidiousHistorySyncService`, pull on launch; **offline-sponsorblock**: `downloadManager.setSponsorBlockDependencies(...)` | `FORK` |
| `Yattee/Services/Downloads/Download.swift` | `sponsorSegments` field + CodingKey + `decodeIfPresent` (backwards-compatible) | `FORK (offline-sponsorblock)` |
| `Yattee/Services/Downloads/DownloadManager.swift` | `sponsorBlockAPI`/`sponsorBlockSettings` props + `setSponsorBlockDependencies` (stored props can't live in an extension; tvOS stub has a no-op) | `FORK (offline-sponsorblock)` |
| `Yattee/Services/Downloads/DownloadManager+Execution.swift` | one `captureAndStoreSponsorSegments(...)` call in `completeMultiFileDownload` | `FORK (offline-sponsorblock)` |
| `Yattee/Services/Player/SponsorBlockAPI.swift` | `SponsorBlockSegment` gains `Equatable` (required so `Download`'s synthesized `Equatable` still holds) | `FORK (offline-sponsorblock)` |
| `Yattee/Views/Subscriptions/SubscriptionsView.swift` | `videoKind` state, filter in `filteredVideos`, `videoKindPicker` in both layouts | — |
| `Yattee/Views/Search/SearchView.swift` | `videoKind` state, filter in `unifiedResults`, `videoKindPicker` under filter strip | — |
| `Yattee/Views/Settings/PlaybackSettingsView.swift` | "Hide Shorts" toggle | — |
| `Yattee/Views/Settings/PrivacySettingsView.swift` | "Sync history with Invidious account" toggle | — |
| `Yattee.xcodeproj/project.pbxproj`, `*/*.entitlements`, `Yattee/Info*.plist`, `*/AppGroup.swift`, `Yattee/Core/AppIdentifiers.swift` | bundle-ID rebrand + iCloud `Production` env | — |

## Notes

- `Video` is `Codable`; old cached blobs without `isShort` fail-decode gracefully
  (cache rebuilds), so the field is safe to add.
- Position pulls decode with a plain `JSONDecoder` — the shared decoder's
  `.convertFromSnakeCase` would corrupt video-ID keys containing `_`.
- The Invidious-fork backend changes live in `superbam/invidious` (branch
  `shorts-filter`): `isShort` in the JSON API + the `/api/v1/auth/positions`
  endpoints, all marked `# shorts-filter`.

import Foundation

/// Filter mode for the subscriptions feed: everything, long-form videos only,
/// or Shorts only. Surfaced as a segmented picker when Shorts aren't globally
/// hidden via the Hide Shorts setting.
enum FeedVideoKind: String, CaseIterable, Identifiable {
    case all
    case videos
    case shorts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .videos: return String(localized: "Videos")
        case .shorts: return String(localized: "Shorts")
        }
    }
}

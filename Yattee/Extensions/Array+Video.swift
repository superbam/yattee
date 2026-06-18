//
//  Array+Video.swift
//  Yattee
//
//  Convenience filtering for video lists.
//

import Foundation

extension Array where Element == Video {
    /// Returns the videos with Shorts removed when `hidden` is true.
    ///
    /// `Video.isShort` prefers the backend's authoritative flag (the
    /// shorts-filter Invidious fork), falling back to a length heuristic.
    func filteringShorts(_ hidden: Bool) -> [Video] {
        hidden ? filter { !$0.isShort } : self
    }
}

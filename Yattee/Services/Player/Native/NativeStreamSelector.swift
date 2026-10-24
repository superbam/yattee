//
//  NativeStreamSelector.swift
//  Yattee
//
//  Picks the video + audio streams the native (AVPlayer) backend can play
//  (native-player). Apple's player handles H.264 + AAC in fragmented MP4;
//  anything else (VP9, AV1, Opus, live, ...) stays on mpv.
//

import Foundation

enum NativeStreamSelector {
    /// UserDefaults key for the tvOS switch (default on).
    static let enabledKey = "tvNativePlayerEnabled"

    static var isEnabled: Bool {
        #if os(tvOS)
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
        #else
        false
        #endif
    }

    /// Best H.264 video-only + AAC audio-only pair with DASH ranges, or nil
    /// when the native backend can't play this video.
    static func select(from streams: [Stream], maxResolution: StreamResolution?) -> (video: Stream, audio: Stream)? {
        guard !streams.contains(where: { $0.isLive }) else { return nil }

        let videos = streams.filter { stream in
            guard !stream.isAudioOnly, stream.isVideoOnly,
                  stream.dashInitRange != nil, stream.dashIndexRange != nil,
                  stream.mimeType?.contains("avc1") == true,
                  stream.mimeType?.hasPrefix("video/mp4") == true else { return false }
            if let maxResolution, let resolution = stream.resolution { return resolution <= maxResolution }
            return true
        }
        guard let video = videos.max(by: { lhs, rhs in
            let l = lhs.resolution?.height ?? 0, r = rhs.resolution?.height ?? 0
            if l != r { return l < r }
            let lf = lhs.fps ?? 0, rf = rhs.fps ?? 0
            if lf != rf { return lf < rf }
            return (lhs.bitrate ?? 0) < (rhs.bitrate ?? 0)
        }) else { return nil }

        let audios = streams.filter { stream in
            stream.isAudioOnly
                && stream.dashInitRange != nil && stream.dashIndexRange != nil
                && stream.mimeType?.hasPrefix("audio/mp4") == true
                && stream.mimeType?.contains("mp4a.40.2") == true
        }
        // Prefer the original-language track, then the highest bitrate.
        guard let audio = audios.max(by: { lhs, rhs in
            if lhs.isOriginalAudio != rhs.isOriginalAudio { return !lhs.isOriginalAudio }
            return (lhs.bitrate ?? 0) < (rhs.bitrate ?? 0)
        }) else { return nil }

        return (video, audio)
    }
}

extension DASHToHLS.Track {
    /// Track description for a stream that carries DASH ranges.
    init?(stream: Stream) {
        guard let initRange = stream.dashInitRange, let indexRange = stream.dashIndexRange,
              let mimeType = stream.mimeType else { return nil }
        self.init(
            url: stream.url,
            initRange: initRange,
            indexRange: indexRange,
            mimeType: mimeType,
            bitrate: stream.bitrate ?? 0,
            width: stream.resolution?.width,
            height: stream.resolution?.height,
            fps: stream.fps,
            headers: stream.httpHeaders ?? [:]
        )
    }
}

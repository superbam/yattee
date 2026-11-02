//
//  DirectLinkResolver+Stream.swift
//  Yattee
//
//  Maps streams resolved on this device onto the player's `Stream` model.
//

import Foundation

extension DirectFormat {
    func toStream() -> Stream? {
        let isAudio = mimeType.hasPrefix("audio/")
        let codecs = Self.codecs(in: mimeType)

        let videoCodec = isAudio ? nil : codecs.compactMap(Self.videoCodecName).first
        let audioCodec = codecs.compactMap(Self.audioCodecName).first

        // Streams without a video codec that aren't audio (storyboards, etc.) are not playable.
        guard isAudio || videoCodec != nil else { return nil }

        let originalAudio = (audioTrackName?.localizedCaseInsensitiveContains("original") ?? false) || audioIsDefault

        return Stream(
            url: url,
            resolution: isAudio ? nil : height.flatMap { StreamResolution(heightLabel: "\($0)p") },
            format: Self.container(for: mimeType),
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            bitrate: bitrate,
            fileSize: contentLength,
            isAudioOnly: isAudio,
            isLive: false,
            mimeType: mimeType,
            audioLanguage: isAudio ? audioTrackID : nil,
            audioTrackName: isAudio ? audioTrackName : nil,
            isOriginalAudio: isAudio && originalAudio,
            fps: isAudio ? nil : fps,
            dashInitRange: initRange,
            dashIndexRange: indexRange,
            isDirect: true
        )
    }

    private static func codecs(in mimeType: String) -> [String] {
        guard let start = mimeType.range(of: "codecs=\""),
              let end = mimeType[start.upperBound...].firstIndex(of: "\"") else { return [] }
        return mimeType[start.upperBound..<end]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }

    private static func videoCodecName(_ codec: String) -> String? {
        if codec.hasPrefix("avc") { return "avc1" }
        if codec.hasPrefix("vp9") || codec.hasPrefix("vp09") { return "vp9" }
        if codec.hasPrefix("av01") || codec.hasPrefix("av1") { return "av1" }
        if codec.hasPrefix("hev") || codec.hasPrefix("hvc") { return "hevc" }
        return nil
    }

    private static func audioCodecName(_ codec: String) -> String? {
        if codec.hasPrefix("mp4a") { return "aac" }
        if codec.contains("opus") { return "opus" }
        if codec.contains("vorbis") { return "vorbis" }
        return nil
    }

    /// Same container names Invidious reports: mp4, webm, and m4a for MP4 audio.
    private static func container(for mimeType: String) -> String {
        let type = mimeType.split(separator: ";").first.map(String.init) ?? mimeType
        switch type {
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "audio/mp4": return "m4a"
        case "audio/webm": return "webm"
        default: return type.split(separator: "/").last.map(String.init) ?? "unknown"
        }
    }
}

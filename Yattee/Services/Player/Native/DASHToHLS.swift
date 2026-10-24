//
//  DASHToHLS.swift
//  Yattee
//
//  Builds HLS playlists from YouTube's DASH fragmented-MP4 streams (native-player).
//
//  Invidious lists video and audio as separate fMP4 files, each with an init
//  range and an index (sidx) range. Apple's player can't join two URLs, but it
//  plays HLS with a separate audio rendition. So we read each file's sidx and
//  emit a media playlist whose segments are byte ranges of the original URL,
//  plus a master playlist tying the two together. Nothing is downloaded or
//  remuxed here beyond the few-KB sidx boxes; the player fetches segments
//  straight from the stream host.
//

import Foundation

nonisolated enum DASHToHLS {
    /// One DASH track as Invidious describes it.
    struct Track: Sendable {
        let url: URL
        /// "start-end" inclusive byte range of the init segment (ftyp+moov).
        let initRange: String
        /// "start-end" inclusive byte range of the sidx box.
        let indexRange: String
        /// Full MIME type, e.g. `video/mp4; codecs="avc1.64002A"`.
        let mimeType: String
        let bitrate: Int
        let width: Int?
        let height: Int?
        let fps: Int?
        let headers: [String: String]
    }

    struct Playlists: Sendable {
        let master: String
        let video: String
        let audio: String
        /// Duration in seconds, from the video playlist.
        let duration: TimeInterval
    }

    enum BuildError: LocalizedError {
        case badRange(String)
        case badSidx(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badRange(let s): return "Invalid byte range \(s)"
            case .badSidx(let s): return "Could not read stream index: \(s)"
            case .http(let code): return "Stream index request failed (HTTP \(code))"
            }
        }
    }

    struct Segment: Sendable {
        let duration: Double
        let size: Int
        let offset: Int
    }

    static func build(video: Track, audio: Track, session: URLSession = .shared) async throws -> Playlists {
        async let v = mediaPlaylist(for: video, session: session)
        async let a = mediaPlaylist(for: audio, session: session)
        let (videoPlaylist, videoDuration) = try await v
        let (audioPlaylist, _) = try await a

        let videoCodec = codecs(in: video.mimeType) ?? "avc1.640028"
        let audioCodec = codecs(in: audio.mimeType) ?? "mp4a.40.2"
        var streamInf = "#EXT-X-STREAM-INF:BANDWIDTH=\(video.bitrate + audio.bitrate),CODECS=\"\(videoCodec),\(audioCodec)\""
        if let w = video.width, let h = video.height { streamInf += ",RESOLUTION=\(w)x\(h)" }
        if let fps = video.fps { streamInf += ",FRAME-RATE=\(fps)" }
        streamInf += ",AUDIO=\"aud\""

        let master = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
            streamInf,
            "video.m3u8",
            ""
        ].joined(separator: "\n")

        return Playlists(master: master, video: videoPlaylist, audio: audioPlaylist, duration: videoDuration)
    }

    // MARK: - Media playlist

    private static func mediaPlaylist(for track: Track, session: URLSession) async throws -> (String, Double) {
        let (initStart, initEnd) = try parse(range: track.initRange)
        let (indexStart, indexEnd) = try parse(range: track.indexRange)

        var request = URLRequest(url: track.url)
        track.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("bytes=\(indexStart)-\(indexEnd)", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BuildError.http(http.statusCode)
        }

        let segments = try parseSidx(data, indexEnd: indexEnd)
        guard !segments.isEmpty else { throw BuildError.badSidx("no segments") }

        let target = Int(ceil(segments.map(\.duration).max() ?? 1))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(track.url.absoluteString)\",BYTERANGE=\"\(initEnd - initStart + 1)@\(initStart)\""
        ]
        for segment in segments {
            lines.append("#EXTINF:\(String(format: "%.5f", segment.duration)),")
            lines.append("#EXT-X-BYTERANGE:\(segment.size)@\(segment.offset)")
            lines.append(track.url.absoluteString)
        }
        lines.append("#EXT-X-ENDLIST")
        lines.append("")
        return (lines.joined(separator: "\n"), segments.reduce(0) { $0 + $1.duration })
    }

    // MARK: - Parsing

    private static func parse(range: String) throws -> (Int, Int) {
        let parts = range.split(separator: "-")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), b >= a else {
            throw BuildError.badRange(range)
        }
        return (a, b)
    }

    private static func codecs(in mimeType: String) -> String? {
        guard let start = mimeType.range(of: "codecs=\"") else { return nil }
        let rest = mimeType[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end]).replacingOccurrences(of: " ", with: "")
    }

    /// Parses a `sidx` box. `indexEnd` is the last byte of the box in the file;
    /// the first referenced segment starts right after it plus `first_offset`.
    static func parseSidx(_ data: Data, indexEnd: Int) throws -> [Segment] {
        let bytes = [UInt8](data)
        guard bytes.count >= 32 else { throw BuildError.badSidx("short box") }
        func u32(_ i: Int) -> Int { Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) }
        func u64(_ i: Int) -> Int { (u32(i) << 32) | u32(i + 4) }

        guard String(bytes: bytes[4..<8], encoding: .ascii) == "sidx" else { throw BuildError.badSidx("not a sidx box") }
        let version = bytes[8]
        var p = 12
        p += 4 // reference_ID
        let timescale = u32(p); p += 4
        guard timescale > 0 else { throw BuildError.badSidx("zero timescale") }
        let firstOffset: Int
        if version == 0 {
            p += 4 // earliest_presentation_time
            firstOffset = u32(p); p += 4
        } else {
            p += 8
            firstOffset = u64(p); p += 8
        }
        p += 2 // reserved
        let count = Int(bytes[p]) << 8 | Int(bytes[p + 1]); p += 2
        guard bytes.count >= p + count * 12 else { throw BuildError.badSidx("truncated") }

        var offset = indexEnd + 1 + firstOffset
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            let size = u32(p) & 0x7fffffff
            let duration = Double(u32(p + 4)) / Double(timescale)
            segments.append(Segment(duration: duration, size: size, offset: offset))
            offset += size
            p += 12
        }
        return segments
    }
}

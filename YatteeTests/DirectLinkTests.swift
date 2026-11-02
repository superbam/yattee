//
//  DirectLinkTests.swift
//  YatteeTests
//
//  Direct playback: mapping device-fetched formats onto streams, and when it applies.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Direct playback")
struct DirectLinkTests {
    private let link = URL(string: "https://rr4---sn-example.googlevideo.com/videoplayback?n=abc")!

    private func format(
        mime: String,
        itag: Int? = 137,
        height: Int? = 1080,
        muxed: Bool = false,
        track: (id: String, name: String, isDefault: Bool)? = nil
    ) -> DirectFormat {
        DirectFormat(
            url: link, itag: itag, mimeType: mime, bitrate: 2_000_000, width: 1920, height: height, fps: 30,
            contentLength: 12_345, audioTrackID: track?.id, audioTrackName: track?.name,
            audioIsDefault: track?.isDefault ?? false, initRange: "0-740", indexRange: "741-2824", isMuxed: muxed
        )
    }

    @Test("Adaptive video maps like an Invidious stream")
    func adaptiveVideo() throws {
        let stream = try #require(format(mime: "video/mp4; codecs=\"avc1.640028\"").toStream())
        #expect(stream.format == "mp4")
        #expect(stream.videoCodec == "avc1")
        #expect(stream.resolution == StreamResolution(heightLabel: "1080p"))
        #expect(!stream.isAudioOnly)
        #expect(stream.isDirect)
        #expect(stream.dashInitRange == "0-740")
        #expect(stream.dashIndexRange == "741-2824")
    }

    @Test("MP4 audio is reported as m4a with an AAC codec")
    func audioStream() throws {
        let stream = try #require(format(mime: "audio/mp4; codecs=\"mp4a.40.2\"", itag: 140, height: nil).toStream())
        #expect(stream.isAudioOnly)
        #expect(stream.format == "m4a")
        #expect(stream.audioCodec == "aac")
        #expect(stream.resolution == nil)
    }

    @Test("Original audio track is recognised")
    func originalAudio() throws {
        let original = try #require(format(mime: "audio/mp4; codecs=\"mp4a.40.2\"", height: nil,
                                           track: ("en.4", "English original", true)).toStream())
        #expect(original.isOriginalAudio)
        #expect(original.audioLanguage == "en.4")
        let dubbed = try #require(format(mime: "audio/mp4; codecs=\"mp4a.40.2\"", height: nil,
                                         track: ("de.3", "German", false)).toStream())
        #expect(!dubbed.isOriginalAudio)
    }

    @Test("Muxed streams keep both codecs")
    func muxed() throws {
        let stream = try #require(format(mime: "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", itag: 18, height: 360, muxed: true).toStream())
        #expect(stream.videoCodec == "avc1")
        #expect(stream.audioCodec == "aac")
        #expect(stream.isMuxed)
    }

    @Test("Formats that are neither audio nor a known video codec are dropped")
    func unplayable() {
        #expect(format(mime: "application/x-unknown").toStream() == nil)
    }

    @Test("Device-fetched links are never rewritten through the server")
    func notProxied() {
        let instance = Instance(
            type: .invidious,
            url: URL(string: "https://invidious.example.com")!,
            proxiesVideos: true
        )
        let direct = Stream(url: link, format: "mp4", isDirect: true)
        let ordinary = Stream(url: link, format: "mp4")
        let result = InvidiousAPI.proxyStreamsIfNeeded([direct, ordinary], instance: instance)
        #expect(result[0].url == link)
        #expect(result[1].url != link)
    }

    @Test("Direct playback only applies on the external address of an opted-in Invidious instance")
    func appliesOnlyWhenExternal() {
        let home = URL(string: "http://192.168.1.6:3000")!
        let external = URL(string: "https://invidious.example.com")!
        let instance = Instance(type: .invidious, url: home, externalURL: external, directPlayback: true)
        #expect(!instance.usesDirectPlayback)
        #expect(instance.withURL(external).usesDirectPlayback)

        let optedOut = Instance(type: .invidious, url: home, externalURL: external, directPlayback: false)
        #expect(!optedOut.withURL(external).usesDirectPlayback)

        let piped = Instance(type: .piped, url: home, externalURL: external, directPlayback: true)
        #expect(!piped.withURL(external).usesDirectPlayback)
    }

    @Test("Instances saved before direct playback existed decode with it off")
    func legacyDecode() throws {
        var json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(Instance(type: .invidious, url: URL(string: "https://x.example.com")!))
        ) as? [String: Any])
        json.removeValue(forKey: "directPlayback")
        let decoded = try JSONDecoder().decode(Instance.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.directPlayback)
    }
}

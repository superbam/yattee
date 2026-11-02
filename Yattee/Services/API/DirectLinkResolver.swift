//
//  DirectLinkResolver.swift
//  Yattee
//
//  Optional "direct playback" for an Invidious instance reached through its external
//  address. YouTube signs stream links for the address that asks for them, so links the
//  server fetches only work from the server's own network. Here the device asks YouTube
//  itself, so the links are signed for the device and the video flows straight from
//  YouTube to it. The server's only job is to supply the anti-bot token and the player
//  script (see the companion's /session and /playerScript routes).
//
//  This file depends only on Foundation and JavaScriptCore so it can be exercised on its
//  own; DirectLinkResolver+Stream.swift adapts the result for the player.
//

import Foundation
import JavaScriptCore

/// One stream YouTube offered, with a link that is valid for this device.
struct DirectFormat: Sendable, Equatable {
    var url: URL
    var itag: Int?
    var mimeType: String
    var bitrate: Int?
    var width: Int?
    var height: Int?
    var fps: Int?
    var contentLength: Int64?
    var audioTrackID: String?
    var audioTrackName: String?
    var audioIsDefault: Bool
    var initRange: String?
    var indexRange: String?
    /// True for the combined audio+video entries (`formats`) as opposed to `adaptiveFormats`.
    var isMuxed: Bool
}

enum DirectLinkError: LocalizedError {
    case sessionUnavailable(Int)
    case malformedSession
    case playerRejected(String)
    case noStreams
    case challengeFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable(let status): return "Direct playback session unavailable (HTTP \(status))"
        case .malformedSession: return "Direct playback session was malformed"
        case .playerRejected(let reason): return "YouTube did not return streams: \(reason)"
        case .noStreams: return "YouTube returned no playable streams"
        case .challengeFailed(let detail): return "Could not solve the stream challenge: \(detail)"
        }
    }
}

/// Runs YouTube's `n` challenge (a function from the player script) in JavaScriptCore.
/// Not thread-safe: owned and serialised by `DirectLinkResolver`.
final class NChallengeSolver {
    private var context: JSContext?
    private var playerID: String?

    /// Loads the player script once per player version.
    func load(script: String, playerID: String) throws {
        if self.playerID == playerID, context != nil { return }
        let ctx = JSContext()!
        var failure: String?
        ctx.exceptionHandler = { _, exception in failure = exception?.toString() }
        // The script assigns its exports to `exportedVars` and expects a function body.
        ctx.evaluateScript("var __exported = (function(){\n\(script)\nreturn exportedVars;\n})();")
        if let failure { throw DirectLinkError.challengeFailed(failure) }
        ctx.evaluateScript(Self.processor)
        if let failure { throw DirectLinkError.challengeFailed(failure) }
        context = ctx
        self.playerID = playerID
    }

    func solve(_ n: String) throws -> String {
        guard let context else { throw DirectLinkError.challengeFailed("player script not loaded") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        let result = context.objectForKeyedSubscript("__solveN")?.call(withArguments: [n])
        if let failure { throw DirectLinkError.challengeFailed(failure) }
        guard let solved = result?.toString(), !solved.isEmpty, solved != "undefined", solved != "null",
              !solved.hasPrefix("enhanced_except_") else {
            throw DirectLinkError.challengeFailed("no result for n")
        }
        return solved
    }

    /// Same wrapper youtubei.js uses: build a throwaway URL, let the player's function
    /// transform it, and read `n` back.
    private static let processor = """
    function __solveN(n) {
      var mock = "https://ytjs.googlevideo.com/videoplayback?expire=1234567890&n=" + encodeURIComponent(n);
      var ctor = __exported.nsigFunction;
      if (!ctor) { throw new Error('No n/sig decipher function extracted'); }
      var urlCtor = ctor(mock, "", "");
      var proto = Object.getPrototypeOf(urlCtor);
      var props = Object.getOwnPropertyNames(proto);
      var blacklist = ['constructor', 'clone', 'set', 'get'];
      for (var i = 0; i < props.length; i++) {
        var prop = props[i];
        if (blacklist.indexOf(prop) !== -1) { continue; }
        if (typeof urlCtor[prop] === 'function') { urlCtor[prop](); }
      }
      var r = urlCtor.get('n');
      return r ? decodeURIComponent(r) : undefined;
    }
    """
}

actor DirectLinkResolver {
    static let shared = DirectLinkResolver()

    private let solver = NChallengeSolver()
    private var scriptCache: [String: String] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches stream links for `videoID` that are valid for this device.
    /// - Parameters:
    ///   - baseURL: The instance's address (it serves `/direct/session/<id>` and `/direct/player/<id>`).
    ///   - authorization: Optional `Authorization` header for a reverse proxy in front of it.
    func resolve(videoID: String, baseURL: URL, authorization: String?) async throws -> [DirectFormat] {
        let package = try await fetchSession(videoID: videoID, baseURL: baseURL, authorization: authorization)
        let script = try await playerScript(for: package.playerID, baseURL: baseURL, authorization: authorization)
        try solver.load(script: script, playerID: package.playerID)

        let response = try await requestPlayer(videoID: videoID, package: package)
        let status = (response["playabilityStatus"] as? [String: Any])?["status"] as? String
        let streaming = response["streamingData"] as? [String: Any]
        guard status == "OK", let streaming else {
            let reason = (response["playabilityStatus"] as? [String: Any])?["reason"] as? String
            throw DirectLinkError.playerRejected(reason ?? status ?? "unknown")
        }

        var solvedN: [String: String] = [:]
        var formats: [DirectFormat] = []
        for (key, muxed) in [("formats", true), ("adaptiveFormats", false)] {
            for raw in (streaming[key] as? [[String: Any]]) ?? [] {
                guard let urlString = raw["url"] as? String,
                      var components = URLComponents(string: urlString) else { continue }
                if let n = components.queryItems?.first(where: { $0.name == "n" })?.value {
                    let solved = try solvedN[n] ?? solver.solve(n)
                    solvedN[n] = solved
                    Self.setQuery(&components, "n", solved)
                }
                // Parameters the companion also adds before handing links out.
                Self.setQuery(&components, "pot", package.streamPoToken)
                Self.setQuery(&components, "cver", "1.0")
                Self.setQuery(&components, "alr", "no")
                guard let url = components.url else { continue }
                formats.append(Self.format(from: raw, url: url, muxed: muxed))
            }
        }
        guard !formats.isEmpty else { throw DirectLinkError.noStreams }
        return formats
    }

    // MARK: - Server

    private struct SessionPackage {
        let poToken: String
        let streamPoToken: String
        let visitorData: String
        let hl: String
        let gl: String
        let signatureTimestamp: Int?
        let playerID: String
    }

    private func fetchSession(videoID: String, baseURL: URL, authorization: String?) async throws -> SessionPackage {
        let url = baseURL.appendingPathComponent("direct/session/\(videoID)")
        let (data, status) = try await get(url, authorization: authorization, timeout: 20)
        guard status == 200 else { throw DirectLinkError.sessionUnavailable(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poToken = json["poToken"] as? String,
              let streamPoToken = json["streamPoToken"] as? String,
              let visitorData = json["visitorData"] as? String,
              let playerID = json["playerId"] as? String else {
            throw DirectLinkError.malformedSession
        }
        return SessionPackage(
            poToken: poToken,
            streamPoToken: streamPoToken,
            visitorData: visitorData,
            hl: json["hl"] as? String ?? "en",
            gl: json["gl"] as? String ?? "US",
            signatureTimestamp: json["signatureTimestamp"] as? Int,
            playerID: playerID
        )
    }

    private func playerScript(for playerID: String, baseURL: URL, authorization: String?) async throws -> String {
        if let cached = scriptCache[playerID] { return cached }
        let url = baseURL.appendingPathComponent("direct/player/\(playerID)")
        let (data, status) = try await get(url, authorization: authorization, timeout: 30)
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let script = json["script"] as? String else {
            throw DirectLinkError.sessionUnavailable(status)
        }
        scriptCache = [playerID: script]   // only the current player is ever needed
        return script
    }

    // MARK: - YouTube

    private func requestPlayer(videoID: String, package: SessionPackage) async throws -> [String: Any] {
        var playback: [String: Any] = ["vis": 0, "splay": false, "lactMilliseconds": "-1"]
        if let timestamp = package.signatureTimestamp { playback["signatureTimestamp"] = timestamp }
        let body: [String: Any] = [
            "context": [
                "client": ["clientName": "TVHTML5_SIMPLY", "clientVersion": "1.0", "hl": package.hl, "gl": package.gl,
                           "visitorData": package.visitorData],
                "user": ["lockedSafetyMode": false],
                "request": ["useSsl": true],
            ],
            "videoId": videoID, "racyCheckOk": true, "contentCheckOk": true,
            "playbackContext": ["contentPlaybackContext": playback],
            "serviceIntegrityDimensions": ["poToken": package.poToken],
        ]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (field, value) in [
            "Content-Type": "application/json", "Origin": "https://www.youtube.com",
            "X-Goog-Visitor-Id": package.visitorData, "X-Youtube-Client-Name": "75", "X-Youtube-Client-Version": "1.0",
            "User-Agent": "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        ] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DirectLinkError.playerRejected("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        return json
    }

    // MARK: - Helpers

    private func get(_ url: URL, authorization: String?, timeout: TimeInterval) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
    }

    private nonisolated static func setQuery(_ components: inout URLComponents, _ name: String, _ value: String) {
        components.queryItems = (components.queryItems ?? []).filter { $0.name != name } + [URLQueryItem(name: name, value: value)]
    }

    private nonisolated static func format(from raw: [String: Any], url: URL, muxed: Bool) -> DirectFormat {
        func range(_ key: String) -> String? {
            guard let r = raw[key] as? [String: Any],
                  let start = (r["start"] as? String) ?? (r["start"] as? Int).map(String.init),
                  let end = (r["end"] as? String) ?? (r["end"] as? Int).map(String.init) else { return nil }
            return "\(start)-\(end)"
        }
        let track = raw["audioTrack"] as? [String: Any]
        return DirectFormat(
            url: url,
            itag: raw["itag"] as? Int,
            mimeType: raw["mimeType"] as? String ?? "",
            bitrate: raw["bitrate"] as? Int,
            width: raw["width"] as? Int,
            height: raw["height"] as? Int,
            fps: raw["fps"] as? Int,
            contentLength: (raw["contentLength"] as? String).flatMap { Int64($0) },
            audioTrackID: track?["id"] as? String,
            audioTrackName: track?["displayName"] as? String,
            audioIsDefault: track?["audioIsDefault"] as? Bool ?? false,
            initRange: range("initRange"),
            indexRange: range("indexRange"),
            isMuxed: muxed
        )
    }
}

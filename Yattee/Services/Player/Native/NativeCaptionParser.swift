//
//  NativeCaptionParser.swift
//  Yattee
//
//  Parses WebVTT / SRT caption files for the native (AVPlayer) backend
//  (native-player). Apple's AVPlayerLayer doesn't draw subtitles itself, so
//  the backend renders the cues with a label.
//

import Foundation

nonisolated struct NativeCaptionCue: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

nonisolated enum NativeCaptionParser {
    /// Parses WebVTT or SRT text into cues sorted by start time.
    static func parse(_ text: String) -> [NativeCaptionCue] {
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var cues: [NativeCaptionCue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            var lines = block.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            guard let (start, end) = parseTiming(lines[timingIndex]) else { continue }
            lines = Array(lines[(timingIndex + 1)...])
            let body = lines.map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            cues.append(NativeCaptionCue(start: start, end: end, text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Cues showing at `time`.
    static func active(in cues: [NativeCaptionCue], at time: TimeInterval) -> [NativeCaptionCue] {
        // Cues are sorted by start; find the first one starting after `time`.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        // Walk back a bounded distance for overlapping cues that are still showing.
        var result: [NativeCaptionCue] = []
        var index = low - 1
        while index >= 0, low - index <= 8 {
            if cues[index].end > time { result.insert(cues[index], at: 0) }
            index -= 1
        }
        return result
    }

    // MARK: - Helpers

    private static func parseTiming(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        // The end time may be followed by cue settings ("align:start position:0%").
        let endToken = parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let start = seconds(from: parts[0].trimmingCharacters(in: .whitespaces)),
              let end = seconds(from: endToken) else { return nil }
        return (start, end)
    }

    /// "HH:MM:SS.mmm", "MM:SS.mmm" or SRT's "HH:MM:SS,mmm".
    private static func seconds(from token: String) -> TimeInterval? {
        let fields = token.replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func clean(_ line: String) -> String {
        var result = ""
        var insideTag = false
        for character in line {
            if character == "<" { insideTag = true } else if character == ">" { insideTag = false } else if !insideTag { result.append(character) }
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

//
//  TVRouteLatencyCompensation.swift
//  Yattee
//
//  Automatic A/V sync for wireless audio routes on tvOS (auto-av-sync).
//
//  mpv's avfoundation audio output does not account for the output route's
//  latency, so audio played through AirPlay (HomePod, AirPlay speakers) or
//  Bluetooth arrives late relative to the video. AVAudioSession reports that
//  latency as `outputLatency`; shifting mpv's `audio-delay` earlier by that
//  amount (negative values delay the video, see mpv's --audio-delay) lines the
//  two up without any manual adjustment.
//
//  Only wireless routes are compensated. HDMI keeps the user's manual offset
//  unchanged, since the Apple TV already aligns wired output.
//

#if os(tvOS)
import AVFoundation

enum TVRouteLatencyCompensation {
    static let enabledKey = "tvAutoAudioDelay"

    struct Reading {
        let route: String
        let isWireless: Bool
        let outputLatencyMs: Double
        let compensationMs: Double
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false
    }

    /// Snapshot of the current route and the compensation (milliseconds,
    /// zero or negative) to add to the user's manual audio delay.
    static func current() -> Reading {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let isWireless = outputs.contains { output in
            output.portType == .airPlay
                || output.portType == .bluetoothA2DP
                || output.portType == .bluetoothLE
                || output.portType == .bluetoothHFP
        }
        let latencyMs = session.outputLatency * 1000
        let route = outputs.isEmpty
            ? "no outputs"
            : outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let compensation = (isEnabled && isWireless) ? -latencyMs : 0
        return Reading(
            route: route,
            isWireless: isWireless,
            outputLatencyMs: latencyMs,
            compensationMs: compensation
        )
    }

    /// Manual offset from A/V Sync Diagnostics plus the automatic compensation.
    static func effectiveDelayMs(manualMs: Double) -> Double {
        manualMs + current().compensationMs
    }
}
#endif

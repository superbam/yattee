//
//  AVPlayerBackend.swift
//  Yattee
//
//  Experimental tvOS backend that plays Invidious' H.264 + AAC DASH streams
//  through Apple's AVPlayer (native-player), so tvOS keeps video and AirPlay /
//  HomePod audio in sync by itself. mpv stays the default and the fallback.
//
//  Video and audio arrive as two separate fMP4 URLs. `DASHToHLS` turns them
//  into HLS playlists (byte ranges of the original URLs) that a loopback
//  server hands to AVPlayer; segments are fetched directly from the stream
//  host, so nothing is relayed or remuxed.
//

#if os(tvOS)
import AVFoundation
import SwiftUI
import UIKit

/// UIView whose layer is an AVPlayerLayer.
final class NativePlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } // swiftlint:disable:this force_cast

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor
final class AVPlayerBackend: PlayerBackend {
    // MARK: - PlayerBackend properties

    let backendType: PlayerBackendType = .avplayer
    weak var delegate: PlayerBackendDelegate?

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private(set) var duration: TimeInterval = 0

    var bufferedTime: TimeInterval {
        guard let item = player.currentItem,
              let range = item.loadedTimeRanges.map(\.timeRangeValue).first(where: { $0.containsTime(player.currentTime()) })
        else { return currentTime }
        let end = range.end.seconds
        return end.isFinite ? end : currentTime
    }

    var isReady: Bool { player.currentItem?.status == .readyToPlay }
    var isPlaying: Bool { player.rate != 0 }

    private var desiredRate: Float = 1.0
    var rate: Float {
        get { desiredRate }
        set {
            desiredRate = newValue
            player.defaultRate = newValue
            if isPlaying { player.rate = newValue }
        }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    let supportedFormats: Set<StreamFormat> = [.mp4H264, .audioAAC]

    var playerView: UIView? { layerView }

    // MARK: - Private state

    private let player = AVPlayer()
    private let layerView = NativePlayerLayerView()
    private let server = LoopbackPlaylistServer()
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var controlObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var pendingInitialSeek = false
    private var didNotifyReady = false
    private var reportedStreamRefresh = false

    init() {
        layerView.playerLayer.player = player
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        startObservingPlayer()
    }

    deinit {
        // Cleanup normally happens in stop(); this is a backstop.
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    // MARK: - Playback control

    func load(stream: Stream, audioStream: Stream?, autoplay: Bool, useEDL: Bool) async throws {
        guard let audioStream,
              let videoTrack = DASHToHLS.Track(stream: stream),
              let audioTrack = DASHToHLS.Track(stream: audioStream) else {
            throw BackendError.loadFailed("Native player needs separate video and audio DASH streams")
        }

        resetItem()
        didNotifyReady = false
        reportedStreamRefresh = false

        let playlists: DASHToHLS.Playlists
        let port: UInt16
        do {
            playlists = try await DASHToHLS.build(video: videoTrack, audio: audioTrack)
            port = try await server.start()
        } catch {
            throw BackendError.loadFailed(error.localizedDescription)
        }

        // A fresh path per load keeps AVPlayer from reusing a cached playlist.
        let token = UUID().uuidString
        server.removeAll()
        server.set(path: "/\(token)/master.m3u8", data: Data(playlists.master.utf8))
        server.set(path: "/\(token)/video.m3u8", data: Data(playlists.video.utf8))
        server.set(path: "/\(token)/audio.m3u8", data: Data(playlists.audio.utf8))
        guard let url = URL(string: "http://127.0.0.1:\(port)/\(token)/master.m3u8") else {
            throw BackendError.loadFailed("Could not build local playlist URL")
        }

        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)

        try await waitUntilReady(item)

        duration = playlists.duration
        delegate?.backend(self, didUpdateDuration: duration)
        if let resolution = stream.resolution {
            delegate?.backend(self, didUpdateVideoSize: resolution.width, height: resolution.height)
        }
        delegate?.backend(self, didUpdateTracks: [])

        if autoplay { play() }
        if !pendingInitialSeek { notifyReady() }
    }

    func play() {
        player.playImmediately(atRate: desiredRate)
        delegate?.backend(self, didChangeState: .playing)
    }

    func pause() {
        player.pause()
        delegate?.backend(self, didChangeState: .paused)
    }

    func stop() {
        resetItem()
        server.stop()
        pendingInitialSeek = false
        didNotifyReady = false
        duration = 0
        delegate?.backend(self, didChangeState: .idle)
    }

    func seek(to time: TimeInterval, showLoading: Bool) async {
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        if showLoading { delegate?.backend(self, didChangeState: .loading) }
        await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        delegate?.backend(self, didUpdateTime: currentTime)
        if pendingInitialSeek {
            pendingInitialSeek = false
            notifyReady()
        }
        if showLoading { delegate?.backend(self, didChangeState: isPlaying ? .playing : .paused) }
    }

    func prepareForInitialSeek() {
        pendingInitialSeek = true
    }

    func prepareForHandoff() {}

    func restore(state: BackendState) async {
        await seek(to: state.currentTime, showLoading: false)
        rate = state.rate
        volume = state.volume
        isMuted = state.isMuted
        if state.isPlaying { play() }
    }

    // MARK: - Observation

    private func startObservingPlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem != nil else { return }
                self.delegate?.backend(self, didUpdateTime: self.currentTime)
                self.delegate?.backend(self, didUpdateBufferedTime: self.bufferedTime)
            }
        }

        controlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem != nil, self.didNotifyReady else { return }
                switch status {
                case .playing: self.delegate?.backend(self, didChangeState: .playing)
                case .paused: self.delegate?.backend(self, didChangeState: .paused)
                case .waitingToPlayAtSpecifiedRate: self.delegate?.backend(self, didChangeState: .buffering)
                @unknown default: break
                }
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            Task { @MainActor [weak self] in self?.handleFailure(error) }
        }

        sizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.backend(self, didUpdateVideoSize: Int(size.width), height: Int(size.height))
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.delegate?.backend(self, didChangeState: .ended)
                self.delegate?.backendDidFinishPlaying(self)
            }
        }
    }

    private func handleFailure(_ error: Error?) {
        let message = error?.localizedDescription ?? "unknown error"
        LoggingService.shared.error("AVPlayerBackend: item failed: \(message)", category: .player)
        if didNotifyReady, !reportedStreamRefresh {
            // After a successful start this is almost always an expired stream URL.
            reportedStreamRefresh = true
            delegate?.backend(self, didRequestStreamRefresh: currentTime)
        } else if let error {
            delegate?.backend(self, didEncounterError: error)
        }
    }

    private func notifyReady() {
        guard !didNotifyReady else { return }
        didNotifyReady = true
        delegate?.backendDidBecomeReady(self)
        delegate?.backend(self, didChangeState: isPlaying ? .playing : .ready)
    }

    private func waitUntilReady(_ item: AVPlayerItem) async throws {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            switch item.status {
            case .readyToPlay: return
            case .failed:
                throw BackendError.loadFailed(item.error?.localizedDescription ?? "Native player failed to load")
            default: break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BackendError.loadFailed("Native player timed out loading the stream")
    }

    private func resetItem() {
        statusObservation = nil
        sizeObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

/// Hosts the backend's AVPlayerLayer view in SwiftUI.
struct NativePlayerRepresentable: UIViewRepresentable {
    let backend: AVPlayerBackend

    func makeUIView(context: Context) -> UIView {
        backend.playerView ?? UIView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif

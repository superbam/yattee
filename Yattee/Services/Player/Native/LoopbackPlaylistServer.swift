//
//  LoopbackPlaylistServer.swift
//  Yattee
//
//  Minimal HTTP server on 127.0.0.1 that hands the generated HLS playlists to
//  AVPlayer (native-player). Only serves in-memory files registered with
//  `set(path:data:)`; listens on the loopback interface only.
//

import Foundation
import Network

nonisolated final class LoopbackPlaylistServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "yattee.loopback-playlist-server")
    private var listener: NWListener?
    private var files: [String: Data] = [:]
    private(set) var port: UInt16 = 0

    /// Starts listening (idempotent) and returns the port.
    func start() async throws -> UInt16 {
        if let listener, listener.state == .ready, port != 0 { return port }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    self?.port = listener.port?.rawValue ?? 0
                    continuation.resume(returning: self?.port ?? 0)
                case .failed(let error):
                    guard gate.claim() else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    /// Lets exactly one state callback resume the continuation.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if claimed { return false }
            claimed = true
            return true
        }
    }

    func set(path: String, data: Data) {
        queue.sync { files[path] = data }
    }

    func removeAll() {
        queue.sync { files.removeAll() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        queue.sync { files.removeAll() }
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil,
                  let request = String(data: data, encoding: .utf8),
                  let line = request.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : ""
            let isHead = parts.first == "HEAD"
            let body = self.files[path]

            var header = body == nil ? "HTTP/1.1 404 Not Found\r\n" : "HTTP/1.1 200 OK\r\n"
            header += "Content-Type: application/vnd.apple.mpegurl\r\n"
            header += "Content-Length: \(body?.count ?? 0)\r\n"
            header += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            if let body, !isHead { response.append(body) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

#if os(iOS) && (DEBUG || STUDIO_DEVICE_CAPTURE)
import Foundation
import Network
import SpringMotionDeviceWire
import UIKit

/// Advertises the device over Bonjour and serves the control protocol.
///
/// One `NWListener` does both jobs: it takes the TCP connections and it
/// publishes the `_springmotion._tcp` service Studio browses for. The TXT record
/// carries enough for Studio to draw a useful device list — name, hardware
/// identifier, screen metrics — without connecting first.
@MainActor
final class ControlServer {
    private let queue = DispatchQueue(label: "com.fumberger.studiodevicekit.server")
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: PeerConnection] = [:]

    private let recorder: TakeRecorder
    private let store: TakeStore
    private let pairing: PairingStore

    private(set) var isRunning = false
    private(set) var lastError: String?

    init(recorder: TakeRecorder, store: TakeStore, pairing: PairingStore) {
        self.recorder = recorder
        self.store = store
        self.pairing = pairing
    }

    func start() {
        guard !isRunning else { return }
        let parameters = NWParameters.tcp
        // Peer-to-peer lets this work over AWDL when the Mac and the device
        // aren't on the same Wi-Fi — a common enough situation (guest networks,
        // client-isolated office APs) that it's worth the one line.
        parameters.includePeerToPeer = true

        do {
            // Port `.any`: Bonjour publishes whatever the system assigns, so
            // there is no fixed port to collide with anything.
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                type: SpringMotionProtocol.serviceType,
                txtRecord: txtRecord().data)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handle(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: queue)
            self.listener = listener
            isRunning = true
        } catch {
            lastError = error.localizedDescription
            print("[SpringMotionDeviceKit] could not start listener: \(error.localizedDescription)")
        }
    }

    func stop() {
        for peer in peers.values { peer.close() }
        peers.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// Republish with fresh metadata. The screen's size changes on rotation and
    /// Studio uses it to pick a device frame, so a stale TXT record means a
    /// landscape take landing in a portrait bezel.
    func refreshAdvertisement() {
        listener?.service = NWListener.Service(
            type: SpringMotionProtocol.serviceType,
            txtRecord: txtRecord().data)
    }

    private func txtRecord() -> NWTXTRecord {
        let screen = DeviceInfo.screen
        var txt = NWTXTRecord()
        txt[SpringMotionProtocol.TXT.deviceName] = UIDevice.current.name
        txt[SpringMotionProtocol.TXT.machine] = DeviceInfo.machine
        txt[SpringMotionProtocol.TXT.widthPoints] = String(Int(screen.width))
        txt[SpringMotionProtocol.TXT.heightPoints] = String(Int(screen.height))
        txt[SpringMotionProtocol.TXT.scale] = String(format: "%.1f", screen.scale)
        txt[SpringMotionProtocol.TXT.bundleID] = Bundle.main.bundleIdentifier ?? ""
        txt[SpringMotionProtocol.TXT.version] = SpringMotionProtocol.version
        return txt
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            lastError = error.localizedDescription
            // The overwhelmingly likely cause is a missing Info.plist key, and
            // the system's own error says nothing about that — so say it here.
            print("""
                [SpringMotionDeviceKit] listener failed: \(error.localizedDescription)
                \(DeviceInfo.configurationWarnings.joined(separator: "\n"))
                """)
            isRunning = false
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = PeerConnection(connection: connection,
                                  recorder: recorder,
                                  store: store,
                                  pairing: pairing)
        peers[ObjectIdentifier(peer)] = peer
        peer.onClose = { [weak self, weak peer] in
            guard let peer else { return }
            self?.peers.removeValue(forKey: ObjectIdentifier(peer))
        }
        peer.start(on: queue)
    }
}

/// One Mac's connection: framing in, responses out, one request at a time.
@MainActor
final class PeerConnection {
    private let connection: NWConnection
    private let recorder: TakeRecorder
    private let store: TakeStore
    private let pairing: PairingStore
    private var decoder = FrameDecoder()
    /// Set once this peer proves itself. Every request but `hello` and `pair`
    /// checks it.
    private var isTrusted = false
    private var isClosed = false

    var onClose: (() -> Void)?

    init(connection: NWConnection, recorder: TakeRecorder,
         store: TakeStore, pairing: PairingStore) {
        self.connection = connection
        self.recorder = recorder
        self.store = store
        self.pairing = pairing
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.close() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose?()
        onClose = nil
    }

    // MARK: Reading

    /// One receive outstanding at a time, re-armed only after the previous
    /// batch is fully handled — which is what keeps requests in order without
    /// any explicit sequencing.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    await self.ingest(data)
                }
                if isComplete || error != nil {
                    self.close()
                    return
                }
                self.receive()
            }
        }
    }

    private func ingest(_ data: Data) async {
        let outputs: [FrameDecoder.Output]
        do {
            outputs = try decoder.feed(data)
        } catch {
            // A bad length header means the stream is desynchronised or hostile;
            // there is no recovering a framed stream from that point.
            close()
            return
        }
        for output in outputs {
            guard case .message(let payload) = output else { continue }
            await handle(payload)
        }
    }

    private func handle(_ payload: Data) async {
        let request: SpringMotionRequest
        do {
            request = try SpringMotionRequest.decode(payload)
        } catch {
            await respond(.failure(.init(.internalError,
                                         "Unreadable request: \(error.localizedDescription)")))
            return
        }
        do {
            // nil = already answered on the wire (a blob writes its own header
            // and body). Sending a second framed message after a blob leaves an
            // unmatched response sitting in the reader's buffer.
            if let response = try await perform(request) {
                await respond(response)
            }
        } catch let failure as SpringMotionResponse.Failure {
            await respond(.failure(failure))
        } catch {
            await respond(.failure(.init(.internalError, error.localizedDescription)))
        }
    }

    /// Returns the response to send, or nil when the request answered itself
    /// (a blob fetch streams its own header and body).
    private func perform(_ request: SpringMotionRequest) async throws -> SpringMotionResponse? {
        switch request {
        case .hello(let token, _):
            if pairing.isTrusted(token) {
                isTrusted = true
                return .hello(helloInfo())
            }
            pairing.beginPairing()
            return .pairingRequired(codeLength: PairingStore.codeLength)

        case .pair(let code):
            let token = try pairing.redeem(code)
            isTrusted = true
            return .paired(token: token)

        case .startRecording(let options):
            try requireTrust()
            return .recordingStarted(takeID: try await recorder.start(options: options))

        case .stopRecording:
            try requireTrust()
            return .recordingStopped(try await recorder.stop())

        case .fetchTake(let id, let part):
            try requireTrust()
            guard store.exists(id) else {
                throw SpringMotionResponse.Failure(.unknownTake,
                                                   "No take with id \(id) on this device.")
            }
            switch part {
            case .touches:
                return .take(try store.loadTake(id))
            case .video:
                // Announced, then streamed — the response IS the header and the
                // bytes follow it directly on the wire, so there is nothing
                // further to send.
                try await sendVideo(for: id)
                return nil
            }

        case .deleteTake(let id):
            try requireTrust()
            store.delete(id)
            return .ok
        }
    }

    private func requireTrust() throws {
        guard isTrusted else {
            throw SpringMotionResponse.Failure(
                .notPaired, "This Mac is not paired with the device yet.")
        }
    }

    private func helloInfo() -> SpringMotionResponse.HelloInfo {
        SpringMotionResponse.HelloInfo(
            device: DeviceInfo.identity,
            screen: DeviceInfo.screen,
            isRecording: recorder.isRecording,
            pendingTakeIDs: store.pendingIDs,
            configurationWarnings: DeviceInfo.configurationWarnings)
    }

    // MARK: Writing

    private func respond(_ response: SpringMotionResponse) async {
        do {
            try await send(SpringMotionFraming.frame(response.encoded()))
        } catch {
            close()
        }
    }

    /// Announce the video's size, then stream the file in chunks.
    ///
    /// Read from disk rather than loaded whole: a few minutes of HEVC is tens
    /// of megabytes, and holding that in memory on a phone to send it is how
    /// you get jetsammed halfway through the transfer.
    private func sendVideo(for id: String) async throws {
        let url = store.videoURL(for: id)
        let bytes = store.videoBytes(for: id)
        guard bytes > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            throw SpringMotionResponse.Failure(.unknownTake,
                                               "The take's video is missing or empty.")
        }
        defer { try? handle.close() }

        let header = SpringMotionResponse.blob(.init(part: .video, bytes: bytes,
                                                     contentType: "video/quicktime"))
        try await send(SpringMotionFraming.frame(header.encoded()))

        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            // Raw, unframed: the announcement already said exactly how many
            // bytes follow, and the reader counts them off.
            try await send(chunk)
        }
    }

    /// Send, waiting for the connection to actually take the bytes. The await
    /// is the back-pressure — without it a fast disk read outruns a slow Wi-Fi
    /// link and the queued sends grow without bound.
    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}
#endif

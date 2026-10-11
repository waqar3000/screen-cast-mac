import Foundation
import Network

enum CastError: LocalizedError {
    case connectionFailed(String)
    case timedOut(String)
    case launchFailed(String)
    case streamRefused(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): "Couldn't connect to the TV: \(reason)"
        case .timedOut(let request): "The TV didn't answer in time (\(request))."
        case .launchFailed(let reason): "The TV couldn't start mirroring: \(reason)"
        case .streamRefused(let reason): "The TV refused the stream: \(reason)"
        case .disconnected: "Lost the connection to the TV."
        }
    }
}

/// Speaks the Cast V2 control protocol to one Chromecast: TLS on port 8009, carrying
/// length-prefixed `CastMessage` frames whose payloads are JSON.
///
/// All state lives on `queue`; callbacks are delivered on the main queue.
final class CastClient: @unchecked Sendable {  // state is confined to `queue`
    /// The screen-mirroring receiver that Chrome uses, built into every Chromecast.
    static let mirroringAppID = "0F5096E8"

    private enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let webrtc = "urn:x-cast:com.google.cast.webrtc"
    }

    /// The TV ended the session on its own (stopped from the remote, another phone cast, Wi-Fi dropped…).
    var onSessionEnded: ((_ reason: String) -> Void)?

    private let senderID = "sender-0"
    private let receiverID = "receiver-0"
    private let queue = DispatchQueue(label: "CastClient")
    private let connection: NWConnection
    private var readyContinuation: CheckedContinuation<String, Error>?
    private var waitingError: NWError?
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextRequestID = 1
    private var heartbeat: DispatchSourceTimer?
    private var transportID: String?
    private var sessionID: String?
    private var closed = false

    init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        // Chromecasts present a self-signed certificate, so there's no chain to verify.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        let parameters = NWParameters(tls: tls)
        // The media stream goes to the same address over UDP, so keep things on plain IPv4.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        connection = NWConnection(to: endpoint, using: parameters)
    }

    // MARK: - Public API

    /// Connects to the device and returns its IPv4 address.
    func connect() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                readyContinuation = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.connectionStateChanged(state) }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, readyContinuation != nil else { return }
                    fail(waitingError.map { CastError.connectionFailed($0.localizedDescription) } ?? CastError.timedOut("connect"))
                }
            }
        }
    }

    /// Starts a receiver app on the TV and joins its session.
    func launch(appID: String) async throws {
        let reply = try await request(Namespace.receiver, to: receiverID, ["type": "LAUNCH", "appId": appID], timeout: 20)
        let apps = (reply["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
        guard reply["type"] as? String == "RECEIVER_STATUS",
              let app = apps.first(where: { $0["appId"] as? String == appID }),
              let transport = app["transportId"] as? String,
              let session = app["sessionId"] as? String
        else {
            throw CastError.launchFailed(reply["reason"] as? String ?? "the app didn't start")
        }
        queue.sync {
            transportID = transport
            sessionID = session
            send(Namespace.connection, to: transport, ["type": "CONNECT"])
        }
    }

    /// Sends a Cast Streaming OFFER to the running mirroring app and returns the receiver's ANSWER body.
    func negotiate(offer: [String: Any]) async throws -> [String: Any] {
        guard let transport = queue.sync(execute: { transportID }) else { throw CastError.disconnected }
        let reply = try await request(Namespace.webrtc, to: transport, ["type": "OFFER", "offer": offer],
                                      idKey: "seqNum", timeout: 10)
        guard reply["type"] as? String == "ANSWER", reply["result"] as? String == "ok",
              let answer = reply["answer"] as? [String: Any] else {
            let error = reply["error"] as? [String: Any]
            throw CastError.streamRefused(error?["description"] as? String ?? "no usable answer")
        }
        return answer
    }

    /// Closes the app on the TV (back to its idle screen) and disconnects.
    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            var finished = false
            let finish = { [self] in
                guard !finished else { return }
                finished = true
                close(with: CastError.disconnected)
                if let completion { DispatchQueue.main.async(execute: completion) }
            }
            guard !closed, let sessionID else { return finish() }
            send(Namespace.receiver, to: receiverID,
                 ["type": "STOP", "sessionId": sessionID, "requestId": takeRequestID()], completion: finish)
            // Don't hang around if the TV has already gone quiet.
            queue.asyncAfter(deadline: .now() + 1, execute: finish)
        }
    }

    // MARK: - Connection

    private func connectionStateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(Namespace.connection, to: receiverID, ["type": "CONNECT"])
            startHeartbeat()
            receiveFrame()
            guard let continuation = readyContinuation else { return }
            readyContinuation = nil
            if let address = remoteIPv4Address() {
                continuation.resume(returning: address)
            } else {
                continuation.resume(throwing: CastError.connectionFailed("couldn't find the TV's network address"))
                close(with: CastError.disconnected)
            }
        case .waiting(let error) where readyContinuation != nil:
            // Still connecting (e.g. the Local Network prompt is up). The connect timeout reports this if it lasts.
            waitingError = error
        case .waiting(let error), .failed(let error):
            fail(CastError.connectionFailed(error.localizedDescription))
        default:
            break
        }
    }

    private func remoteIPv4Address() -> String? {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint,
              case .ipv4(let address) = host else { return nil }
        return address.rawValue.map(String.init).joined(separator: ".")
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            send(Namespace.heartbeat, to: receiverID, ["type": "PING"])
        }
        timer.resume()
        heartbeat = timer
    }

    private func fail(_ error: Error) {
        guard !closed else { return }
        let hadSession = sessionID != nil
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: error)
        }
        close(with: error)
        if hadSession { notifySessionEnded("Lost the connection to the TV.") }
    }

    private func close(with error: Error) {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        connection.cancel()
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        let waiting = pending
        pending = [:]
        waiting.values.forEach { $0.resume(throwing: error) }
    }

    private func notifySessionEnded(_ reason: String) {
        DispatchQueue.main.async { self.onSessionEnded?(reason) }
    }

    // MARK: - Messages

    private func takeRequestID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    /// Sends a message and waits for the reply that echoes its ID (`requestId`, or `seqNum` for streaming messages).
    private func request(_ namespace: String, to destination: String, _ payload: [String: Any],
                         idKey: String = "requestId", timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: CastError.disconnected) }
                let id = takeRequestID()
                pending[id] = continuation
                var body = payload
                body[idKey] = id
                send(namespace, to: destination, body)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.pending.removeValue(forKey: id)?
                        .resume(throwing: CastError.timedOut(payload["type"] as? String ?? "request"))
                }
            }
        }
    }

    private func send(_ namespace: String, to destination: String, _ payload: [String: Any],
                      completion: (() -> Void)? = nil) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: .withoutEscapingSlashes) else { return }
        let message = CastMessage(sourceID: senderID, destinationID: destination, namespace: namespace,
                                  payload: String(decoding: json, as: UTF8.self))
        let body = message.encoded()
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        if namespace != Namespace.heartbeat {
            Log.cast("→ \(destination) \(message.payload)")
        }
        connection.send(content: frame, completion: .contentProcessed { _ in completion?() })
    }

    private func receiveFrame() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, !closed else { return }
            guard let header, header.count == 4, error == nil else { return fail(CastError.disconnected) }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            guard length > 0, length <= 64 * 1024 else { return fail(CastError.disconnected) }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self, !closed else { return }
                guard let body, body.count == length, error == nil else { return fail(CastError.disconnected) }
                if let message = CastMessage(decoding: body) { handle(message) }
                receiveFrame()
            }
        }
    }

    private func handle(_ message: CastMessage) {
        if message.namespace != Namespace.heartbeat {
            Log.cast("← \(message.sourceID) \(message.payload)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(message.payload.utf8)) as? [String: Any],
              let type = json["type"] as? String else { return }
        let replyID = json["requestId"] as? Int ?? json["seqNum"] as? Int ?? 0

        switch (message.namespace, type) {
        case (Namespace.heartbeat, "PING"):
            send(Namespace.heartbeat, to: message.sourceID, ["type": "PONG"])

        case (Namespace.connection, "CLOSE") where message.sourceID == transportID:
            close(with: CastError.disconnected)
            notifySessionEnded("The TV closed the cast.")

        case (Namespace.receiver, "RECEIVER_STATUS") where replyID == 0:
            // Unprompted status: if our session is gone, someone stopped it from the TV or another device.
            let apps = (json["status"] as? [String: Any])?["applications"] as? [[String: Any]] ?? []
            if let sessionID, !apps.contains(where: { $0["sessionId"] as? String == sessionID }) {
                close(with: CastError.disconnected)
                notifySessionEnded("Casting was stopped from the TV.")
            }

        default:
            break
        }

        if replyID != 0, let continuation = pending.removeValue(forKey: replyID) {
            continuation.resume(returning: json)
        }
    }
}

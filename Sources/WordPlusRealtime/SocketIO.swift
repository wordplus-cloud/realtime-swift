import Foundation

/// One Socket.IO namespace on one Engine.IO connection, over the system's WebSocket (URLSessionWebSocketTask), as the
/// realtime servers speak it: Engine.IO 4's open, ping and pong, and Socket.IO 5's connect, events, acks and binary
/// attachments. Only the WebSocket transport, as every WordPlus client connects. Moves between nodes are the
/// connection's (Connection.swift): this socket goes to one address and stays there.
final class SocketIO: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Event {
        case connected
        case refused(String)
        case closed(String)
        case event(String, JSONValue)
    }

    let base: URL
    private let path: String
    private let namespace: String
    private let auth: JSONValue
    private let queue: DispatchQueue
    private let handler: (SocketIO, Event) -> Void

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var nextAck = 0
    private var acks: [Int: (JSONValue?) -> Void] = [:]
    private var pingTimer: DispatchWorkItem?
    private var pingWindow: TimeInterval = 45
    private var binary: (packet: [Any], type: Int, id: Int?, left: Int, buffers: [Data])?
    private(set) var isConnected = false
    private var ended = false

    /// `base` the server or a node (`https://ws-a.de.wordplus.cloud`), `auth` the namespace's handshake.
    init(base: URL, path: String, namespace: String, auth: JSONValue, queue: DispatchQueue, handler: @escaping (SocketIO, Event) -> Void) {
        self.base = base
        self.path = path
        self.namespace = namespace
        self.auth = auth
        self.queue = queue
        self.handler = handler
    }

    func open(timeout: TimeInterval) {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = (path.hasSuffix("/") ? path : path + "/")
        parts.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]

        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: delegateQueue)
        let task = session.webSocketTask(with: parts.url!)
        task.maximumMessageSize = 110_000_000
        self.session = session
        self.task = task
        task.resume()
        receive()

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.isConnected, !self.ended else { return }
            self.end("timeout")
        }
    }

    /// An event to the namespace; with `ack`, its answer (nil when the connection ended first, or after `timeout`).
    func emit(_ event: String, _ data: JSONValue, timeout: TimeInterval = 8, ack: ((JSONValue?) -> Void)? = nil) {
        queue.async { [self] in
            guard isConnected, !ended else {
                ack?(nil)
                return
            }
            var id: Int?
            if let ack {
                nextAck += 1
                let n = nextAck
                id = n
                acks[n] = ack
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let waiting = self.acks.removeValue(forKey: n) else { return }
                    waiting(nil)
                }
            }
            var buffers: [Data] = []
            let packed = SocketIO.deconstruct(JSONValue.array([.string(event), data]).socketAny(), &buffers)
            let json = (try? JSONSerialization.data(withJSONObject: packed, options: [.fragmentsAllowed])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let prefix = buffers.isEmpty ? "42" : "45" + String(buffers.count) + "-"
            send(prefix + namespacePart + (id.map(String.init) ?? "") + json)
            for buffer in buffers { task?.send(.data(buffer)) { _ in } }
        }
    }

    func emit(_ event: String, _ data: JSONValue, timeout: TimeInterval = 8) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            emit(event, data, timeout: timeout) { continuation.resume(returning: $0) }
        }
    }

    func close() {
        queue.async { [self] in
            if isConnected { send("41" + namespacePart) }
            end("io client disconnect", tell: false)
        }
    }

    private var namespacePart: String { namespace == "/" ? "" : namespace + "," }

    private func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                switch message {
                case let .string(text): self.packet(text)
                case let .data(data): self.attachment(data)
                @unknown default: break
                }
                if !self.ended { self.receive() }
            case .failure:
                self.end("transport close")
            }
        }
    }

    /// An Engine.IO packet: open, close, ping, or a Socket.IO packet inside a message.
    private func packet(_ text: String) {
        guard let type = text.first else { return }
        switch type {
        case "0":
            if let open = JSONValue.parse(String(text.dropFirst())) {
                pingWindow = ((open["pingInterval"]?.number ?? 25000) + (open["pingTimeout"]?.number ?? 20000)) / 1000
            }
            heard()
            send("40" + namespacePart + auth.jsonString())
        case "1": end("transport close")
        case "2":
            heard()
            send("3")
        case "4": socketPacket(String(text.dropFirst()))
        default: break
        }
    }

    /// A Socket.IO packet: `{type}[{attachments}-][{namespace},][{ack id}][json]`.
    private func socketPacket(_ text: String) {
        var rest = Substring(text)
        guard let typeChar = rest.first, let type = Int(String(typeChar)) else { return }
        rest = rest.dropFirst()
        var attachments = 0
        if type == 5 || type == 6, let dash = rest.firstIndex(of: "-") {
            attachments = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        if rest.hasPrefix("/") {
            let comma = rest.firstIndex(of: ",") ?? rest.endIndex
            guard rest[..<comma] == namespace else { return }
            rest = comma == rest.endIndex ? "" : rest[rest.index(after: comma)...]
        } else if namespace != "/" {
            return
        }
        var id: Int?
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty {
            id = Int(digits)
            rest = rest.dropFirst(digits.count)
        }
        let any = rest.isEmpty ? nil : try? JSONSerialization.jsonObject(with: Data(rest.utf8), options: [.fragmentsAllowed])

        switch type {
        case 0:
            isConnected = true
            heard()
            handler(self, .connected)
        case 1: end("io server disconnect")
        case 4:
            let message = (any as? [String: Any])?["message"] as? String ?? (any as? String) ?? "refused"
            end(message, refused: true)
        case 2, 3:
            deliver(type: type, id: id, any as? [Any] ?? [])
        case 5, 6:
            binary = (any as? [Any] ?? [], type == 5 ? 2 : 3, id, attachments, [])
            if attachments == 0 { attachment(nil) }
        default: break
        }
    }

    private func attachment(_ data: Data?) {
        guard var pending = binary else { return }
        if let data { pending.buffers.append(data) }
        pending.left -= data == nil ? 0 : 1
        binary = pending
        guard pending.left <= 0 else { return }
        binary = nil
        deliver(type: pending.type, id: pending.id, SocketIO.reconstruct(pending.packet, pending.buffers) as? [Any] ?? [])
    }

    private func deliver(type: Int, id: Int?, _ items: [Any]) {
        let values = items.map(JSONValue.init(any:))
        if type == 3 {
            guard let id, let ack = acks.removeValue(forKey: id) else { return }
            ack(values.first ?? .null)
            return
        }
        guard let name = values.first?.string else { return }
        handler(self, .event(name, values.count > 1 ? values[1] : .null))
    }

    /// The connection is alive: its ping is due again within the server's interval and timeout.
    private func heard() {
        pingTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.end("ping timeout") }
        pingTimer = timer
        queue.asyncAfter(deadline: .now() + pingWindow, execute: timer)
    }

    private func end(_ reason: String, refused: Bool = false, tell: Bool = true) {
        guard !ended else { return }
        ended = true
        let wasConnected = isConnected
        isConnected = false
        pingTimer?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        for (_, ack) in acks { ack(nil) }
        acks.removeAll()
        guard tell else { return }
        if refused { handler(self, .refused(reason)) } else if wasConnected { handler(self, .closed(reason)) } else { handler(self, .refused("connect_failed:" + reason)) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        end("transport close")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        end(error == nil ? "transport close" : "transport error")
    }

    /// Binary parts out of a packet, each replaced by its placeholder, as socket.io-parser's deconstructPacket.
    static func deconstruct(_ value: Any, _ buffers: inout [Data]) -> Any {
        if let data = value as? Data {
            buffers.append(data)
            return ["_placeholder": true, "num": buffers.count - 1]
        }
        if let array = value as? [Any] { return array.map { deconstruct($0, &buffers) } }
        if let object = value as? [String: Any] { return object.mapValues { deconstruct($0, &buffers) } }
        return value
    }

    static func reconstruct(_ value: Any, _ buffers: [Data]) -> Any {
        if let object = value as? [String: Any] {
            if object["_placeholder"] as? Bool == true, let n = object["num"] as? Int, buffers.indices.contains(n) { return buffers[n] }
            return object.mapValues { reconstruct($0, buffers) }
        }
        if let array = value as? [Any] { return array.map { reconstruct($0, buffers) } }
        return value
    }
}

extension JSONValue {
    /// For a Socket.IO packet: binary as Data, which the packet carries as an attachment.
    func socketAny() -> Any {
        switch self {
        case let .binary(d): return d
        case let .array(a): return a.map { $0.socketAny() }
        case let .object(o): return o.mapValues { $0.socketAny() }
        default: return any
        }
    }
}

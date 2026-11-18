import Foundation
import Network
@testable import WordPlusRealtime

/// A realtime node for the tests, on a port of this machine's loopback: Engine.IO 4's open and Socket.IO 5's connect,
/// events and acks over a WebSocket, as the realtime server speaks them, in whatever namespace a client opens. It keeps
/// each client's namespace, handshake and requests, answers every request with `answer`, and the test sends a client
/// events (`migrate` and `nodes` among them) or drops it.
final class FakeNode: @unchecked Sendable {
    /// One client's socket: the namespace and handshake it opened, and what it asked.
    final class Client: @unchecked Sendable {
        fileprivate let connection: NWConnection
        private unowned let node: FakeNode
        private let lock = NSLock()
        private var _namespace: String?
        private var _auth: JSONValue?
        private var _asked: [(event: String, data: JSONValue)] = []
        private var _closed = false

        fileprivate init(_ connection: NWConnection, node: FakeNode) {
            self.connection = connection
            self.node = node
        }

        var namespace: String? { lock.withLock { _namespace } }
        var auth: JSONValue? { lock.withLock { _auth } }
        var closed: Bool { lock.withLock { _closed } }
        var asked: [(event: String, data: JSONValue)] { lock.withLock { _asked } }

        func asked(_ event: String) -> [JSONValue] {
            asked.filter { $0.event == event }.map(\.data)
        }

        /// An event from the server, in the namespace this client opened.
        func emit(_ event: String, _ data: JSONValue) {
            send("42" + prefix + JSONValue.array([.string(event), data]).jsonString())
        }

        /// The connection gone, as a node that dies or a network that drops it.
        func drop() {
            connection.cancel()
        }

        private var prefix: String {
            let name = namespace ?? "/"
            return name == "/" ? "" : name + ","
        }

        fileprivate func opened() {
            send(#"0{"sid":"e1","upgrades":[],"pingInterval":25000,"pingTimeout":60000,"maxPayload":1000000}"#)
            receive()
        }

        fileprivate func ended() {
            lock.withLock { _closed = true }
        }

        fileprivate func send(_ text: String) {
            let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }

        private func receive() {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if let data, metadata?.opcode == .text, let text = String(data: data, encoding: .utf8) { self.heard(text) }
                if error == nil, data != nil, !self.closed { self.receive() }
            }
        }

        /// A packet from the client: `40` its connect with the handshake, `42` an event, `41` its disconnect.
        private func heard(_ text: String) {
            guard text.hasPrefix("4"), text.count >= 2 else { return }
            let type = text[text.index(after: text.startIndex)]
            var rest = Substring(text.dropFirst(2))
            var name = "/"
            if rest.hasPrefix("/") {
                let comma = rest.firstIndex(of: ",") ?? rest.endIndex
                name = String(rest[..<comma])
                rest = comma == rest.endIndex ? "" : rest[rest.index(after: comma)...]
            }
            switch type {
            case "0":
                lock.withLock {
                    _namespace = name
                    _auth = rest.isEmpty ? nil : JSONValue.parse(String(rest))
                }
                send("40" + prefix + #"{"sid":"n1"}"#)
                node.connected(self)
            case "2":
                let digits = rest.prefix { $0.isNumber }
                let id = Int(digits)
                let items = JSONValue.parse(String(rest.dropFirst(digits.count)))?.array ?? []
                guard let event = items.first?.string else { return }
                let data = items.count > 1 ? items[1] : .null
                lock.withLock { _asked.append((event, data)) }
                guard let id, let reply = node.answer(event, data) else { return }
                send("43" + prefix + String(id) + JSONValue.array([reply]).jsonString())
            case "1":
                ended()
            default:
                break
            }
        }
    }

    /// Where a client reaches this node: `http://127.0.0.1:<port>`.
    private(set) var url: URL!
    /// What each request is answered with, nil for no answer. `{ok: true}` unless the test says otherwise.
    var answer: (String, JSONValue) -> JSONValue? = { _, _ in ["ok": true] }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-node")
    private let lock = NSLock()
    private var _clients: [Client] = []

    init() throws {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw URLError(.cannotConnectToHost) }
        url = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        listener.cancel()
        lock.withLock { _clients }.forEach { $0.drop() }
    }

    /// The clients that opened a namespace here, in the order they did.
    var clients: [Client] { lock.withLock { _clients } }

    /// The `n`th client to open a namespace here (from 1), once it has; nil after `timeout`.
    func client(_ n: Int, timeout: TimeInterval = 5) -> Client? {
        let deadline = Date().addingTimeInterval(timeout)
        while clients.count < n, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        let all = clients
        return all.count >= n ? all[n - 1] : nil
    }

    private func accept(_ connection: NWConnection) {
        let client = Client(connection, node: self)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: client.opened()
            case .failed, .cancelled: client.ended()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    fileprivate func connected(_ client: Client) {
        lock.withLock { _clients.append(client) }
    }
}

/// Until `done` holds, or five seconds (or `timeout`) have gone.
func eventually(timeout: TimeInterval = 5, _ done: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !done(), Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
}

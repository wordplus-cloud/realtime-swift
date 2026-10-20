import Foundation

// What the SDK's other modules (WordPlusRealtimeCalls) reach of the connection, behind `@_spi(WordPlusModules)`: not
// part of the API an app uses. A module speaks on the same `/channels` socket as the rooms, with requests of its own
// (`call`, `line`, `invite` …), hears the events the rooms leave alone, and holds what it needs again on every socket
// before that socket takes over: after a drop, and at a move between nodes, make before break.

/// A socket the connection holds, or the one a move is about to switch to.
@_spi(WordPlusModules)
public struct ModuleSocket {
    let socket: SocketIO

    public var isConnected: Bool { socket.isConnected }

    /// An event to the socket; with `ack`, its answer (nil when the socket ended first, or after `timeout`).
    public func emit(_ event: String, _ payload: JSONValue, timeout: TimeInterval = 8, ack: ((JSONValue?) -> Void)? = nil) {
        socket.emit(event, payload, timeout: timeout, ack: ack)
    }
}

@_spi(WordPlusModules)
extension JSONValue {
    /// From what JSONSerialization parses, as a module's dictionaries hold it.
    public static func from(any: Any) -> JSONValue { JSONValue(any: any) }

    /// For JSONSerialization and the dictionaries a module holds; binary as `{ "$b": base64 }`.
    public var anyValue: Any { any }
}

@_spi(WordPlusModules)
extension Realtime {
    /// The queue the connection runs on; everything a module hears comes on it.
    public var moduleQueue: DispatchQueue { queue }

    /// Where an app wants its handlers called.
    public var callbackQueue: DispatchQueue { options.callbackQueue }

    /// The realtime server the app connects to (`https://ws.wordplus.cloud`), whose cloud a live stream joins.
    public var serverURL: URL { options.server }

    /// The socket the connection holds now, when it is connected. On the module queue.
    public var currentSocket: ModuleSocket? {
        guard let socket = socketForEmit(), socket.isConnected else { return nil }
        return ModuleSocket(socket: socket)
    }

    /// The events of `name` the connection doesn't handle itself, on the module queue.
    public func onSocketEvent(_ name: String, _ handler: @escaping (JSONValue) -> Void) {
        queue.async { [self] in moduleEvents[name, default: []].append(handler) }
    }

    /// A step of holding a socket before it takes over: at a connect, after a drop, at a move. `done` when it is held.
    public func addHold(_ step: @escaping (ModuleSocket, @escaping () -> Void) -> Void) {
        queue.async { [self] in moduleHolds.append(step) }
    }

    /// The keys a value needs that the keyring lacks, asked for on the app's keys route; `done` on the module queue.
    public func ensureKeys(for value: JSONValue, _ done: @escaping () -> Void) {
        queue.async { [self] in inOrder([value], done) }
    }
}

/// A namespace on a connection of its own, for a module whose server speaks on one: a live stream's chat
/// (`/estream`, Easy Stream's protocol). It goes to one address and stays there; the module opens it again after a drop.
/// Its events come on its own queue.
@_spi(WordPlusModules)
public final class NamespaceSocket: @unchecked Sendable {
    public enum Event {
        case connected
        case refused(String)
        case closed(String)
        case event(String, JSONValue)
    }

    private let queue = DispatchQueue(label: "cloud.wordplus.realtime.namespace")
    private var socket: SocketIO?

    /// `base` the server (`https://ws.wordplus.cloud`), `path` its socket path, `auth` the namespace's handshake.
    public init(base: URL, path: String, namespace: String, auth: JSONValue, handler: @escaping (Event) -> Void) {
        socket = SocketIO(base: base, path: path, namespace: namespace, auth: auth, queue: queue) { _, event in
            switch event {
            case .connected: handler(.connected)
            case let .refused(reason): handler(.refused(reason))
            case let .closed(reason): handler(.closed(reason))
            case let .event(name, data): handler(.event(name, data))
            }
        }
    }

    public func open(timeout: TimeInterval = 10) {
        queue.async { [self] in socket?.open(timeout: timeout) }
    }

    /// An event to the namespace, and its answer: nil when the socket ended first, or after `timeout`.
    public func emit(_ event: String, _ payload: JSONValue, timeout: TimeInterval = 8) async -> JSONValue? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let socket else { return continuation.resume(returning: nil) }
                socket.emit(event, payload, timeout: timeout) { continuation.resume(returning: $0) }
            }
        }
    }

    /// An event that wants no answer.
    public func send(_ event: String, _ payload: JSONValue) {
        queue.async { [self] in socket?.emit(event, payload) }
    }

    public func close() {
        queue.async { [self] in
            socket?.close()
            socket = nil
        }
    }
}

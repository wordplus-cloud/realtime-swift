import Foundation

/// A handler of a call, a group call or a ring that can be taken off again (`off`).
public struct CallListener: Hashable, Sendable {
    let id = UUID()
}

/// The handlers of one event, in the order they came. On the main queue, where the calls live.
struct CallHandlers<Value> {
    private var list: [(listener: CallListener, fn: (Value) -> Void)] = []

    @discardableResult
    mutating func add(_ fn: @escaping (Value) -> Void, as listener: CallListener = CallListener()) -> CallListener {
        list.append((listener, fn))
        return listener
    }

    mutating func remove(_ listener: CallListener) {
        list.removeAll { $0.listener == listener }
    }

    /// Each handler as it was when fired: one may take itself or another off.
    func fire(_ value: Value) {
        list.forEach { $0.fn(value) }
    }
}

extension CallHandlers where Value == Void {
    func fire() { fire(()) }
}

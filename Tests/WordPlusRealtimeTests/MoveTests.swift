import Foundation
import XCTest
@testable import WordPlusRealtime

/// A move between nodes: `node test/native/serve.mjs` runs two realtime nodes and drains
/// the first on POST /drain to its control port (WORDPLUS_CONTROL). The client knows the first from its node cache and
/// has the second as its realtime server: as the local nodes have plain-HTTP names, which the server lists to nobody, a
/// drain moves its clients to their server, as the fleet's do when no other node is ready. The client moves, its rooms
/// joined there before the switch, and nothing the app's server sends meanwhile is lost. It runs after LiveTests, as the
/// first node is gone afterwards.
final class MoveTests: XCTestCase {
    func testMovesToAnotherNodeWhenItsNodeDrainsLosingNothing() async throws {
        guard let shopValue = ProcessInfo.processInfo.environment["WORDPLUS_SHOP"], let base = URL(string: shopValue),
              let controlValue = ProcessInfo.processInfo.environment["WORDPLUS_CONTROL"], let control = URL(string: controlValue) else {
            throw XCTSkip("WORDPLUS_SHOP and WORDPLUS_CONTROL are not set: run `node test/native/serve.mjs` in realtime-js")
        }

        let (listing, _) = try await URLSession.shared.data(from: control)
        let nodes = try XCTUnwrap(JSONValue.parse(String(decoding: listing, as: UTF8.self))?["nodes"]?.array).compactMap(\.string)
        XCTAssertEqual(nodes.count, 2)
        let first = try XCTUnwrap(nodes.first), second = try XCTUnwrap(URL(string: nodes[1]))

        func signIn(_ person: Int) async throws -> (Realtime, String) {
            var request = URLRequest(url: base.appendingPathComponent("api/token"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{\"as\":\(person)}".utf8)
            let (data, _) = try await URLSession.shared.data(for: request)
            let answer = try XCTUnwrap(JSONValue.parse(String(decoding: data, as: UTF8.self)))
            let token = try XCTUnwrap(answer["token"]?.string)
            var options = RealtimeOptions(config: try XCTUnwrap(answer["realtime"]), base: base, headers: { ["Authorization": "Bearer " + token] }, callbackQueue: DispatchQueue(label: "move-\(person)"))
            options.server = second
            let store = MemoryNodeStore()
            store.save(server: second, NodeCache(nodes: [CachedNode(url: first, until: Date().timeIntervalSince1970 + 3600)]))
            options.nodeStore = store
            let rt = Realtime(options)
            rt.connect()
            return (rt, token)
        }

        let (ben, _) = try await signIn(42)
        let (ann, annToken) = try await signIn(34)
        defer { ben.close(); ann.close() }

        let order = ben.rt_join("order:1042")
        let bens = ben.rt_join("chat:34:42"), anns = ann.rt_join("chat:34:42")
        try await order.ready()
        try await bens.ready()
        try await anns.ready()

        let moved = expectation(description: "both moved")
        moved.expectedFulfillmentCount = 2
        ben.on("moved") { _, _ in moved.fulfill() }
        ann.on("moved") { _, _ in moved.fulfill() }

        let heard = LockedList()
        order.on("updated") { data, _ in heard.append(data["status"]?.string ?? "") }

        // The app's server keeps sending while the node drains.
        var drain = URLRequest(url: control.appendingPathComponent("drain"))
        drain.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: drain)

        let sent = ["packed", "shipped", "delivered", "placed", "packed"]
        for status in sent {
            var request = URLRequest(url: base.appendingPathComponent("orders/1042/status"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + annToken, forHTTPHeaderField: "Authorization")
            request.httpBody = Data("{\"status\":\"\(status)\"}".utf8)
            _ = try await URLSession.shared.data(for: request)
            try await Task.sleep(nanoseconds: 600_000_000)
        }

        await fulfillment(of: [moved], timeout: 20)

        // Every update, once each, in order: from the first node, or from the second's history at the join there.
        let deadline = Date().addingTimeInterval(5)
        while heard.items.count < sent.count, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(heard.items, sent)

        // On the second node now, a message goes across as before.
        let text = "After the move"
        let got = expectation(description: "message")
        bens.on("message") { data, _ in if data["text"]?.string == text { got.fulfill() } }
        _ = try await anns.emitWithAck("message", ["from": 34, "text": .string(text)])
        await fulfillment(of: [got], timeout: 8)
        XCTAssertEqual(bens.state, .joined)
    }
}

final class LockedList: @unchecked Sendable {
    private var stored: [String] = []
    private let lock = NSLock()

    var items: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ item: String) {
        lock.lock()
        stored.append(item)
        lock.unlock()
    }
}

extension Realtime {
    /// `join`, named apart for the test's readability.
    func rt_join(_ name: String) -> Room { join(name) }
}

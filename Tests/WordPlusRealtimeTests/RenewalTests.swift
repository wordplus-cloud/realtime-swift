import Foundation
import XCTest
@testable import WordPlusRealtime

/// The app's routes as a test answers them: what each route was asked, and the answer of each ask. `URLSession.shared`
/// carries the routes, so a protocol registered for the shared session stands in for the app's server.
final class FakeRoutes: URLProtocol {
    private static let lock = NSLock()
    private static var _asked: [(route: String, body: JSONValue)] = []
    private static var answers: [String: (Int) -> String] = [:]

    static func answer(_ route: String, _ make: @escaping (Int) -> String) { lock.withLock { answers[route] = make } }
    static var asked: [(route: String, body: JSONValue)] { lock.withLock { _asked } }
    static func asked(_ route: String) -> [JSONValue] { asked.filter { $0.route == route }.map(\.body) }
    static func reset() { lock.withLock { _asked = []; answers = [:] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "routes.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var bytes = request.httpBody
        if bytes == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(chunk, maxLength: 4096)
                if read <= 0 { break }
                data.append(chunk, count: read)
            }
            chunk.deallocate()
            stream.close()
            bytes = data
        }
        let route = request.url?.lastPathComponent ?? ""
        let body = bytes.flatMap { String(data: $0, encoding: .utf8) }.flatMap(JSONValue.parse) ?? .null
        let text: String = FakeRoutes.lock.withLock {
            FakeRoutes._asked.append((route, body))
            let times = FakeRoutes._asked.filter { $0.route == route }.count
            return FakeRoutes.answers[route]?(times) ?? "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Tokens asked for again before they run out, as the browser's rooms() asks them (realtime-client rooms.ts,
/// scheduleRenewal and scheduleIdentity): the held rooms' in one request to the auth route, ten minutes before the first
/// runs out, and again after each answer, and the identity of the keys route the same. A stand-in for the app's server
/// answers, and the renewals are hurried along.
final class RenewalTests: XCTestCase {
    private var rt: Realtime!

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(FakeRoutes.self)
        FakeRoutes.reset()
        Realtime.renewFloor = 0.2
        // Good for ten minutes and a third of a second: due again a third of a second after each answer.
        FakeRoutes.answer("auth") { times in #"{"token":"t\#(times)","exp":\#(Date().timeIntervalSince1970 + 600.3)}"# }
        rt = Realtime(RealtimeOptions(app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!))
    }

    override func tearDown() {
        rt.close()
        Realtime.renewFloor = 30
        URLProtocol.unregisterClass(FakeRoutes.self)
        super.tearDown()
    }

    private func wait(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done(), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    private func rooms(_ body: JSONValue) -> [String] { (body["rooms"]?.array?.compactMap(\.string) ?? []).sorted() }

    func testTheHeldRoomsTokensAreAskedForAgainBeforeTheyRunOutInOneRequest() {
        _ = rt.join("order:1")
        _ = rt.join("chat:34:42")
        rt.queue.async { [rt] in ["order:1", "chat:34:42"].forEach { rt!.tokenFor($0) { _ in } } }

        wait { FakeRoutes.asked("auth").count >= 3 }

        // The first ask, then the renewals, each asking for both rooms at once.
        let asked = FakeRoutes.asked("auth")
        XCTAssertGreaterThanOrEqual(asked.count, 3, "the auth route was asked \(asked.count) times")
        asked.forEach { XCTAssertEqual(rooms($0), ["chat:34:42", "order:1"]) }
    }

    func testARoomLeftIsNotAskedForAgain() {
        _ = rt.join("order:1")
        _ = rt.join("chat:34:42")
        rt.queue.async { [rt] in ["order:1", "chat:34:42"].forEach { rt!.tokenFor($0) { _ in } } }
        wait { !FakeRoutes.asked("auth").isEmpty }
        rt.leave("chat:34:42")

        wait { FakeRoutes.asked("auth").count >= 3 }
        let asked = FakeRoutes.asked("auth")
        XCTAssertGreaterThanOrEqual(asked.count, 3, "the auth route was asked \(asked.count) times")
        XCTAssertEqual(asked.last.map(rooms), ["order:1"])
    }

    private func signedIn(exp: Double) -> Realtime {
        // A new identity good for ten minutes and a third of a second each time the keys route is asked.
        FakeRoutes.answer("keys") { times in #"{"identity":{"token":"i\#(times)","exp":\#(Date().timeIntervalSince1970 + 600.3)}}"# }
        return Realtime(RealtimeOptions(app: "s1", endpoint: URL(string: "https://routes.test/api/realtime")!, identity: Identity(token: "i0", exp: exp)))
    }

    func testTheIdentityIsAskedForAgainBeforeItRunsOutAndAfterEachAnswer() {
        let app = signedIn(exp: Date().timeIntervalSince1970 + 600.3)
        defer { app.close() }
        wait { FakeRoutes.asked("keys").count >= 2 }
        XCTAssertGreaterThanOrEqual(FakeRoutes.asked("keys").count, 2, "the keys route was asked \(FakeRoutes.asked("keys").count) times")
    }

    func testAnIdentityWithNoEndIsLeftAndAClosedAppAsksNoMore() {
        let noEnd = signedIn(exp: 0)
        Thread.sleep(forTimeInterval: 0.6)
        noEnd.close()
        XCTAssertEqual(FakeRoutes.asked("keys").count, 0, "an identity with no end was asked for")

        let closing = signedIn(exp: Date().timeIntervalSince1970 + 600.3)
        closing.close()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(FakeRoutes.asked("keys").count, 0, "a closed app asked for its identity")
    }
}

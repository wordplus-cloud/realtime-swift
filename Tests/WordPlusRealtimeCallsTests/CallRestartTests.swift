import XCTest
@testable import WordPlusRealtimeCalls

/// How the engine tells the other side's ICE restart from any other offer (CallPeer.iceUfrag), the same rule as the
/// realtime client's calls/peer.ts: before a first connection a restart the other side made is this side's attempt too,
/// so its own connect clock does not restart over it. A callee whose caller heard the relay five seconds late (30 Oct
/// 2026) and a caller that restarted on its own clock abandoned each other's checks until the call went to the room.
final class CallRestartTests: XCTestCase {
    private func offer(ufrag: String) -> String {
        "v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0 1\r\n"
            + "m=video 9 UDP/TLS/RTP/SAVPF 96\r\nc=IN IP4 0.0.0.0\r\na=ice-ufrag:\(ufrag)\r\na=ice-pwd:p\r\na=mid:0\r\n"
            + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=ice-ufrag:\(ufrag)\r\na=ice-pwd:p\r\na=mid:1\r\n"
    }

    func testTheFirstSectionsUfragIsRead() {
        XCTAssertEqual(CallPeer.iceUfrag(offer(ufrag: "Ab3d")), "Ab3d")
        XCTAssertEqual(CallPeer.iceUfrag("a=ice-ufrag:x\nm=audio 9\n"), "x")
    }

    func testARestartChangesItAndARenegotiationDoesNot() {
        let held = CallPeer.iceUfrag(offer(ufrag: "Ab3d"))

        XCTAssertNotEqual(CallPeer.iceUfrag(offer(ufrag: "Zz90")), held)
        XCTAssertEqual(CallPeer.iceUfrag(offer(ufrag: "Ab3d")), held)
    }

    func testADescriptionWithoutOneHasNone() {
        XCTAssertNil(CallPeer.iceUfrag("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"))
        XCTAssertNil(CallPeer.iceUfrag("a=ice-ufrag:\r\n"))
    }
}

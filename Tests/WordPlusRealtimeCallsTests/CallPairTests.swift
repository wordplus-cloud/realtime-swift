import XCTest
@testable import WordPlusRealtimeCalls

/// Which candidate pair a stats report says the connection is using (CallPair), as the direct call's report, round trip
/// and bandwidth estimates read it, the same rule as the realtime client's calls/pair.ts. A
/// Firefox side of a call on 2026-10-26 reported "relay, relay, udp" and a 1.616 s round trip for the whole call while it
/// ran srflx to srflx: the relay pair that won the first checks stayed nominated, and the last nominated pair won.
final class CallPairTests: XCTestCase {
    private typealias Entry = CallPair.Entry

    private let candidates = [
        Entry(id: "Lr", type: "local-candidate", values: ["candidateType": "relay", "protocol": "udp", "relayProtocol": "udp"]),
        Entry(id: "Rr", type: "remote-candidate", values: ["candidateType": "relay", "protocol": "udp"]),
        Entry(id: "Ls", type: "local-candidate", values: ["candidateType": "srflx", "protocol": "udp"]),
        Entry(id: "Rs", type: "remote-candidate", values: ["candidateType": "srflx", "protocol": "udp"])
    ]

    /// The relay pair that won the first checks, nominated and left there.
    private func stale(_ more: [String: Any] = [:]) -> Entry {
        Entry(id: "Prelay", type: "candidate-pair", values: [
            "state": "succeeded", "nominated": NSNumber(value: true), "localCandidateId": "Lr", "remoteCandidateId": "Rr",
            "currentRoundTripTime": NSNumber(value: 1.616), "lastPacketReceivedTimestamp": NSNumber(value: 1_000), "bytesReceived": NSNumber(value: 2_000)
        ].merging(more) { $1 })
    }

    /// The pair the call runs on.
    private func direct(_ more: [String: Any] = [:]) -> Entry {
        Entry(id: "Pdirect", type: "candidate-pair", values: [
            "state": "succeeded", "nominated": NSNumber(value: true), "localCandidateId": "Ls", "remoteCandidateId": "Rs",
            "currentRoundTripTime": NSNumber(value: 0.054), "lastPacketReceivedTimestamp": NSNumber(value: 90_000), "bytesReceived": NSNumber(value: 3_600_000)
        ].merging(more) { $1 })
    }

    func testTheTransportsPairWinsInAnyOrder() {
        let transport = Entry(id: "T1", type: "transport", values: ["selectedCandidatePairId": "Pdirect"])
        // its stale pair heard last and moved more, so only the transport's word picks the other
        let louder = stale(["lastPacketReceivedTimestamp": NSNumber(value: 99_000), "bytesReceived": NSNumber(value: 9_000_000)])

        XCTAssertEqual(CallPair.selected(candidates + [transport, direct(), louder]), "Pdirect")
        XCTAssertEqual(CallPair.selected(candidates + [louder, direct(), transport]), "Pdirect")
    }

    func testAPairMarkedSelectedWinsOverOneOnlyOnceNominated() {
        let marked = direct(["selected": NSNumber(value: true)])
        let unmarked = stale(["selected": NSNumber(value: false), "lastPacketReceivedTimestamp": NSNumber(value: 99_000)])

        XCTAssertEqual(CallPair.selected(candidates + [marked, unmarked]), "Pdirect")
        XCTAssertEqual(CallPair.selected(candidates + [unmarked, marked]), "Pdirect")
    }

    func testWithNothingElseTheNominatedPairThatHeardLastWins() {
        XCTAssertEqual(CallPair.selected(candidates + [direct(), stale()]), "Pdirect")
        XCTAssertEqual(CallPair.selected(candidates + [stale(), direct()]), "Pdirect")

        // without timestamps, the one that took in the most
        let quiet: [String: Any] = ["lastPacketReceivedTimestamp": NSNull()]

        XCTAssertEqual(CallPair.selected(candidates + [direct(quiet), stale(quiet)]), "Pdirect")
        XCTAssertEqual(CallPair.selected(candidates + [stale(quiet), direct(quiet)]), "Pdirect")
    }

    func testNoPairBeforeOneIsChosen() {
        let checking = [
            Entry(id: "T1", type: "transport", values: [:]),
            direct(["state": "in-progress"]),
            stale(["nominated": NSNumber(value: false)])
        ]

        XCTAssertNil(CallPair.selected(candidates + checking))
        XCTAssertNil(CallPair.selected([]))
    }
}

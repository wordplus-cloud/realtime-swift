import Foundation

/// The candidate pair a peer connection is using, of one stats report's, as
/// the web's call engine reads it.
///
/// The transport's own word first: its `selectedCandidatePairId`, which
/// WebRTC gives once it has chosen. A pair marked `selected` next, as a
/// browser marks it where it has no transport entry (Firefox). `nominated`
/// says the least, since a pair stays nominated after the connection moves
/// off it: Firefox's side of a call that ran direct reported the relay pair
/// that won the first checks, and that pair's round trip frozen at 1.6 s, for
/// the whole call, because whichever nominated pair the report listed last
/// won — and a report's order here is a dictionary's, none at all. So a
/// nominated pair counts only where neither of the others says anything, and
/// then the one that heard from the other side last.
enum CallPair {
    struct Entry {
        let id: String
        let type: String
        let values: [String: Any]
    }

    /// The pair's id, nil before there is one.
    static func selected(_ entries: [Entry]) -> String? {
        var transport: String?
        var pairs: [Entry] = []

        for entry in entries {
            if entry.type == "transport" {
                if transport == nil, let id = entry.values["selectedCandidatePairId"] as? String { transport = id }
            } else if entry.type == "candidate-pair" {
                pairs.append(entry)
            }
        }

        if let id = transport, pairs.contains(where: { $0.id == id }) { return id }

        if let marked = pairs.first(where: { flag($0.values["selected"]) }) { return marked.id }

        var best: Entry?

        for pair in pairs where pair.values["state"] as? String == "succeeded" && flag(pair.values["nominated"]) {
            guard let current = best else {
                best = pair
                continue
            }

            let heard = number(pair.values["lastPacketReceivedTimestamp"])
            let heardBest = number(current.values["lastPacketReceivedTimestamp"])

            if heard > heardBest || (heard == heardBest && number(pair.values["bytesReceived"]) > number(current.values["bytesReceived"])) {
                best = pair
            }
        }

        return best?.id
    }

    private static func flag(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func number(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }
}

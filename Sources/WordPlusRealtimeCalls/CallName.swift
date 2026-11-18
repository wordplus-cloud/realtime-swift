import Foundation

/// A call's name for this app's user and another, from a template, as the call buttons of the web take it: `{pair}` the two
/// ids in order, `{me}`, `{id}`. Both people so name the same call, whichever calls. A name with none of them is as it
/// is. @wordplus/realtime-client's sdk-calls/call-name.ts, rule for rule.
enum CallName {
    /// Throws `no_identity` where it needs this app's user and the app's server named none.
    static func named(_ template: String, me: String?, id: String) throws -> String {
        guard template.contains("{") else { return template }
        if me == nil, template.contains("{pair}") || template.contains("{me}") { throw CallError("no_identity") }
        let own = me ?? ""
        let pair = pairOf(own, id).joined(separator: ":")
        return template
            .replacingOccurrences(of: "{pair}", with: pair)
            .replacingOccurrences(of: "{me}", with: own)
            .replacingOccurrences(of: "{id}", with: id)
    }

    /// The two ids in order, the smaller first: as numbers when both are whole numbers (9 before 10, as an app's server
    /// sorts them), else as text, so both people name the same call either way round.
    private static func pairOf(_ one: String, _ other: String) -> [String] {
        let digits = { (id: String) in !id.isEmpty && id.allSatisfy { $0.isASCII && $0.isNumber } }
        let first = digits(one) && digits(other) ? compareNumbers(one, other) <= 0 : bytesAtMost(one, other)
        return first ? [one, other] : [other, one]
    }

    /// Text in the order of its characters' codes, as the browser's `<=` compares it, never by this device's language.
    private static func bytesAtMost(_ one: String, _ other: String) -> Bool {
        !other.utf16.lexicographicallyPrecedes(one.utf16)
    }

    /// Whole numbers of any length compared exactly, without parsing past what a number holds.
    private static func compareNumbers(_ one: String, _ other: String) -> Int {
        let a = stripped(one), b = stripped(other)
        if a.count != b.count { return a.count - b.count }
        return a == b ? 0 : (a < b ? -1 : 1)
    }

    private static func stripped(_ id: String) -> String {
        let kept = id.drop { $0 == "0" }
        return kept.isEmpty ? "0" : String(kept)
    }
}

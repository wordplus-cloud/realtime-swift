import Foundation
@_spi(WordPlusModules) import WordPlusRealtime

// The tokens an app's own server gives it to start with: its own route checks whatever it needs, makes one (`callToken()`,
// `groupCallToken()` and `streamToken()` in the server packages), and the app passes it on, so whether someone may call or
// join is the app's own logic. To the app each is a string. Inside it is base64url of JSON: the token for the realtime
// server, and what this side keeps to itself. @wordplus/realtime-client's sdk-calls/calls.ts, rule for rule (openToken(),
// openCallToken(), refOf()), so a phone and a browser read the same tokens.

/// A token from `callToken()`, read: a call to start, or with `group` a ring into a call that goes on as a group call.
struct MadeCall {
    let token: String
    let call: String
    let id: String
    /// Who it rings.
    let to: String
    let type: CallType
    /// The call's two people, its caller first, in the SDK's spelling. A ring's are those of the call it rings into, so
    /// its first needn't be who rings.
    let pair: [String]
    /// This user's proof of being in the call, which a new token through the calls route takes.
    let member: String
    /// The call it rings into, for a ring. Nil for a call of its own.
    let group: String?
    /// The proof the person was rung, which the realtime server hands them with a ring into a group call.
    let ring: String?
    /// All of it as the calls route would have answered, which a `Call` is made from.
    let grant: [String: Any]
}

/// What a token of the app's server gave this app to host a group call, to record it, or to raise a hand in it (`member`,
/// everyone's): each `{ until, proof }`, which the calls route checks, as the call may outlast the token. Nil where the
/// token gave none.
struct GroupProofs {
    let host: JSONValue?
    let recorder: JSONValue?
    var member: JSONValue? = nil
}

/// A token from `groupCallToken()`, read.
struct MadeGroupCall {
    let token: String
    let room: String
    let type: CallType
    /// Who it was made for, nil when it names nobody a call can have.
    let user: String?
    let mediaKey: String?
    let proofs: GroupProofs
    /// The acts the app's package takes (`CallAct`), nil from a package before them, which offers today's five.
    var acts: [String]? = nil
}

/// A token from `streamToken()`, read.
struct MadeStream {
    let token: String
    let name: String
}

enum CallTokens {
    /// What a token holds, or nil for anything that isn't one: base64url of a JSON object, and nothing else.
    static func open(_ token: String) -> JSONValue? {
        let isBase64URL = !token.isEmpty && token.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) || byte == 0x2d || byte == 0x5f
        }
        guard isBase64URL else { return nil }
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard
            let data = Data(base64Encoded: base64),
            let text = String(data: data, encoding: .utf8),
            let value = JSONValue.parse(text), value.object != nil
        else { return nil }
        return value
    }

    /// A call's token, or nil for anything else, a user id among them: what tells one from the other in `add`.
    static func call(_ token: String) -> MadeCall? {
        guard
            let value = open(token), var fields = value.object,
            let inner = value["token"]?.string,
            let call = value["call"]?.string,
            let id = value["id"]?.string,
            let member = value["member"]?.string,
            let to = RealtimeCalls.user(value["to"]),
            let two = value["pair"]?.array, two.count == 2
        else { return nil }
        let pair = two.compactMap { RealtimeCalls.user($0) }
        guard pair.count == 2 else { return nil }

        // One spelling for each user, as the calls route answers them.
        fields["pair"] = JSONValue.from(any: pair.map(RealtimeCalls.userValue))
        return MadeCall(
            token: inner,
            call: call,
            id: id,
            to: to,
            type: type(value["type"]),
            pair: pair,
            member: member,
            group: value["group"]?.string,
            ring: value["ring"]?.string,
            grant: JSONValue.object(fields).anyValue as? [String: Any] ?? [:]
        )
    }

    /// A group call's token, or nil for anything else.
    static func groupCall(_ token: String) -> MadeGroupCall? {
        guard let value = open(token), let inner = value["token"]?.string, let room = value["room"]?.string else { return nil }
        return MadeGroupCall(
            token: inner,
            room: room,
            type: type(value["type"]),
            user: RealtimeCalls.user(value["user"]),
            mediaKey: value["media_key"]?.string,
            proofs: GroupProofs(host: proof(value["host"]), recorder: proof(value["recorder"]), member: proof(value["member"])),
            acts: CallAct.names(value["acts"])
        )
    }

    /// A live stream's token, or nil for anything else.
    static func stream(_ token: String) -> MadeStream? {
        guard let value = open(token), let inner = value["token"]?.string, let name = value["name"]?.string else { return nil }
        return MadeStream(token: inner, name: name)
    }

    /// What the app sends its route to ring someone into a call: base64url of the call, and the proof that this user is
    /// in it. The route gives it to `callToken( user, to, { into: ref } )`, which checks the proof.
    static func ref(of link: GroupOf) -> String {
        var fields: [String: JSONValue] = ["id": .string(link.id), "name": .string(link.name), "type": .string(link.type.rawValue)]
        if let pair = link.pair { fields["pair"] = JSONValue.from(any: pair) }
        if let member = link.member { fields["member"] = .string(member) }
        let json = (try? JSONValue.object(fields).encoded()) ?? Data()
        return json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func type(_ value: JSONValue?) -> CallType {
        value?.string == "audio" ? .audio : .video
    }

    private static func proof(_ value: JSONValue?) -> JSONValue? {
        value?.object == nil ? nil : value
    }
}

import XCTest
@testable @_spi(WordPlusModules) import WordPlusRealtime
@testable import WordPlusRealtimeCalls

/// Tokens from the server package's own source (@wordplus/realtime's `callToken()`, `groupCallToken()` and `streamToken()`,
/// made on 2026-11-09), with throwaway keys, so what these tests read is what a server makes. Their time never matters
/// here: the client doesn't read it, the realtime server does.
private enum Made {
    static let call = "eyJ0b2tlbiI6ImV5SmhiR2NpT2lKSVV6STFOaUlzSW5SNWNDSTZJa3BYVkNKOS5leUpwYzNNaU9pSnpNVFV3TURBd09UazVPU0lzSW1saGRDSTZNVGM1TkRJeE1EWXdOQ3dpWlhod0lqb3hOemswTWpNeU1qQTBMQ0poZFdRaU9pSjNiM0prY0d4MWN5MXlaV0ZzZEdsdFpTQmpZV3hzSWl3aVkyRnNiQ0k2SW5OMWNIQnZjblE2TVRjaUxDSnBaQ0k2SW1SSWIyUmhlV0ZuVG5Cck5YcGpZMUF0TjBSWUlpd2ljM1ZpSWpvME1pd2ljbTlzWlNJNkltTmhiR3hsY2lJc0luUjVjR1VpT2lKaGRXUnBieUlzSW5Sdklqb3pOQ3dpYVc1bWJ5STZJbVE2TWpBM05qWTZNUzVtVlVOME9UWjRkemRUTkdwMllUWnVaVUZXUVhoRWIxbHNWV2d3VW1aZlFXbGtNRmxLU2taV01tbFlMWGR1WTNwM04zSXdSeTFEUzA5Q04xUlhXbGR5Y0hsWGJ6aExNbFZWU1hoQlJtcEdRMVF0Vm1odGNrZEVUekYxV1ZnNWIyeGlNRzE0UkhnelYxcFBUM1YxVFdsb2RUUllVVWhuYURoQlVuWktZbU5LTjJKNE5IcEVaWFJ0V2tsM1VWVmhSVWhVZUhabVoxRWlmUS5pc2x1dWRleHNqU0lfVExXY1RNeDZXR1Vlc19lVFZFSkJxRmJqRFVvSVVJIiwiZXhwIjoxNzk0MjMyMjA0LCJjYWxsIjoic3VwcG9ydDoxNyIsImlkIjoiZEhvZGF5YWdOcGs1emNjUC03RFgiLCJ0byI6MzQsInR5cGUiOiJhdWRpbyIsImtleSI6IjBhMDNhNGRiMTFjYWNkMTM5NTNmN2QzYTBkN2U0OWY1MjFmZDc4Nzk2YjcwZTBmYzE5MTkyMTQ1NzY4M2Y4ZGYiLCJtZWRpYV9rZXkiOiJ4LXEwSnY2OHIxNl8xYkZsTUpIS2o4b3pkOFkwZ2ZtWXlKSmNGZHZ0RDVnIiwicGFpciI6WzQyLDM0XSwibWVtYmVyIjoiOFZ2VktFVVFDY1lCbmhFY3l6T09zTURhc1pLZk1Ma0VsdDhSYWY4a0prUSJ9"
    static let textUsers = "eyJ0b2tlbiI6ImV5SmhiR2NpT2lKSVV6STFOaUlzSW5SNWNDSTZJa3BYVkNKOS5leUpwYzNNaU9pSnpNVFV3TURBd09UazVPU0lzSW1saGRDSTZNVGM1TkRJeE1EWXdOQ3dpWlhod0lqb3hOemswTWpNeU1qQTBMQ0poZFdRaU9pSjNiM0prY0d4MWN5MXlaV0ZzZEdsdFpTQmpZV3hzSWl3aVkyRnNiQ0k2SW1OaGJHdzZkME5zVDFoS2VuTlVhWGg0ZUMxRWRYUTBaUzBpTENKcFpDSTZJbmREYkU5WVNucHpWR2w0ZUhndFJIVjBOR1V0SWl3aWMzVmlJam9pWVhWMGFEQjhZVzV1SWl3aWNtOXNaU0k2SW1OaGJHeGxjaUlzSW5SNWNHVWlPaUoyYVdSbGJ5SXNJblJ2SWpvaWRYTmxjbDh5WVdKaklpd2lhVzVtYnlJNkltUTZNakEzTmpZNk1TNVNRMGgwVTJWM01VbHFlVTV1YzNKNk0xODNVRXhWTkVKaFdtTnlVakpLV1cxUmNucElNVTB6ZGtKdGNuWnVNVzV0VDJONVpFVTBiVnA0YldzdE1qZERjSEZ1VkdkZlJVczRWbEp4WXpFemFVaEZTRUp4VVZsRloxSkdkVTFvY0ROR1dVOHRka0prUVdkV1pVdHhWMU5pWmkxb1EwZHVURlpuWkd4bU5rUTFjVUZJZG5OTFVuaHJMV295YmtNNWQwbERiR0YxVm5CNFlqUnlhelp5U2traWZRLjlZVVJ5WmJDYTZUM1FWb3ZDczhPSUlnci1GQmZydHIxNjkxT1A3QlFKNUUiLCJleHAiOjE3OTQyMzIyMDQsImNhbGwiOiJjYWxsOndDbE9YSnpzVGl4eHgtRHV0NGUtIiwiaWQiOiJ3Q2xPWEp6c1RpeHh4LUR1dDRlLSIsInRvIjoidXNlcl8yYWJjIiwidHlwZSI6InZpZGVvIiwia2V5IjoiMTc5ZWFiYzRmYzg1YjVmNjQzMzgzZGQ5NzA2ODlhYjU4ZjE3MzBlODQ5MzlkNmUzOTVlOGVjY2JhZDM1ZWExNSIsIm1lZGlhX2tleSI6Inl2Mzl4R0YzcDFTalpQczQ5Rk15YzVQcVF0dGYtNVQtVG5zSnhQeHpiYVUiLCJwYWlyIjpbImF1dGgwfGFubiIsInVzZXJfMmFiYyJdLCJtZW1iZXIiOiJKVDBLOFJ0Y0NncDYwVXAxbzVBMW84UnlIYVB3bldXXzl1U0pnd3BLc2ZrIn0"
    /// `callToken(42, 56, { into })`, into the call in `call`.
    static let add = "eyJ0b2tlbiI6ImV5SmhiR2NpT2lKSVV6STFOaUlzSW5SNWNDSTZJa3BYVkNKOS5leUpwYzNNaU9pSnpNVFV3TURBd09UazVPU0lzSW1saGRDSTZNVGM1TkRJeE1EWXdOQ3dpWlhod0lqb3hOemswTWpNeU1qQTBMQ0poZFdRaU9pSjNiM0prY0d4MWN5MXlaV0ZzZEdsdFpTQmpZV3hzSWl3aVkyRnNiQ0k2SW5OMWNIQnZjblE2TVRjaUxDSnBaQ0k2SW1adWVVNU9aRFF5U1dGbmVuaGtWSFkxTURoYUlpd2ljM1ZpSWpvME1pd2ljbTlzWlNJNkltTmhiR3hsY2lJc0luUjVjR1VpT2lKaGRXUnBieUlzSW5SdklqbzFOaXdpWjNKdmRYQWlPaUprU0c5a1lYbGhaMDV3YXpWNlkyTlFMVGRFV0NJc0ltbHVabThpT2lKa09qSXdOelkyT2pFdUxWUllVR014ZGtsVVpraEhaWHBuVm5KNmFFa3hlR0Y0UTFCa2JFUlpPVUpvZUhKVFZYb3RSMGRzY21SdmRrSjNOMFJaTFZSd2FYZGhRUzFoUjNWamFHdE1jRTgyTnpaTlZHczFTMkZCSW4wLnpWazA1dEtya1FtSUR5bDRFamhDSHVTRHN4Qk1zX0JVZWRpMzB0dUtpd2ciLCJleHAiOjE3OTQyMzIyMDQsImNhbGwiOiJzdXBwb3J0OjE3IiwiaWQiOiJmbnlOTmQ0MklhZ3p4ZFR2NTA4WiIsInRvIjo1NiwidHlwZSI6ImF1ZGlvIiwiZ3JvdXAiOiJkSG9kYXlhZ05wazV6Y2NQLTdEWCIsInBhaXIiOls0MiwzNF0sIm1lbWJlciI6IjhWdlZLRVVRQ2NZQm5oRWN5ek9Pc01EYXNaS2ZNTGtFbHQ4UmFmOGtKa1EiLCJyaW5nIjoiNE0zbldpM2J2NER0MkZ1bU9XRTZYS1ZBWFQ5WGZITHdiSmdTVDczSTIwOCJ9"
    /// `groupCallToken(42, "meeting:7", { admin: true, encrypt: true, type: "audio" })`.
    static let hostGroup = "eyJ0b2tlbiI6ImV5SmhiR2NpT2lKSVV6STFOaUlzSW5SNWNDSTZJa3BYVkNKOS5leUpwYzNNaU9pSnpNVFV3TURBd09UazVPU0lzSW1saGRDSTZNVGM1TkRJeE1EWXdOQ3dpWlhod0lqb3hOemswTWpNeU1qQTBMQ0poZFdRaU9pSjNiM0prY0d4MWN5MXlaV0ZzZEdsdFpTQnliMjl0SWl3aWNtOXZiU0k2SW0xbFpYUnBibWM2TnlJc0luTjFZaUk2TkRJc0luUjVjR1VpT2lKaGRXUnBieUlzSW1sdVptOGlPaUprT2pJd056WTJPakV1WWtOeE9HZHFTWGxwZURGQmIwbFZiamQxZWpWelMweDVSRmxwVm5Wb1JIaEJSRWRJWkdsUE1IaGljME5uWjB4VFFrODBRamswWjBaemF6Vk5WbUk0VldKd2FrOVlVV0ZtUlY5MFMyeEJJaXdpY0hWaWJHbHphQ0k2ZEhKMVpTd2ljM1ZpYzJOeWFXSmxJanAwY25WbExDSmhaRzFwYmlJNmRISjFaU3dpYUdsa1pHVnVJanBtWVd4elpYMC5wNGFGc0x0bHRPTzk1WXdtVlBRZ3ZpU3dxcHVkT1dTWWRUWjZHa0s3UlprIiwiZXhwIjoxNzk0MjMyMjA0LCJyb29tIjoibWVldGluZzo3IiwidHlwZSI6ImF1ZGlvIiwidXNlciI6NDIsIm1lZGlhX2tleSI6ImtUbkczME5aQlI0YjlpTEl6d3c2NDl5NDRTM2xJektIMXdDa0g5bkNCMUEiLCJob3N0Ijp7InVudGlsIjoxNzk0MjUzODA0LCJwcm9vZiI6Ik5MTlJCclFmUldmQmZyYVpfVWc1YWhLZEFIQ0RiXzV6TEROT20xdVJ0QncifSwicmVjb3JkZXIiOnsidW50aWwiOjE3OTQyNTM4MDQsInByb29mIjoiMDdSNDBKVklCSTFPaUUxWEo0cHdPTHhmM0NoTXJnWUJaZTRma1dDdjNDbyJ9fQ"
    /// `groupCallToken(42, "meeting:7")`.
    static let plainGroup = "eyJ0b2tlbiI6ImV5SmhiR2NpT2lKSVV6STFOaUlzSW5SNWNDSTZJa3BYVkNKOS5leUpwYzNNaU9pSnpNVFV3TURBd09UazVPU0lzSW1saGRDSTZNVGM1TkRJeE1EWXdOQ3dpWlhod0lqb3hOemswTWpNeU1qQTBMQ0poZFdRaU9pSjNiM0prY0d4MWN5MXlaV0ZzZEdsdFpTQnliMjl0SWl3aWNtOXZiU0k2SW0xbFpYUnBibWM2TnlJc0luTjFZaUk2TkRJc0luUjVjR1VpT2lKMmFXUmxieUlzSW1sdVptOGlPaUprT2pJd056WTJPakV1V25wWlFqaE5Yek5rYjBkYU1EbEtSVUZIWWtNMlRYWTJaMlJwY0VsTVRsSlpkMUU1YmxKalp6ZGFaMGRJUldSSWJUTmxhbkZPVVdwd1EySkJaWEZhTmxWRk5EVlJRM0IwZW1OQ016UkJJaXdpY0hWaWJHbHphQ0k2ZEhKMVpTd2ljM1ZpYzJOeWFXSmxJanAwY25WbExDSmhaRzFwYmlJNlptRnNjMlVzSW1ocFpHUmxiaUk2Wm1Gc2MyVjkuYW1FbGtZRXEzN2NoLUUwZHVnVWxDbzQ0Mk1POHgwbkFuVXVTZEhZNVhrTSIsImV4cCI6MTc5NDIzMjIwNCwicm9vbSI6Im1lZXRpbmc6NyIsInR5cGUiOiJ2aWRlbyIsInVzZXIiOjQyfQ"
    /// `groupCallToken(42, "meeting:7", { record: true })`.
    static let recorderGroup = "eyJ0b2tlbiI6ImV5SmhiR2NpT2lKSVV6STFOaUlzSW5SNWNDSTZJa3BYVkNKOS5leUpwYzNNaU9pSnpNVFV3TURBd09UazVPU0lzSW1saGRDSTZNVGM1TkRJeE1EWXdOQ3dpWlhod0lqb3hOemswTWpNeU1qQTBMQ0poZFdRaU9pSjNiM0prY0d4MWN5MXlaV0ZzZEdsdFpTQnliMjl0SWl3aWNtOXZiU0k2SW0xbFpYUnBibWM2TnlJc0luTjFZaUk2TkRJc0luUjVjR1VpT2lKMmFXUmxieUlzSW1sdVptOGlPaUprT2pJd056WTJPakV1U1Zob2REa3lUV1ZmTTFCTUxVOXZRVjl3YjJ0bVdUZFBNRzVqYnpBdGNFTmpkMjFZTWtaMVJ6VmpZWEZLU2xKek0yMW1UMVpaZDNaYVVXSllSMkZIWldGd05HUkxWSGg1WjNsV01FSlJJaXdpY0hWaWJHbHphQ0k2ZEhKMVpTd2ljM1ZpYzJOeWFXSmxJanAwY25WbExDSmhaRzFwYmlJNlptRnNjMlVzSW1ocFpHUmxiaUk2Wm1Gc2MyVjkuSmZVMjJQRDVCSEtRYUQ4SDByTldHby1jUGxuWVZWR3RwNnpmaTJGS0UxZyIsImV4cCI6MTc5NDIzMjIwNCwicm9vbSI6Im1lZXRpbmc6NyIsInR5cGUiOiJ2aWRlbyIsInVzZXIiOjQyLCJyZWNvcmRlciI6eyJ1bnRpbCI6MTc5NDI1MzgwNCwicHJvb2YiOiIwN1I0MEpWSUJJMU9pRTFYSjRwd09MeGYzQ2hNcmdZQlplNGZrV0N2M0NvIn19"
    /// `streamToken(null, "show:1")`.
    static let viewer = "eyJ0b2tlbiI6ImV5SmhiR2NpT2lKSVV6STFOaUlzSW5SNWNDSTZJa3BYVkNKOS5leUpwYzNNaU9pSnpNVFV3TURBd09UazVPU0lzSW1GMVpDSTZJbXhwZG1VdGMzUnlaV0Z0SWl3aWMzUnlJam9pYzJodmR6b3hJaXdpY205c1pTSTZJblpwWlhkbGNpSXNJbWxoZENJNk1UYzVOREl4TURZd05Dd2laWGh3SWpveE56azBNakV4TWpBMGZRLjNRamNOYVhpSHhINkxPZi1CU21KNU84NXVjMEdYOGFFV1cwNzRKUE1xcjgiLCJleHAiOjE3OTQyMTEyMDQsIm5hbWUiOiJzaG93OjEifQ"
}

private func base64URL(_ text: String) -> String {
    Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// A token holding what the server would put in it.
private func tokenOf(_ value: JSONValue) -> String { base64URL(value.jsonString()) }

/// What a token of the app's server or a `ref` holds, as the other side reads it.
private func read(_ text: String) -> JSONValue? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }.flatMap(JSONValue.parse)
}

private let callFields: [String: JSONValue] = [
    "token": "call-token", "exp": 1_794_232_204, "call": "support:17", "id": "call-1", "to": 34, "type": "audio",
    "key": "signal-key", "media_key": "media-key", "pair": [42, 34], "member": "member-proof",
]

private let ringFields: [String: JSONValue] = callFields.merging(["token": "ring-token", "id": "ring-1", "to": 56, "group": "call-1", "ring": "rung-proof"]) { $1 }

private let groupFields: [String: JSONValue] = [
    "token": "room-token", "exp": 1_794_232_204, "room": "meeting:7", "type": "audio", "user": 42, "media_key": "room-key",
    "host": ["until": 1_794_253_804, "proof": "host-proof"], "recorder": ["until": 1_794_253_804, "proof": "recorder-proof"],
]

/// A connection the app's server named as `user`, with no server: its calls route and socket are stand-ins.
private func signedIn(as user: JSONValue?, route: @escaping ([String: JSONValue]) -> (Int, JSONValue?) = { _ in (200, ["token": "t"]) }) -> (rt: Realtime, socket: CallsSocket, route: CallsRouteAsked) {
    let identity = user.map { Identity(token: "h." + base64URL(JSONValue.object(["sub": $0]).jsonString()) + ".s", exp: Date().timeIntervalSince1970 + 3600) }
    let rt = Realtime(RealtimeOptions(app: "app_test", endpoint: URL(string: "https://shop.example/api/realtime")!, server: URL(string: "https://nowhere.invalid")!, identity: identity))
    let socket = CallsSocket(rt)
    socket.answer = { event, _ in
        switch event {
        case "room", "group": return ["ok": true, "server": "wss://nowhere.invalid", "token": "place-token"]
        case "call": return ["ok": true, "role": "polite"]
        case "invite": return ["ok": true, "state": "ringing"]
        case "uninvite": return ["ok": true, "state": "cancelled"]
        default: return ["ok": true]
        }
    }
    let asked = CallsRouteAsked()
    rt.socketAsked = socket
    rt.calls.connectedAsked = true
    rt.calls.routeAsked = { body in
        if body["line"] == nil { asked.add(body) }
        return route(body)
    }
    return (rt, socket, asked)
}

/// Reading what a token holds, from the server's own output and as a string that isn't one.
final class CallTokensReadingTests: XCTestCase {
    func testACallTokenFromTheServerReads() throws {
        let made = try XCTUnwrap(CallTokens.call(Made.call))
        XCTAssertEqual(made.call, "support:17")
        XCTAssertEqual(made.id, "dHodayagNpk5zccP-7DX")
        XCTAssertEqual(made.to, "34")
        XCTAssertEqual(made.type, .audio)
        XCTAssertEqual(made.pair, ["42", "34"])
        XCTAssertEqual(made.member, "8VvVKEUQCcYBnhEcyzOOsMDasZKfMLkElt8Raf8kJkQ")
        XCTAssertNil(made.group)
        XCTAssertNil(made.ring)
        XCTAssertTrue(made.token.hasPrefix("eyJhbGciOi"), "the token inside is the realtime server's, as it is")

        // What a Call is made from, as the calls route would have answered.
        XCTAssertEqual(made.grant["token"] as? String, made.token)
        XCTAssertEqual(made.grant["key"] as? String, "0a03a4db11cacd13953f7d3a0d7e49f521fd78796b70e0fc191921457683f8df")
        XCTAssertEqual(made.grant["media_key"] as? String, "x-q0Jv68r16_1bFlMJHKj8ozd8Y0gfmYyJJcFdvtD5g")
        XCTAssertEqual((made.grant["exp"] as? NSNumber)?.doubleValue, 1_794_232_204)
        XCTAssertEqual(JSONValue.from(any: made.grant["pair"] as Any), [42, 34])
    }

    func testACallBetweenIdsOfTextReads() throws {
        let made = try XCTUnwrap(CallTokens.call(Made.textUsers))
        XCTAssertEqual(made.to, "user_2abc")
        XCTAssertEqual(made.pair, ["auth0|ann", "user_2abc"])
        XCTAssertEqual(made.type, .video, "video unless it says audio")
        XCTAssertEqual(JSONValue.from(any: made.grant["pair"] as Any), ["auth0|ann", "user_2abc"])
    }

    func testARingIntoACallFromTheServerReads() throws {
        let call = try XCTUnwrap(CallTokens.call(Made.call))
        let made = try XCTUnwrap(CallTokens.call(Made.add))
        XCTAssertEqual(made.group, call.id)
        XCTAssertEqual(made.to, "56")
        XCTAssertEqual(made.pair, call.pair, "a ring's pair is the call's")
        XCTAssertEqual(made.ring, "4M3nWi3bv4Dt2FumOWE6XKVAXT9XfHLwbJgST73I208")
        XCTAssertEqual(made.member, call.member, "the proof of whoever rings, from the ref")
    }

    func testAGroupCallTokenFromTheServerReads() throws {
        let made = try XCTUnwrap(CallTokens.groupCall(Made.hostGroup))
        XCTAssertEqual(made.room, "meeting:7")
        XCTAssertEqual(made.type, .audio)
        XCTAssertEqual(made.user, "42")
        XCTAssertEqual(made.mediaKey, "kTnG30NZBR4b9iLIzww649y44S3lIzKH1wCkH9nCB1A")
        XCTAssertEqual(made.proofs.host, ["until": 1_794_253_804, "proof": "NLNRBrQfRWfBfraZ_Ug5ahKdAHCDb_5zLDNOm1uRtBw"])
        XCTAssertEqual(made.proofs.recorder, ["until": 1_794_253_804, "proof": "07R40JVIBI1OiE1XJ4pwOLxf3ChMrgYBZe4fkWCv3Co"])

        let plain = try XCTUnwrap(CallTokens.groupCall(Made.plainGroup))
        XCTAssertEqual(plain.type, .video)
        XCTAssertNil(plain.mediaKey)
        XCTAssertNil(plain.proofs.host)
        XCTAssertNil(plain.proofs.recorder)

        let recorder = try XCTUnwrap(CallTokens.groupCall(Made.recorderGroup))
        XCTAssertNil(recorder.proofs.host)
        XCTAssertNotNil(recorder.proofs.recorder)
    }

    func testAStreamTokenFromTheServerReads() throws {
        let made = try XCTUnwrap(CallTokens.stream(Made.viewer))
        XCTAssertEqual(made.name, "show:1")
        XCTAssertTrue(made.token.hasPrefix("eyJhbGciOi"))
    }

    func testWhatIsNoTokenReadsAsNothing() {
        let notTokens = ["", "not-a-token", "43", "user_2abc", "auth0|5f7c", "a b", "====", "é", base64URL("[]"), base64URL("1"), base64URL("null"), base64URL("\"text\""), base64URL("not json"), Made.call + "!"]
        for text in notTokens {
            XCTAssertNil(CallTokens.open(text), text)
            XCTAssertNil(CallTokens.call(text), text)
            XCTAssertNil(CallTokens.groupCall(text), text)
            XCTAssertNil(CallTokens.stream(text), text)
        }
    }

    func testAKindOfTokenIsNotAnother() {
        XCTAssertNil(CallTokens.call(Made.hostGroup))
        XCTAssertNil(CallTokens.call(Made.viewer))
        XCTAssertNil(CallTokens.groupCall(Made.call))
        XCTAssertNil(CallTokens.groupCall(Made.viewer))
        XCTAssertNil(CallTokens.stream(Made.call))
        XCTAssertNil(CallTokens.stream(Made.hostGroup))
    }

    func testACallTokenWantingAnyOfItsPartsIsNone() {
        XCTAssertNotNil(CallTokens.call(tokenOf(.object(callFields))))
        for part in ["token", "call", "id", "member", "to", "pair"] {
            var fields = callFields
            fields[part] = nil
            XCTAssertNil(CallTokens.call(tokenOf(.object(fields))), part)
        }
        let wrong: [(String, JSONValue)] = [
            ("token", 1), ("call", 1), ("id", 1), ("member", 1), ("to", 0), ("to", 1.5), ("to", "two words"), ("to", .null),
            ("pair", [42]), ("pair", [42, 34, 56]), ("pair", [42, 0]), ("pair", "42,34"),
        ]
        for (part, value) in wrong {
            XCTAssertNil(CallTokens.call(tokenOf(.object(callFields.merging([part: value]) { $1 }))), "\(part) \(value)")
        }
    }

    func testOnlyAudioIsAudio() {
        for (type, expected) in [("audio", CallType.audio), ("video", .video), ("anything", .video)] {
            let call = CallTokens.call(tokenOf(.object(callFields.merging(["type": .string(type)]) { $1 })))
            XCTAssertEqual(call?.type, expected)
            let group = CallTokens.groupCall(tokenOf(.object(groupFields.merging(["type": .string(type)]) { $1 })))
            XCTAssertEqual(group?.type, expected)
        }
        var noType = callFields
        noType["type"] = nil
        XCTAssertEqual(CallTokens.call(tokenOf(.object(noType)))?.type, .video)
    }

    func testAnIdOfDigitsInTextIsThatNumber() throws {
        let made = try XCTUnwrap(CallTokens.call(tokenOf(.object(callFields.merging(["pair": ["42", "34"], "to": "34"]) { $1 })))).grant
        XCTAssertEqual(JSONValue.from(any: made["pair"] as Any), [42, 34], "one spelling for each user, as the calls route answers")
    }

    func testEveryLengthAndTheURLSafeAlphabetRead() throws {
        // Base64 of these takes `-` and `_` once made URL safe, at each length a token can end at.
        for tail in ["", "?", "??", "???>>>", "é✓"] {
            let token = tokenOf(.object(["token": .string("t" + tail), "name": "show:1"]))
            XCTAssertEqual(CallTokens.stream(token)?.token, "t" + tail)
        }
        let urlSafe = tokenOf(.object(["token": "???>>>~~~", "name": "show:1"]))
        XCTAssertTrue(urlSafe.contains("-") || urlSafe.contains("_"))
        XCTAssertFalse(urlSafe.contains("="))
    }
}

/// `startCall`: the token goes to the realtime server, and the calls route isn't asked. With no server.
final class CallTokensStartTests: XCTestCase {
    override func setUp() {
        CallPermissions.answerAsked = { _ in false }
    }

    override func tearDown() {
        CallPermissions.answerAsked = nil
    }

    @MainActor
    func testACallStartsFromItsTokenWithNoRouteAsked() async throws {
        let (rt, socket, route) = signedIn(as: 42)
        var heard: [Call] = []
        rt.calls.onCall { heard.append($0) }
        await mainSettled()

        let call = try await rt.startCall(Made.call)
        XCTAssertEqual(call.id, "dHodayagNpk5zccP-7DX")
        XCTAssertEqual(call.name, "support:17")
        XCTAssertEqual(call.type, .audio)
        XCTAssertEqual(call.role, .caller)
        XCTAssertEqual(call.peer, "34")
        XCTAssertEqual(call.state, .ringing)
        XCTAssertTrue(heard.first === call, "onCall hears it, as a call started by name")

        XCTAssertEqual(route.bodies.count, 0, "the calls route isn't asked")
        let joined = try XCTUnwrap(socket.asked("call").first)
        XCTAssertEqual(joined["token"]?.string, CallTokens.call(Made.call)?.token, "the realtime server gets the token inside")
        XCTAssertEqual(joined["tab"]?.string, rt.tab)
        call.end()
    }

    @MainActor
    func testItRenewsThroughTheCallsRouteWithItsProof() async throws {
        let (rt, _, _) = signedIn(as: 42)
        let call = try await rt.calls.startCall(tokenOf(.object(callFields)))
        // What its renewal sends: Call.scheduleRenewal() asks the route with this.
        XCTAssertEqual(JSONValue.from(any: call.request), ["call": "support:17", "id": "call-1", "role": "caller", "to": 34, "type": "audio", "member": "member-proof"])
        call.end()
    }

    @MainActor
    func testAnIdOfTextGoesAsText() async throws {
        let (rt, _, _) = signedIn(as: "auth0|ann")
        let call = try await rt.startCall(Made.textUsers)
        XCTAssertEqual(call.peer, "user_2abc")
        XCTAssertEqual(JSONValue.from(any: call.request)["to"], "user_2abc")
        call.end()
    }

    @MainActor
    func testATokenMadeForAnotherUserIsForbidden() async {
        for me in [34, 56] as [JSONValue] {
            let (rt, socket, route) = signedIn(as: me)
            await XCTAssertThrowsCode("forbidden") { _ = try await rt.startCall(Made.call) }
            XCTAssertEqual(socket.asked("call").count, 0)
            XCTAssertEqual(route.bodies.count, 0)
        }
        let (rt, _, _) = signedIn(as: "ann")
        await XCTAssertThrowsCode("forbidden") { _ = try await rt.startCall(Made.textUsers) }
    }

    @MainActor
    func testTheSameUserIsTheSameWhicheverWayTheyAreSpelled() async throws {
        let (rt, _, _) = signedIn(as: "42")
        let call = try await rt.startCall(Made.call)
        call.end()
    }

    @MainActor
    func testAConnectionNotYetNamedGoesByTheToken() async throws {
        let (rt, socket, _) = signedIn(as: nil)
        XCTAssertNil(rt.user)
        let call = try await rt.startCall(Made.call)
        XCTAssertEqual(socket.asked("call").first?["token"]?.string, CallTokens.call(Made.call)?.token)
        call.end()
    }

    @MainActor
    func testWhatIsNoTokenIsABadToken() async {
        let (rt, socket, route) = signedIn(as: 42)
        for text in ["not-a-token", "", "34", Made.hostGroup, Made.viewer] {
            await XCTAssertThrowsCode("bad_token") { _ = try await rt.startCall(text) }
        }
        XCTAssertEqual(socket.asked("call").count, 0)
        XCTAssertEqual(route.bodies.count, 0)
    }

    @MainActor
    func testARefusalFromTheRealtimeServerIsNotHeard() async {
        let (rt, socket, _) = signedIn(as: 42)
        socket.answer = { _, _ in ["ok": false, "error": "expired"] }
        var heard = 0
        rt.calls.onCall { _ in heard += 1 }
        await mainSettled()
        await XCTAssertThrowsCode("expired") { _ = try await rt.startCall(Made.call) }
        XCTAssertEqual(heard, 0)
    }

    @MainActor
    func testTheOldFormStaysAsItWas() async throws {
        let (rt, _, route) = signedIn(as: 42, route: { _ in (200, ["token": "t", "pair": [42, 34], "member": "proof"]) })
        let call = try await rt.call("support:34:42", to: "34", type: .audio)
        XCTAssertEqual(route.bodies.count, 1)
        XCTAssertNil(route.bodies[0]["member"])
        XCTAssertEqual(route.bodies[0]["to"], 34)
        XCTAssertEqual(route.bodies[0]["role"], "caller")
        call.end()
    }
}

/// A ring from a token: the proof it carries stays out of what the app sees, and goes with the answer.
final class CallTokensRingTests: XCTestCase {
    private func ring(_ rt: Realtime, info: JSONValue, message: [String: Any] = [:]) -> IncomingCall {
        IncomingCall(owner: rt.calls, message: ["id": "call-1", "call": "support:17", "from": 42, "type": "audio"].merging(message) { $1 }, info: info)
    }

    func testTheProofIsTakenOutOfTheCallersInfo() {
        let (rt, _, _) = signedIn(as: 34)
        let incoming = ring(rt, info: ["name": "Ann", "avatar": "https://shop.example/ann.png", "_ring": "rung-proof"])
        XCTAssertEqual(incoming.info, ["name": "Ann", "avatar": "https://shop.example/ann.png"])
        XCTAssertNil(incoming.info["_ring"])
        XCTAssertEqual(incoming.ring, "rung-proof")
    }

    func testInfoOfNothingElseIsNoInfo() {
        let (rt, _, _) = signedIn(as: 34)
        let incoming = ring(rt, info: ["_ring": "rung-proof"])
        XCTAssertEqual(incoming.info, .null)
        XCTAssertEqual(incoming.ring, "rung-proof")
    }

    func testInfoWithNoProofIsLeftAsItIs() {
        let (rt, _, _) = signedIn(as: 34)
        for info in [["name": "Ann"], .null, "text", [1, 2], ["_ring": 1, "name": "Ann"]] as [JSONValue] {
            let incoming = ring(rt, info: info)
            XCTAssertEqual(incoming.info, info)
            XCTAssertNil(incoming.ring)
        }
    }

    func testARingIntoAGroupCallKeepsItsProofFromTheRelay() {
        let (rt, _, _) = signedIn(as: 56)
        let incoming = ring(rt, info: ["name": "Ann"], message: ["group": "g-1", "pair": [42, 34], "ring": "relay-proof"])
        XCTAssertEqual(incoming.ring, "relay-proof")
        XCTAssertEqual(incoming.info, ["name": "Ann"])
    }

    @MainActor
    func testAnsweringCarriesTheProofAndNothingElseOfTheApps() async throws {
        let (rt, _, route) = signedIn(as: 34, route: { _ in (200, ["token": "callee-token", "key": "k", "pair": [42, 34], "member": "m"]) })
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }

        let incoming = ring(rt, info: ["name": "Ann", "_ring": "rung-proof"])
        guard case let .call(call) = try await incoming.acceptNow() else { return XCTFail("a ring between two answers as a call") }
        XCTAssertEqual(route.bodies, [["call": "support:17", "id": "call-1", "role": "callee", "from": 42, "type": "audio", "ring": "rung-proof"]])
        XCTAssertEqual(call.peerInfo, ["name": "Ann"], "what the app sees of the caller holds no proof")
        XCTAssertEqual(JSONValue.from(any: call.request)["ring"], "rung-proof", "and its renewal proves the same")
        call.end()
    }

    @MainActor
    func testAnsweringARingWithNoProofAsksAsBefore() async throws {
        let (rt, _, route) = signedIn(as: 34)
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }

        guard case let .call(call) = try await ring(rt, info: ["name": "Ann"]).acceptNow() else { return XCTFail("a ring between two answers as a call") }
        XCTAssertEqual(route.bodies, [["call": "support:17", "id": "call-1", "role": "callee", "from": 42, "type": "audio"]])
        call.end()
    }

    @MainActor
    func testARingOnTheLineShowsWithoutItsProof() async throws {
        let (rt, _, _) = signedIn(as: 34)
        var heard: [IncomingCall] = []
        let came = expectation(description: "the ring")
        rt.calls.onIncoming {
            heard.append($0)
            came.fulfill()
        }
        await mainSettled()

        rt.calls.onLine(["op": "incoming", "id": "call-1", "call": "support:17", "from": 42, "type": "audio"], info: ["name": "Ann", "_ring": "rung-proof"])
        await fulfillment(of: [came], timeout: 5)
        XCTAssertEqual(heard.first?.info, ["name": "Ann"])
        XCTAssertEqual(heard.first?.ring, "rung-proof")
        XCTAssertEqual(rt.calls.incoming.first?.info, ["name": "Ann"])
    }

    @MainActor
    func testASealedRingOpensThenLosesItsProof() async throws {
        let (rt, _, _) = signedIn(as: 34)
        let label = "d:20261109"
        rt.keyring.add([label + ":" + String(repeating: "ab", count: 32)])
        let sealed = try XCTUnwrap(rt.keyring.sealJSON(["name": "Ann", "_ring": "rung-proof"], label: label))

        var heard: [IncomingCall] = []
        let came = expectation(description: "the ring")
        rt.calls.onIncoming {
            heard.append($0)
            came.fulfill()
        }
        await mainSettled()

        rt.calls.onLine(["op": "incoming", "id": "call-2", "call": "support:17", "from": 42, "type": "audio"], info: .string(sealed))
        await fulfillment(of: [came], timeout: 5)
        XCTAssertEqual(heard.first?.info, ["name": "Ann"])
        XCTAssertEqual(heard.first?.ring, "rung-proof")
    }
}

/// `add(token)` and `ref`: what the app's route takes, and the token it answers.
final class CallTokensAddTests: XCTestCase {
    private let link = GroupOf(id: "call-1", name: "support:17", type: .audio, pair: [42, 34], member: "member-proof")

    @MainActor
    func testATokenRingsWithoutAskingTheRoute() async throws {
        let (rt, socket, route) = signedIn(as: 42)
        let invite = try await rt.calls.addTo(link, who: tokenOf(.object(ringFields)))
        XCTAssertEqual(invite.id, "ring-1")
        XCTAssertEqual(invite.group, "call-1")
        XCTAssertEqual(invite.to, "56")
        XCTAssertEqual(invite.state, "ringing")
        XCTAssertEqual(route.bodies.count, 0, "the app's own route already said yes")
        XCTAssertEqual(socket.asked("invite"), [["tab": .string(rt.tab), "token": "ring-token", "ring": "rung-proof"]])

        // The app that rang can call it off, with the same token.
        XCTAssertTrue(invite.canCancel)
        try await invite.cancel()
        XCTAssertEqual(invite.state, "cancelled")
        XCTAssertEqual(socket.asked("uninvite"), [["tab": .string(rt.tab), "token": "ring-token"]])
    }

    @MainActor
    func testATokenForAnotherCallIsForbidden() async {
        let (rt, socket, route) = signedIn(as: 42)
        let elsewhere = tokenOf(.object(ringFields.merging(["group": "call-2"]) { $1 }))
        await XCTAssertThrowsCode("forbidden") { _ = try await rt.calls.addTo(link, who: elsewhere) }
        // A call's own token, for ringing nobody in.
        await XCTAssertThrowsCode("forbidden") { _ = try await rt.calls.addTo(link, who: tokenOf(.object(callFields))) }
        XCTAssertEqual(socket.asked("invite").count, 0)
        XCTAssertEqual(route.bodies.count, 0)
    }

    @MainActor
    func testAUserIdStillAsksTheRoute() async throws {
        let (rt, socket, route) = signedIn(as: 42, route: { _ in (200, ["token": "route-token", "ring": "route-proof"]) })
        for who in ["43", "auth0|5f7c", "user_2abc", "not-a-token"] {
            _ = try await rt.calls.addTo(link, who: who)
        }
        XCTAssertEqual(route.bodies.map(\.["to"]), [43, "auth0|5f7c", "user_2abc", "not-a-token"])
        XCTAssertEqual(route.bodies.first?["group"], "call-1")
        XCTAssertEqual(route.bodies.first?["member"], "member-proof")
        XCTAssertEqual(socket.asked("invite").first?["token"], "route-token")
    }

    @MainActor
    func testACallAddsByTokenOnceItIsUp() async throws {
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        let (rt, socket, _) = signedIn(as: 42)
        let call = try await rt.startCall(tokenOf(.object(callFields)))

        await XCTAssertThrowsCode("not_connected") { _ = try await call.add(tokenOf(.object(ringFields))) }
        XCTAssertEqual(socket.asked("invite").count, 0)

        call.session.onConnection?(.connected)
        XCTAssertEqual(call.state, .connected)
        let invite = try await call.add(tokenOf(.object(ringFields)))
        XCTAssertEqual(invite.to, "56")
        XCTAssertEqual(socket.asked("invite").first?["token"], "ring-token")
        await XCTAssertThrowsCode("forbidden") { _ = try await call.add(tokenOf(.object(ringFields.merging(["group": "call-2"]) { $1 }))) }
        call.end()
    }

    @MainActor
    func testAGroupCallMadeFromACallAddsByToken() async throws {
        let (rt, socket, _) = signedIn(as: 42)
        let group = try await rt.calls.joinGroup(link, token: "t", mediaKey: nil, microphone: false, camera: false)
        var rung: [CallInvite] = []
        group.onInvite { rung.append($0) }

        let invite = try await group.add(tokenOf(.object(ringFields)))
        XCTAssertTrue(rung.first === invite)
        XCTAssertEqual(group.invites.map(\.id), ["ring-1"])
        XCTAssertEqual(socket.asked("invite").first?["ring"], "rung-proof")
        group.leave()
    }

    @MainActor
    func testARefHoldsTheCallAndTheProof() async throws {
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        let (rt, _, _) = signedIn(as: 42)
        let call = try await rt.startCall(tokenOf(.object(callFields)))
        XCTAssertEqual(read(call.ref), ["id": "call-1", "name": "support:17", "type": "audio", "pair": [42, 34], "member": "member-proof"])
        XCTAssertFalse(call.ref.contains("="), "base64url, unpadded")
        XCTAssertFalse(call.ref.contains("+"))
        XCTAssertFalse(call.ref.contains("/"))
        call.end()
    }

    @MainActor
    func testARefOfACallTheRouteStartedHoldsTheSame() async throws {
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        let (rt, _, _) = signedIn(as: 42, route: { _ in (200, ["token": "t", "pair": ["auth0|ann", "user_2abc"], "member": "route-proof"]) })
        let call = try await rt.calls.start("support:17", to: "user_2abc", type: .video)
        let ref = try XCTUnwrap(read(call.ref))
        XCTAssertEqual(ref["id"]?.string, call.id)
        XCTAssertEqual(ref, ["id": .string(call.id), "name": "support:17", "type": "video", "pair": ["auth0|ann", "user_2abc"], "member": "route-proof"])
        call.end()
    }

    @MainActor
    func testARefHasNoPartTheCallDoesNotHave() async throws {
        CallPermissions.answerAsked = { _ in false }
        defer { CallPermissions.answerAsked = nil }
        let (rt, _, _) = signedIn(as: 42)
        let call = try await rt.calls.start("support:17", to: "34", type: .video)
        XCTAssertEqual(read(call.ref), ["id": .string(call.id), "name": "support:17", "type": "video"], "the keys a JSON.stringify of nothing leaves out")
        call.end()
    }

    func testARefReadsAsTheBrowsersDoes() {
        // What the browser's refOf() made of this call, with its JSON's keys in the browser's order.
        let browsers = "eyJpZCI6ImRIb2RheWFnTnBrNXpjY1AtN0RYIiwibmFtZSI6InN1cHBvcnQ6MTciLCJ0eXBlIjoiYXVkaW8iLCJwYWlyIjpbNDIsMzRdLCJtZW1iZXIiOiI4VnZWS0VVUUNjWUJuaEVjeXpPT3NNRGFzWktmTUxrRWx0OFJhZjhrSmtRIn0"
        let made = CallTokens.call(Made.call)!
        let ours = CallTokens.ref(of: GroupOf(id: made.id, name: made.call, type: made.type, pair: made.grant["pair"], member: made.member))
        XCTAssertEqual(read(ours), read(browsers))
    }

    @MainActor
    func testAGroupCallsRefIsItsCallsAndOtherRoomsHaveNone() async throws {
        let (rt, _, _) = signedIn(as: 42)
        let made = try await rt.calls.joinGroup(link, token: "t", mediaKey: nil, microphone: false, camera: false)
        XCTAssertEqual(read(try XCTUnwrap(made.ref)), ["id": "call-1", "name": "support:17", "type": "audio", "pair": [42, 34], "member": "member-proof"])
        made.leave()

        let named = try await rt.joinGroupCall(Made.plainGroup)
        XCTAssertNil(named.ref)
        await XCTAssertThrowsCode("not_a_call") { _ = try await named.add("43") }
        named.leave()
    }
}

/// `joinGroupCall`: the room's token goes to the realtime server, and a host's acts carry the token's proofs.
@MainActor
final class CallTokensGroupTests: XCTestCase {
    func testAGroupCallJoinsFromItsTokenWithNoRouteAsked() async throws {
        let (rt, socket, route) = signedIn(as: 42)
        var heard: [GroupCall] = []
        rt.calls.onGroup { heard.append($0) }
        await mainSettled()

        let group = try await rt.joinGroupCall(tokenOf(.object(groupFields)))
        XCTAssertEqual(group.name, "meeting:7")
        XCTAssertTrue(group.encrypted, "with the key in the token")
        XCTAssertNil(group.group)
        XCTAssertEqual(group.microphone, false, "nothing is sent until asked")
        XCTAssertEqual(group.camera, false)
        XCTAssertTrue(heard.first === group)
        XCTAssertEqual(route.bodies.count, 0)
        XCTAssertEqual(socket.asked("room"), [["tab": .string(rt.tab), "token": "room-token"]])
        group.leave()
    }

    func testNoKeyInTheTokenIsNoEncryption() async throws {
        let (rt, _, _) = signedIn(as: 42)
        let group = try await rt.joinGroupCall(Made.plainGroup)
        XCTAssertFalse(group.encrypted)
        group.leave()
    }

    func testATokenMadeForAnotherUserIsForbidden() async {
        for me in [34, "ann"] as [JSONValue] {
            let (rt, socket, _) = signedIn(as: me)
            await XCTAssertThrowsCode("forbidden") { _ = try await rt.joinGroupCall(Made.plainGroup) }
            XCTAssertEqual(socket.asked("room").count, 0)
        }
        // One that names nobody is nobody's.
        var fields = groupFields
        fields["user"] = nil
        let (rt, _, _) = signedIn(as: 42)
        await XCTAssertThrowsCode("forbidden") { _ = try await rt.joinGroupCall(tokenOf(.object(fields))) }
    }

    func testAConnectionNotYetNamedGoesByTheToken() async throws {
        let (rt, socket, _) = signedIn(as: nil)
        let group = try await rt.joinGroupCall(Made.plainGroup)
        XCTAssertEqual(socket.asked("room").count, 1)
        group.leave()
    }

    func testWhatIsNoTokenIsABadToken() async {
        let (rt, socket, _) = signedIn(as: 42)
        for text in ["not-a-token", "", Made.call, Made.viewer] {
            await XCTAssertThrowsCode("bad_token") { _ = try await rt.joinGroupCall(text) }
        }
        XCTAssertEqual(socket.asked("room").count, 0)
    }

    func testTheRealtimeServersRefusalIsItsCode() async {
        let (rt, socket, _) = signedIn(as: 42)
        socket.answer = { _, _ in ["ok": false, "error": "expired"] }
        var heard = 0
        rt.calls.onGroup { _ in heard += 1 }
        await mainSettled()
        await XCTAssertThrowsCode("expired") { _ = try await rt.joinGroupCall(Made.plainGroup) }
        XCTAssertEqual(heard, 0)
    }

    func testAHostsActsCarryTheTokensProof() async throws {
        let (rt, _, route) = signedIn(as: 42, route: { _ in (200, ["done": true]) })
        let group = try await rt.joinGroupCall(tokenOf(.object(groupFields)))
        _ = try await group.moderate(.mute, user: "34")
        _ = try await group.spotlightOff()
        let host: JSONValue = ["until": 1_794_253_804, "proof": "host-proof"]
        XCTAssertEqual(route.bodies, [
            ["moderate": "meeting:7", "act": "mute", "user": 34, "host": host],
            ["moderate": "meeting:7", "act": "unspotlight", "user": .null, "host": host],
        ])
        group.leave()
    }

    func testRecordingCarriesTheTokensProof() async throws {
        let (rt, _, route) = signedIn(as: 42, route: { _ in (200, ["recording": ["id": "rec-1", "state": "recording"]]) })
        var fields = groupFields
        fields["media_key"] = nil
        let group = try await rt.joinGroupCall(tokenOf(.object(fields)))
        _ = try await group.startRecording()
        _ = try await group.stopRecording("rec-1")
        let recorder: JSONValue = ["until": 1_794_253_804, "proof": "recorder-proof"]
        XCTAssertEqual(route.bodies, [
            ["call": "meeting:7", "record": "start", "recorder": recorder],
            ["call": "meeting:7", "record": "stop", "recording": "rec-1", "recorder": recorder],
        ])
        group.leave()
    }

    func testATokenWithoutProofsSendsNone() async throws {
        let (rt, _, route) = signedIn(as: 42, route: { body in (200, body["moderate"] != nil ? ["done": false] : ["recording": ["id": "r", "state": "recording"]]) })
        let group = try await rt.joinGroupCall(Made.plainGroup)
        _ = try await group.moderate(.mute, user: "34")
        _ = try await group.startRecording()
        XCTAssertEqual(route.bodies, [
            ["moderate": "meeting:7", "act": "mute", "user": 34],
            ["call": "meeting:7", "record": "start"],
        ])
        group.leave()
    }

    func testAGroupCallByItsNameSendsNoProof() async throws {
        let (rt, _, route) = signedIn(as: 42, route: { body in (200, body["room"] != nil ? ["token": "t"] : ["done": true]) })
        let group = try await rt.groupCall("meeting:7")
        _ = try await group.moderate(.mute, user: "34")
        XCTAssertEqual(route.bodies, [["room": "meeting:7", "type": "video"], ["moderate": "meeting:7", "act": "mute", "user": 34]])
        group.leave()
    }

    func testTheTokenSaysWhetherTheyMayRecord() async throws {
        let (rt, _, _) = signedIn(as: 42)
        let host = try await rt.joinGroupCall(Made.hostGroup)
        XCTAssertFalse(host.canRecord, "its media is encrypted, which the recorder can't read")
        host.leave()

        var clear = groupFields
        clear["media_key"] = nil
        let open = try await rt.joinGroupCall(tokenOf(.object(clear)))
        XCTAssertTrue(open.canRecord)
        open.leave()

        let recorder = try await rt.joinGroupCall(Made.recorderGroup)
        XCTAssertTrue(recorder.canRecord, "not a host, and the token lets them")
        recorder.leave()

        let plain = try await rt.joinGroupCall(Made.plainGroup)
        XCTAssertFalse(plain.canRecord)
        plain.leave()
    }

    func testTheCallsRouteSaysWhetherTheyMayRecordACallByItsName() async throws {
        // The server packages answer a room's `record` for whoever its rule answers `record`, else its host, and the
        // browser's group calls offer it by that answer (@wordplus/realtime-client's sdk-calls/group-call.ts, mayRecord).
        let host = "h." + base64URL(#"{"video":{"roomAdmin":true}}"#) + ".s"
        var answer: [String: JSONValue] = [:]
        let (rt, _, route) = signedIn(as: 42, route: { _ in (200, .object(answer)) })

        answer = ["token": "t", "record": true]
        let recorder = try await rt.groupCall("meeting:7")
        XCTAssertTrue(recorder.canRecord, "not a host, and the rule lets them")
        recorder.leave()

        answer = ["token": .string(host)]
        let hostOnly = try await rt.groupCall("meeting:8")
        XCTAssertFalse(hostOnly.canRecord, "a host the answer doesn't let record, as a calls route without recording answers")
        hostOnly.leave()

        answer = ["token": "t", "record": false]
        let refused = try await rt.groupCall("meeting:9")
        XCTAssertFalse(refused.canRecord)
        refused.leave()

        answer = ["token": "t", "record": true, "media_key": "kTnG30NZBR4b9iLIzww649y44S3lIzKH1wCkH9nCB1A"]
        let encrypted = try await rt.groupCall("meeting:10")
        XCTAssertFalse(encrypted.canRecord, "its media is encrypted, which the recorder can't read")
        encrypted.leave()

        // Asked as a room by its name, with no proof.
        XCTAssertEqual(route.bodies.map { $0["room"] }, ["meeting:7", "meeting:8", "meeting:9", "meeting:10"])
    }
}

/// The cloud's join for a stream: what each request's grant was, and what it answers, in place of the realtime server.
private final class StreamJoinStub: URLProtocol {
    private static let lock = NSLock()
    private static var replies: [JSONValue] = []
    private static var grants: [String] = []

    static func start(_ answers: [JSONValue]) {
        lock.withLock {
            replies = answers
            grants = []
        }
        URLProtocol.registerClass(StreamJoinStub.self)
    }

    static func stop() {
        URLProtocol.unregisterClass(StreamJoinStub.self)
    }

    static var asked: [String] { lock.withLock { grants } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/easy-stream/v1/join") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(contentsOf: buffer[0..<read])
            }
            return data
        } ?? Data()
        let grant = String(data: body, encoding: .utf8).flatMap(JSONValue.parse)?["grant"]?.string ?? ""
        let reply: JSONValue = Self.lock.withLock {
            Self.grants.append(grant)
            return Self.replies.isEmpty ? ["ok": false, "error": "no_reply"] : Self.replies.removeFirst()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.jsonString().utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// `joinStream`: the token inside goes to the cloud's join, and a function is asked again as each runs out. With no cloud.
@MainActor
final class CallTokensStreamTests: XCTestCase {
    /// A join the cloud lets through: no chat to open, and not live, so no room.
    private let joined: JSONValue = ["ok": true, "stream": ["state": "idle"], "you": ["identity": "u:42", "role": "host"]]
    private let ranOut: JSONValue = ["ok": false, "error": "expired"]

    private func token(_ inner: String, name: String = "show:1") -> String {
        tokenOf(["token": .string(inner), "exp": 1_794_211_204, "name": .string(name)])
    }

    override func tearDown() async throws {
        StreamJoinStub.stop()
    }

    func testAFunctionIsAskedForTheJoinAndTheNameComesFromItsToken() async throws {
        StreamJoinStub.start([joined])
        let (rt, _, route) = signedIn(as: 42)
        var asked = 0
        let stream = try await rt.joinStream(getToken: {
            asked += 1
            return self.token("grant-1")
        }, video: false)
        XCTAssertEqual(stream.name, "show:1")
        XCTAssertFalse(stream.video)
        XCTAssertEqual(stream.role, .host)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(StreamJoinStub.asked, ["grant-1"], "the token inside, as the cloud's join takes it")
        XCTAssertEqual(route.bodies.count, 0, "the calls route isn't asked")
    }

    func testAFunctionIsAskedAgainWhenAGrantRunsOut() async throws {
        StreamJoinStub.start([ranOut, joined])
        let (rt, _, _) = signedIn(as: 42)
        var asked = 0
        _ = try await rt.joinStream {
            asked += 1
            return self.token("grant-\(asked)")
        }
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(StreamJoinStub.asked, ["grant-1", "grant-2"])
    }

    func testOneTokenThrowsExpiredWhenItWouldNeedAnother() async {
        StreamJoinStub.start([ranOut, joined])
        let (rt, _, _) = signedIn(as: 42)
        await XCTAssertThrowsCode("expired") { _ = try await rt.joinStream(self.token("grant-1")) }
        XCTAssertEqual(StreamJoinStub.asked, ["grant-1"], "nothing more goes to the cloud")
    }

    func testOneTokenJoins() async throws {
        StreamJoinStub.start([joined])
        let (rt, _, route) = signedIn(as: 42)
        let stream = try await rt.joinStream(token("grant-1"), video: false)
        XCTAssertEqual(stream.name, "show:1")
        XCTAssertFalse(stream.video)
        XCTAssertEqual(StreamJoinStub.asked, ["grant-1"])
        XCTAssertEqual(route.bodies.count, 0)
    }

    func testAVisitorsTokenFromTheServerJoins() async throws {
        StreamJoinStub.start([joined])
        let (rt, _, _) = signedIn(as: nil)
        let stream = try await rt.calls.joinStream(Made.viewer)
        XCTAssertEqual(stream.name, "show:1")
        XCTAssertEqual(StreamJoinStub.asked, [CallTokens.stream(Made.viewer)?.token])
    }

    func testWhatIsNoTokenIsABadToken() async {
        StreamJoinStub.start([joined])
        let (rt, _, _) = signedIn(as: 42)
        for text in ["not-a-token", "", Made.call, Made.plainGroup] {
            await XCTAssertThrowsCode("bad_token") { _ = try await rt.joinStream(text) }
            await XCTAssertThrowsCode("bad_token") { _ = try await rt.joinStream(getToken: { text }) }
        }
        XCTAssertEqual(StreamJoinStub.asked, [])
    }

    func testAFreshAnswerThatIsNoTokenIsABadToken() async {
        StreamJoinStub.start([ranOut, joined])
        let (rt, _, _) = signedIn(as: 42)
        var asked = 0
        await XCTAssertThrowsCode("bad_token") {
            _ = try await rt.joinStream(getToken: {
                asked += 1
                return asked == 1 ? self.token("grant-1") : "not-a-token"
            })
        }
        XCTAssertEqual(StreamJoinStub.asked, ["grant-1"])
    }

    func testWhatTheAppsFunctionThrowsComesThrough() async {
        struct RouteSaidNo: Error {}
        StreamJoinStub.start([joined])
        let (rt, _, _) = signedIn(as: 42)
        do {
            _ = try await rt.joinStream(getToken: { throw RouteSaidNo() })
            XCTFail("no refusal")
        } catch {
            XCTAssertTrue(error is RouteSaidNo, "\(error)")
        }
    }

    func testTheCloudsRefusalIsItsCode() async {
        StreamJoinStub.start([["ok": false, "error": "not_included"]])
        let (rt, _, _) = signedIn(as: 42)
        await XCTAssertThrowsCode("not_included") { _ = try await rt.joinStream(self.token("grant-1")) }
    }

    func testAStreamByItsNameStillAsksTheRoute() async throws {
        StreamJoinStub.start([joined])
        let (rt, _, route) = signedIn(as: 42, route: { _ in (200, ["token": "route-grant"]) })
        let stream = try await rt.stream("show:42")
        XCTAssertEqual(stream.name, "show:42")
        XCTAssertEqual(route.bodies, [["stream": "show:42"]])
        XCTAssertEqual(StreamJoinStub.asked, ["route-grant"])
    }
}

import Foundation
import LiveKitWebRTC

/// Which video codec each direction of a direct call uses.
///
/// libwebrtc's own order is a legacy one — VP8 first, software everywhere —
/// and the answerer follows the offerer, so a call lands on VP8 unless
/// somebody says otherwise. Each side says what it can encode and decode and
/// whether that is hardware, and the two orders are arranged from that.
///
/// The scoring is the web's, number for number, because the two have to agree
/// about a call they are both in. What differs is where the answers come from:
/// the browser asks the Media Capabilities API, and this asks the factories
/// and the platform.
struct CallCodecScore {
    let ok: Bool
    let hw: Bool
    let smooth: Bool
    let fast: Bool

    var dictionary: [String: Any] {
        [ "ok": ok, "hw": hw, "smooth": smooth, "fast": fast ]
    }

    static let unknown = CallCodecScore(ok: true, hw: false, smooth: true, fast: false)
    static let none = CallCodecScore(ok: false, hw: false, smooth: false, fast: false)
}

struct CallCodecCaps {
    var families: [String: (enc: CallCodecScore, dec: CallCodecScore)]
    /// Whether a sender can be moved to another codec after negotiation.
    /// Neither wrapper has the per-encoding `codec` field — checked in M150's
    /// `RTCRtpEncodingParameters` — so the native side always says no, and the
    /// protocol arranges the SDP order for the side that cannot switch.
    var canSwitch: Bool
    /// Which engine answered the probe: `native` here, `chromium`, `gecko`
    /// or `webkit` from a browser. A codec an engine vouches for can still
    /// fail in it — Chrome's H265 did, on both ends, in every camera stall
    /// the production traces of 19 to 21 Sep 2026 held — and the ranking
    /// holds that against it. Nil from a peer older than the field, which is
    /// then not held to anything.
    var engine: String? = nil

    var dictionary: [String: Any] {
        var map: [String: Any] = [:]

        for (family, pair) in families {
            map[family] = [ "enc": pair.enc.dictionary, "dec": pair.dec.dictionary ]
        }

        var result: [String: Any] = [ "families": map, "switch": canSwitch ]

        if let engine = engine { result["engine"] = engine }

        return result
    }

    static func from(_ value: [String: Any]?) -> CallCodecCaps? {
        guard let value = value, let families = value["families"] as? [String: Any] else { return nil }

        var parsed: [String: (enc: CallCodecScore, dec: CallCodecScore)] = [:]

        let score: ([String: Any]?) -> CallCodecScore = { entry in
            guard let entry = entry else { return .none }

            return CallCodecScore(
                ok: entry["ok"] as? Bool ?? false,
                hw: entry["hw"] as? Bool ?? false,
                smooth: entry["smooth"] as? Bool ?? false,
                fast: entry["fast"] as? Bool ?? false
            )
        }

        for (family, entry) in families {
            guard let pair = entry as? [String: Any] else { continue }

            parsed[family] = (enc: score(pair["enc"] as? [String: Any]), dec: score(pair["dec"] as? [String: Any]))
        }

        return CallCodecCaps(families: parsed, canSwitch: value["switch"] as? Bool ?? false, engine: value["engine"] as? String)
    }
}

/// The stock factory lists H264, VP8, VP9 and — where the build has libaom —
/// AV1, but not H265: `RTCVideoEncoderH265` exists and `createEncoder:` builds
/// it, the codec is simply never advertised. Appending it is what makes HEVC
/// offerable, and it is hardware on every phone this app runs on.
final class CallVideoEncoderFactory: LKRTCDefaultVideoEncoderFactory {
    override func supportedCodecs() -> [LKRTCVideoCodecInfo] {
        var codecs = super.supportedCodecs()

        if !codecs.contains(where: { $0.name.uppercased() == CallCodecs.h265Name }) {
            codecs.append(LKRTCVideoCodecInfo(name: CallCodecs.h265Name))
        }

        return codecs
    }

    /// H264 is encoded at this device's own level where the other side
    /// allowed that — see `atOwnLevel` for the call it cost.
    override func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        guard info.name.uppercased() == "H264" else { return super.createEncoder(info) }

        return LKRTCVideoEncoderH264(codecInfo: CallCodecs.atOwnLevel(info, advertised: super.supportedCodecs()))
    }
}

enum CallCodecs {
    static let h265Name = "H265"

    /// The negotiated H264 codec at this device's own level.
    ///
    /// The codec libwebrtc builds a sender's encoder from carries the *other*
    /// side's `profile-level-id`, and the encoder configures VideoToolbox
    /// with it. Firefox and Chrome both answer `42e01f` — level 3.1, whose
    /// frame-size limit is 3600 macroblocks — so any picture bigger than
    /// 1280×720 is outside what the session was told it may encode, and
    /// VideoToolbox answers `kVTParameterErr` to every frame of it.
    ///
    /// That is what a phone → Firefox call looked like on 16 Sep 2026: it
    /// came up at 960×720 (2700 macroblocks, inside the limit) and played
    /// perfectly, and then died ten to fifteen seconds in, when the wish
    /// from the other side or libwebrtc's own bandwidth adaptation moved the
    /// encoder to 1280×960 (4800) or 1920×1440 (10800). libwebrtc treats the
    /// refusal as final, so the picture stayed dead until something rebuilt
    /// the encoder — a `refresh`, a camera toggle — and then died again at
    /// the next size. libwebrtc's own log named it in one line once it was
    /// captured: the frame-rate cap it prints beside the refusal (40 at
    /// 960×720, 22 at 1280×960, 10 at 1920×1440) is level 3.1's macroblock
    /// rate divided by the frame, and the two that failed are the two over
    /// the frame-size limit.
    ///
    /// Both sides send `level-asymmetry-allowed=1`, which is the permission
    /// for each to send at its own level, so where it is given the level
    /// goes back to the one this device put in its own offer for the same
    /// profile — VideoToolbox's own maximum, which it can therefore always
    /// encode. A level is only ever raised: the other side's is kept where
    /// it is the higher one.
    ///
    /// Where the permission is *not* given there is nothing to be done here
    /// — every endpoint this ships to gives it — and the log now says so
    /// outright, which is how this was found.
    static func atOwnLevel(_ info: LKRTCVideoCodecInfo, advertised: [LKRTCVideoCodecInfo]) -> LKRTCVideoCodecInfo {
        var parameters = info.parameters

        guard parameters["level-asymmetry-allowed"] == "1",
              let negotiated = parameters["profile-level-id"]?.lowercased(),
              negotiated.count == 6,
              let negotiatedLevel = Int(negotiated.suffix(2), radix: 16) else { return info }

        let profile = negotiated.prefix(4)

        let own = advertised
            .filter { $0.name.uppercased() == "H264" }
            .compactMap { $0.parameters["profile-level-id"]?.lowercased() }
            .first { $0.count == 6 && $0.prefix(4) == profile }

        guard let own = own, let ownLevel = Int(own.suffix(2), radix: 16), ownLevel > negotiatedLevel else { return info }

        parameters["profile-level-id"] = own

        return LKRTCVideoCodecInfo(name: info.name, parameters: parameters, scalabilityModes: info.scalabilityModes)
    }

    static let families = [ "video/H265", "video/H264", "video/VP9", "video/VP8", "video/AV1" ]

    /// Newer first among hardware matches, cheaper first among software ones.
    /// VP8 is last: software everywhere and the weakest at 1080p.
    private static let tie: [String: Double] = [
        "video/H265": 0.5,
        "video/H264": 0.4,
        "video/VP9": 0.3,
        "video/AV1": 0.2,
        "video/VP8": 0.1
    ]

    /// A screen share is mostly text, and hardware encoders are tuned for
    /// camera pictures: at the same bitrate they smear glyphs the software
    /// codecs with screen-content tools keep. So the screen ranks by that,
    /// and hardware counts only on the decoding end.
    private static let screenContent: [String: Double] = [
        "video/AV1": 6,
        "video/VP9": 5,
        "video/H265": 3,
        "video/H264": 2,
        "video/VP8": 0
    ]

    private static func mime(of name: String) -> String? {
        families.first { $0.dropFirst("video/".count).uppercased() == name.uppercased() }
    }

    /// A codec both sides agreed on can still carry nothing.
    ///
    /// Chrome on a Mac answers `mediaCapabilities.decodingInfo` for H265 with
    /// "supported, power efficient" — VideoToolbox does decode HEVC — and then
    /// its WebRTC receive path hands the stream to a decoder that throws every
    /// frame away. Measured against this app: 29059 packets and 33 MB arrived
    /// with nothing lost, `framesDecoded` stayed at zero, and the far side sat
    /// on a 0x0 video element for a whole call. No capability answer says so.
    ///
    /// So the device remembers what has failed it and stops asking for it, in
    /// the failing direction only: a codec this phone cannot decode may still
    /// be the right thing for it to send. VP8 is never written off — it is the
    /// one video codec every WebRTC implementation must have, so it is where a
    /// downgrade lands when there is nothing else left.
    static let encode = "enc"
    static let decode = "dec"

    private static let brokenKey = "bm_calls_broken_codecs"
    private static let baseline = "video/VP8"

    /// What a call learns about a codec that carries nothing belongs to that
    /// call and dies with it.
    ///
    /// It used to persist, and that was worse than the problem it solved: a
    /// write-off earned against one peer's broken build then applied to every
    /// later peer forever. Measured on the web side, which had the same store
    /// — Chrome carried H265:dec away from an app call, and Chrome to Safari,
    /// hardware H265 at both ends, fell to H264 on a software encoder and
    /// stayed there. Clearing the entry put it straight back to VideoToolbox.
    /// Every call now starts from what the hardware can do.
    private static var brokenCache: [String: Set<String>] = [:]

    private static func shortName(_ family: String) -> String {
        String(family.dropFirst("video/".count))
    }

    private static func broken() -> [String: Set<String>] {
        brokenCache
    }

    /// Called as a call starts. Nothing an earlier call learnt about an
    /// earlier peer should narrow what this one may offer.
    static func forgetBroken() {
        brokenCache = [:]

        UserDefaults.standard.removeObject(forKey: brokenKey)
    }

    /// True when the call has just learnt something it did not know; the
    /// caller acts on it, so a family already written off answers false.
    static func markBroken(family: String, direction: String) -> Bool {
        guard families.contains(family), family != baseline else { return false }

        guard !(brokenCache[family]?.contains(direction) ?? false) else { return false }

        brokenCache[family, default: []].insert(direction)

        return true
    }

    private static func withoutBroken(_ caps: CallCodecCaps) -> CallCodecCaps {
        let current = broken()

        guard !current.isEmpty else { return caps }

        var result = caps.families

        for (family, pair) in result {
            let directions = current[family] ?? []

            result[family] = (
                enc: directions.contains(encode) ? CallCodecScore.none : pair.enc,
                dec: directions.contains(decode) ? CallCodecScore.none : pair.dec
            )
        }

        return CallCodecCaps(families: result, canSwitch: caps.canSwitch, engine: caps.engine)
    }

    /// The engine this device runs, for the ranking on both ends.
    static let ownEngine = "native"

    /// Whether a family is held back in a direction because of what runs it.
    ///
    /// Chrome's H265 is hardware on paper and failed in practice on both
    /// ends — a decoder on Windows and one on Android that decoded a burst
    /// after each keyframe and then nothing, an encoder on Android that
    /// produced no frame after a restart — in every camera stall the
    /// production traces of 19 to 21 Sep 2026 held. Firefox has no H265 at
    /// all, but its answer to the probe is not trusted either. Apple's is,
    /// and so is this app's, so a call between the two keeps it. An engine
    /// that did not say what it is is not held to anything.
    private static func heldBack(_ family: String, sender: CallCodecCaps, receiver: CallCodecCaps?) -> Bool {
        guard family == "video/H265" else { return false }

        let engines: [String] = [ sender.engine, receiver?.engine ].compactMap { $0 }

        return engines.contains("chromium") || engines.contains("gecko")
    }

    /// What this device can do with each family. VideoToolbox gives hardware
    /// H264 and H265; the rest are libwebrtc's own software codecs, which
    /// decode 1080p smoothly on a phone but do not encode it that way.
    static func probe(factory: LKRTCPeerConnectionFactory,
                      encoders: [LKRTCVideoCodecInfo],
                      decoders: [LKRTCVideoCodecInfo],
                      forced: [String]?) -> CallCodecCaps {
        let encoderNames = Set(encoders.map { $0.name.uppercased() })
        let decoderNames = Set(decoders.map { $0.name.uppercased() })

        var result: [String: (enc: CallCodecScore, dec: CallCodecScore)] = [:]

        for family in families {
            let name = String(family.dropFirst("video/".count)).uppercased()
            let hardware = name == "H264" || name == "H265"

            let canEncode = encoderNames.contains(name)
            let canDecode = decoderNames.contains(name)

            result[family] = (
                enc: CallCodecScore(
                    ok: canEncode,
                    hw: canEncode && hardware,
                    // Software encoders on a phone do not hold 1080p30.
                    smooth: canEncode && hardware,
                    fast: canEncode && hardware
                ),
                dec: CallCodecScore(
                    ok: canDecode,
                    hw: canDecode && hardware,
                    smooth: canDecode,
                    fast: canDecode && hardware
                )
            )
        }

        if let forced = forced, !forced.isEmpty {
            for family in families where !forced.contains(family) {
                result[family] = (enc: .none, dec: .none)
            }
        }

        return withoutBroken(CallCodecCaps(families: result, canSwitch: false, engine: ownEngine))
    }

    private static func encodeScore(_ caps: CallCodecCaps, _ family: String) -> CallCodecScore {
        caps.families[family]?.enc ?? .none
    }

    private static func decodeScore(_ caps: CallCodecCaps, _ family: String) -> CallCodecScore {
        caps.families[family]?.dec ?? .none
    }

    /// Which codec a room's camera (or screen) goes out in, as the browser
    /// picks it (the realtime client's calls/room-publish.ts, cameraCodecFor())
    /// and Better Messages' app does.
    ///
    /// A room is not negotiated the way a direct call is: the media server
    /// forwards each publisher's codec to everyone subscribed, so the choice
    /// is this device's alone, with VP8 behind it for a subscriber that can't
    /// decode it (`roomBackupCodec`). H.264 where this device encodes it in
    /// hardware, which every iPhone and iPad does by VideoToolbox, and nearly
    /// every receiver decodes in hardware too. VP8 otherwise.
    ///
    /// An encrypted room takes VP8 alone, as the browser publishes into one:
    /// nothing can stand behind the codec there, since only a track's first
    /// sender is encrypted, so it has to be one every subscriber decodes.
    ///
    /// The media server may ask for others: the mesh's codec policy, which the
    /// room hands over once joined (`Room.meshCodecPolicy`). Its list is a
    /// preference, first choice first: a codec goes out only where this device
    /// encodes it ("h265:hw" only in hardware), H.265 only to the mesh, never
    /// into an encrypted room, and VP8 is where any list ends. Without one,
    /// the built-in list: H.264 from hardware, else VP8.
    static func roomPublishCodec(_ caps: CallCodecCaps, encrypted: Bool, onMesh: Bool = false, policy: [String]? = nil) -> String {
        if encrypted { return "vp8" }

        let list = policy.flatMap { $0.isEmpty ? nil : $0 } ?? ["h264:hw", "vp8"]

        for entry in list {
            let parts = entry.lowercased().trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1).map(String.init)

            guard let name = parts.first, ["h265", "h264", "vp8", "vp9", "av1"].contains(name) else { continue }

            if name == "vp8" { return "vp8" }
            if name == "h265", !onMesh { continue }

            guard let enc = caps.families["video/" + name.uppercased()]?.enc, enc.ok else { continue }

            if parts.count > 1, parts[1] == "hw", !enc.hw { continue }

            return name
        }

        return "vp8"
    }

    /// What goes behind a room's camera (the browser's backupFor()): nothing
    /// behind VP8 or in an encrypted room; H.264 where the media server's
    /// policy asks for it and the codec isn't H.264; VP8 otherwise.
    static func roomBackupCodec(_ codec: String, encrypted: Bool, policy: String? = nil) -> String? {
        if codec == "vp8" || encrypted { return nil }

        return policy?.lowercased() == "h264" && codec != "h264" ? "h264" : "vp8"
    }

    /// The video codecs this device encodes in hardware, as a join to the mesh
    /// names them (`mesh_hwenc`) for its live view and what a codec policy
    /// could have it send.
    static func hardwareEncoders(_ caps: CallCodecCaps) -> [String] {
        ["H264", "H265", "VP8", "VP9", "AV1"].filter { name in
            guard let enc = caps.families["video/" + name]?.enc else { return false }

            return enc.ok && enc.hw
        }.map { $0.lowercased() }
    }

    /// The video codecs this device decodes in hardware, as a join to the mesh
    /// names them (`mesh_hwdec`), as the browser's client does.
    static func hardwareDecoders(_ caps: CallCodecCaps) -> [String] {
        ["H264", "H265", "VP8", "VP9", "AV1"].filter { name in
            guard let dec = caps.families["video/" + name]?.dec else { return false }

            return dec.ok && dec.hw
        }.map { $0.lowercased() }
    }

    /// Whether a room's server is WordPlus Mesh, whose rooms take H.265: the
    /// cloud's `rtc.wordplus.cloud` and the names under it, as the room
    /// client's own mesh check.
    static func onMesh(_ server: String) -> Bool {
        guard let host = URL(string: server)?.host?.lowercased() else { return false }

        return host == "rtc.wordplus.cloud" || host.hasSuffix(".rtc.wordplus.cloud")
    }

    /// How good one direction would be: hardware on either end counts most, a
    /// smooth encoder next, then the tie-breaker. Nil when it is not possible.
    static func directionScore(sender: CallCodecCaps, receiver: CallCodecCaps?, family: String) -> Double? {
        let enc = encodeScore(sender, family)
        let dec = receiver.map { decodeScore($0, family) } ?? .unknown

        guard enc.ok, dec.ok else { return nil }

        // A family held back loses its hardware standing and its tie-breaker:
        // it lands under every software codec that is smooth (VP9 at 3.3, AV1
        // at 3.2) and stays above VP8 (3.1), so it is still there when nothing
        // better is, and never chosen over something that works. The web
        // scores it the same way, number for number.
        // Summed in typed parts: one expression of them all is more than Xcode 16's
        // compiler type-checks in time.
        let smooth: Double = (enc.smooth ? 2 : 0) + (dec.smooth ? 1 : 0)

        if heldBack(family, sender: sender, receiver: receiver) {
            return smooth + 0.15
        }

        let hardware: Double = (enc.hw ? 4 : 0) + (dec.hw ? 4 : 0)
        let tieBreak: Double = tie[family] ?? 0

        return hardware + smooth + tieBreak
    }

    static func screenDirectionScore(sender: CallCodecCaps, receiver: CallCodecCaps?, family: String) -> Double? {
        let enc = encodeScore(sender, family)
        let dec = receiver.map { decodeScore($0, family) } ?? .unknown

        guard enc.ok, dec.ok else { return nil }

        let content: Double = screenContent[family] ?? 0
        let smooth: Double = (enc.smooth ? 2 : 0) + (dec.smooth ? 1 : 0)
        let decodeHardware: Double = dec.hw ? 1 : 0
        let tieBreak: Double = tie[family] ?? 0

        return content + smooth + decodeHardware + tieBreak
    }

    /// Whether a direction can run at 60 frames, by both ends' own word.
    static func fastDirection(sender: CallCodecCaps, receiver: CallCodecCaps?, family: String) -> Bool {
        let enc = encodeScore(sender, family)
        let dec = receiver.map { decodeScore($0, family) } ?? .none

        return enc.fast && dec.fast
    }

    private static func ranked(sender: CallCodecCaps, receiver: CallCodecCaps?, screen: Bool) -> [String] {
        families
            .compactMap { family -> (String, Double)? in
                let value = screen
                    ? screenDirectionScore(sender: sender, receiver: receiver, family: family)
                    : directionScore(sender: sender, receiver: receiver, family: family)

                return value.map { (family, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    /// The order for an offer: this side's sending, the other side unknown.
    static func offerOrder(own: CallCodecCaps, screen: Bool, forced: [String]?) -> [String] {
        if let forced = forced, !forced.isEmpty { return forced }

        return ranked(sender: own, receiver: nil, screen: screen)
    }

    /// The order for an answer is what both sides send with until they switch,
    /// and what a side that cannot switch sends with for good. So it serves
    /// the offerer's sending when the offerer cannot switch, and this side's
    /// sending otherwise.
    static func answerOrder(own: CallCodecCaps, peer: CallCodecCaps?, screen: Bool, forced: [String]?) -> [String] {
        if let forced = forced, !forced.isEmpty { return forced }

        if let peer = peer, !peer.canSwitch {
            return ranked(sender: peer, receiver: own, screen: screen)
        }

        return ranked(sender: own, receiver: peer, screen: screen)
    }

    /// Reorders a video transceiver's codecs: every capability of a family in
    /// ranking order, the families not ranked after them, then the rest (RTX,
    /// RED, FEC) as they were.
    static func apply(order: [String], to transceiver: LKRTCRtpTransceiver, factory: LKRTCPeerConnectionFactory) {
        let capabilities = factory.rtpReceiverCapabilities(forKind: "video")

        guard !capabilities.codecs.isEmpty else { return }

        let isFamily: (LKRTCRtpCodecCapability, String) -> Bool = { codec, family in
            codec.mimeType.lowercased() == family.lowercased()
        }

        // A section says what this side can be sent, and the other side sends
        // with the order in it. So a family this device has been caught
        // failing to decode comes out of the list altogether, before it is
        // ordered: leaving it in is an invitation to send exactly what will
        // not arrive, and demoting it is not enough, because the ranking that
        // built `order` may have put it first for this side's own *sending* —
        // which is what the order means when the other side's abilities are
        // not known yet.
        let dead = broken()
        let codecs = capabilities.codecs.filter { codec in
            guard let family = families.first(where: { isFamily(codec, $0) }) else { return true }

            return !(dead[family]?.contains(decode) ?? false)
        }

        let preferred = order.flatMap { family in codecs.filter { isFamily($0, family) } }

        guard !preferred.isEmpty else { return }

        // A family that is merely not preferred still belongs in the section:
        // the other side may have nothing else.
        let known = codecs.filter { codec in families.contains { isFamily(codec, $0) } }
        let others = known.filter { codec in !preferred.contains(where: { $0 === codec }) }
        let rest = codecs.filter { codec in !families.contains { isFamily(codec, $0) } }

        // The header's `NSError **_Nullable` on a method that already takes a
        // nullable array imports as `error: ()`, so the call reads oddly and
        // has to be written this way.
        try? transceiver.setCodecPreferences(preferred + others + rest, error: ())
    }
}

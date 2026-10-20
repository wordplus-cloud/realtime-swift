import Foundation

/// How much of a picture actually goes out.
///
/// The other side says how big it draws each of our video sources, and the
/// encoder is set to exactly that: a camera in a thumbnail is not paid for at
/// 1080p, a screen share on a retina stage gets retina text, and a source
/// nobody is looking at is switched off rather than sent and thrown away.
///
/// Every number here is the web's. Two sides of one call have to make the same
/// picture out of the same wish.
struct CallEncodingShape {
    let active: Bool
    let maxBitrate: Int
    let scale: Double
    let maxFramerate: Int?
}

enum CallShapes {
    static let viewSteps = [ 180, 360, 540, 720, 1080, 1440, 2160 ]

    static let cameraMaxBitrate = 4_000_000
    static let microphoneMaxBitrate = 64_000
    static let screenAudioMaxBitrate = 128_000

    static let defaultTrackHeight = 1080

    private static let cameraRungs: [(height: Int, maxBitrate: Int, maxFramerate: Int)] = [
        (180, 200_000, 15),
        (360, 500_000, 20),
        (540, 1_000_000, 25),
        (720, 2_000_000, 30)
    ]

    private static let screenDefaultHeight = 1080
    private static let screenSmallHeight = 360
    private static let screenSmallFramerate = 5
    private static let screenFramerate = 30

    private static let screenCeilings: [(height: Int, maxBitrate: Int)] = [
        (540, 4_000_000),
        (720, 6_000_000),
        (1080, 10_000_000),
        (1440, 14_000_000),
        (Int.max, 20_000_000)
    ]

    /// A camera is asked for at a rung, so a box that grows by a few pixels
    /// does not reconfigure the far encoder. Exactly the web's ladder.
    static func viewStep(_ height: Int) -> Int {
        guard height > 0 else { return 0 }

        return viewSteps.first { $0 >= height } ?? viewSteps[viewSteps.count - 1]
    }

    /// A screen is asked for at the pixel it is drawn at, rounded up to an
    /// even one — text is either sharp or it is not, and an odd height is not
    /// something an encoder can give.
    static func exactStep(_ height: Int) -> Int {
        guard height > 0 else { return 0 }

        return Int(ceil(Double(height) / 2)) * 2
    }

    static func screenCeiling(_ height: Int) -> Int {
        (screenCeilings.first { $0.height >= height } ?? screenCeilings[screenCeilings.count - 1]).maxBitrate
    }

    static func audioCeiling(_ source: CallSource) -> Int {
        source == .screenShareAudio ? screenAudioMaxBitrate : microphoneMaxBitrate
    }

    /// The camera at the rung the other side asked for; full size keeps the
    /// capture's own frame rate and the camera ceiling.
    static func camera(wanted: Int?, captureHeight: Int) -> CallEncodingShape {
        if wanted == 0 {
            return CallEncodingShape(active: false, maxBitrate: cameraMaxBitrate, scale: 1, maxFramerate: nil)
        }

        let full = viewSteps[viewSteps.count - 1]

        guard let wanted = wanted, wanted < full, let rung = cameraRungs.first(where: { $0.height >= wanted }) else {
            return CallEncodingShape(active: true, maxBitrate: cameraMaxBitrate, scale: 1, maxFramerate: nil)
        }

        return CallEncodingShape(
            active: true,
            maxBitrate: rung.maxBitrate,
            scale: max(1, Double(captureHeight) / Double(rung.height)),
            maxFramerate: rung.maxFramerate
        )
    }

    /// The screen at exactly the size it is shown. In a chip it keeps up to
    /// 1080 lines and drops to 5 frames instead, so it is sharp the moment it
    /// is put back on the stage.
    ///
    /// `fast` means both ends run the chosen codec smoothly at 60, so the
    /// capture's own rate goes through.
    static func screen(wanted: Int?, captureHeight: Int, fast: Bool) -> CallEncodingShape {
        let full = captureHeight

        if wanted == 0 {
            return CallEncodingShape(active: false, maxBitrate: screenCeiling(full), scale: 1, maxFramerate: nil)
        }

        if let wanted = wanted, wanted <= screenSmallHeight {
            let height = min(full, screenDefaultHeight)

            return CallEncodingShape(
                active: true,
                maxBitrate: screenCeiling(height),
                scale: max(1, Double(full) / Double(height)),
                maxFramerate: screenSmallFramerate
            )
        }

        let height = min(full, wanted ?? screenDefaultHeight)

        return CallEncodingShape(
            active: true,
            maxBitrate: screenCeiling(height),
            scale: max(1, Double(full) / Double(height)),
            maxFramerate: fast ? nil : screenFramerate
        )
    }
}

/// Screen audio is music or a video's sound as often as speech, and Opus only
/// sends it in stereo when the side *receiving* it says so in its SDP. So
/// every audio section of a description that arrives is marked stereo before
/// it is applied, and this side's encoder then sends screen audio in stereo.
///
/// Every audio section, not the screen-audio one alone. Both carry Opus
/// under one payload type, and a payload type shared across a bundle has to
/// mean one thing (RFC 8843): marking one section and not the other had
/// libwebrtc reporting a "codec collision" at every connect — one it still
/// let through, where a stricter build refuses the description. The
/// microphone captures mono, so its section reading stereo changes nothing
/// it sends, and the bitrate it may use is set on its sender, not here.
enum CallSdp {
    static func withStereoOpus(_ sdp: String) -> String {
        let params = "stereo=1;sprop-stereo=1;maxaveragebitrate=" + String(CallShapes.screenAudioMaxBitrate)

        // Worked on line by line and joined back with the same separator, so
        // an SDP with nothing to change comes out byte for byte as it went in.
        // Anything else is a description libwebrtc may refuse for a reason
        // that has nothing to do with stereo.
        var lines = sdp.components(separatedBy: "\n")

        var starts: [Int] = []

        for (index, line) in lines.enumerated() where line.hasPrefix("m=") {
            starts.append(index)
        }

        // Backwards: inserting a line moves everything after it.
        for (position, start) in starts.enumerated().reversed() {
            guard lines[start].hasPrefix("m=audio") else { continue }

            let end = position + 1 < starts.count ? starts[position + 1] : lines.count
            let section = lines[start..<end]

            guard let payload = opusPayload(in: section) else { continue }

            let prefix = "a=fmtp:" + payload + " "

            if let index = section.indices.first(where: { lines[$0].hasPrefix(prefix) }) {
                let existing = String(lines[index].dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)

                let kept = existing
                    .components(separatedBy: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { item in
                        !item.isEmpty
                            && !item.hasPrefix("stereo=")
                            && !item.hasPrefix("sprop-stereo=")
                            && !item.hasPrefix("maxaveragebitrate=")
                    }

                lines[index] = prefix + (kept + [params]).joined(separator: ";") + "\r"
            } else if let index = section.indices.first(where: { lines[$0].hasPrefix("a=rtpmap:" + payload + " ") }) {
                lines.insert(prefix + params + "\r", at: index + 1)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// A description without the attribute lines for payload types its media
    /// sections do not declare.
    ///
    /// Firefox answers a negotiation on the offerer's payload types and then,
    /// in every offer of its own — an ICE restart, a codec change — renumbers
    /// them to its own defaults while keeping the `a=rtcp-fb` lines it had
    /// for the old ones. libwebrtc's parser, this app's as much as Chrome's,
    /// makes a codec out of every payload type it sees a feedback or format
    /// line for, and refuses the whole description over the nameless ones:
    /// "Failed to parse codecs correctly". Measured 21 Sep 2026 on production
    /// between Firefox and Chrome. The web strips them before sending; this
    /// strips them before applying, for a Firefox on a plugin older than that.
    static func withoutOrphanPayloads(_ sdp: String) -> String {
        let lines = sdp.components(separatedBy: "\n")

        var starts: [Int] = []

        for (index, line) in lines.enumerated() where line.hasPrefix("m=") {
            starts.append(index)
        }

        var drop = Set<Int>()

        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : lines.count
            let fields = lines[start].trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")

            guard fields.count > 3 else { continue }

            let declared = Set(fields[3...].map(String.init))

            guard declared.allSatisfy({ Int($0) != nil }) else { continue }

            for index in (start + 1)..<end {
                let line = lines[index]

                guard line.hasPrefix("a=rtcp-fb:") || line.hasPrefix("a=fmtp:") || line.hasPrefix("a=rtpmap:"),
                      let colon = line.firstIndex(of: ":") else { continue }

                let payload = String(line[line.index(after: colon)...].prefix { $0.isNumber })

                guard !payload.isEmpty, !declared.contains(payload) else { continue }

                drop.insert(index)
            }
        }

        guard !drop.isEmpty else { return sdp }

        return lines.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }.joined(separator: "\n")
    }

    private static func opusPayload(in section: ArraySlice<String>) -> String? {
        for line in section where line.hasPrefix("a=rtpmap:") {
            let body = line.dropFirst("a=rtpmap:".count)

            guard let space = body.firstIndex(of: " ") else { continue }

            let payload = String(body[body.startIndex..<space])

            if body[body.index(after: space)...].lowercased().hasPrefix("opus/48000/2") { return payload }
        }

        return nil
    }
}

/// A candidate line, read far enough to decide what to do with it.
struct CallCandidateInfo {
    let type: String
    let address: String
    let isPrivate: Bool

    static func parse(_ candidate: String) -> CallCandidateInfo? {
        var line = candidate

        if line.hasPrefix("candidate:") { line = String(line.dropFirst("candidate:".count)) }

        let parts = line.components(separatedBy: " ")

        guard parts.count >= 8 else { return nil }

        let address = parts[4]
        var type = ""

        if let index = parts.firstIndex(of: "typ"), index + 1 < parts.count {
            type = parts[index + 1]
        }

        return CallCandidateInfo(type: type, address: address, isPrivate: isPrivateAddress(address))
    }

    /// The ranges a candidate can name that mean nothing outside its own
    /// network. Two people behind different routers can each hold 192.168.1.x,
    /// and pairing those wastes the whole connectivity check on an address
    /// belonging to a stranger's printer.
    static func isPrivateAddress(_ address: String) -> Bool {
        let lower = address.lowercased()

        if lower.hasSuffix(".local") { return true }
        if lower == "::1" { return true }
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }

        let octets = lower.components(separatedBy: ".")

        guard octets.count == 4, let first = Int(octets[0]), let second = Int(octets[1]) else { return false }

        if first == 10 || first == 127 { return true }
        if first == 169 && second == 254 { return true }
        if first == 192 && second == 168 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 100 && (64...127).contains(second) { return true }

        return false
    }
}

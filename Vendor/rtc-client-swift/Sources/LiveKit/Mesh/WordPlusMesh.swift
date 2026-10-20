/*
 * Copyright 2026 The WordPlus RTC client authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

// WordPlus Mesh: what this client does differently on a mesh's servers, as @wordplus/rtc-client does in a browser
// (the mesh's clients/js). The protocol is upstream's own; a mesh node answers `/settings/regions` as LiveKit Cloud
// does, refuses a join it can't place now with HTTP 429, and sends its region list over the signal connection.

/// The domains a mesh serves: `rtc.wordplus.cloud` and the names under it, and any a product adds.
public enum MeshDomains {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var domains: Set<String> = ["rtc.wordplus.cloud"]

    /// Adds domains served by a mesh, beside the built-in ones.
    public static func add(_ list: String...) {
        lock.lock()
        defer { lock.unlock() }
        for domain in list {
            let clean = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if !clean.isEmpty { domains.insert(clean) }
        }
    }

    static func contains(host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Why a join on a mesh started to wait: every server tried was `busy` and a slot is held on one, a node holds a
/// `slot` for it, the cluster is `full` (and a slot is held), or no server of the list could be reached at all.
public enum MeshWaitReason: String, Sendable {
    case busy
    case slot
    case full
    case unreachable
}

/// A join on a mesh waiting, until when, and why (`ConnectOptions.onMeshWait`).
public struct MeshWait: Sendable {
    public let until: Date
    public let reason: MeshWaitReason
}

/// The product placing a call (1.0.3, rtc-client 1.0.6's `meshApp`), which a mesh node is told on each join of the
/// room (`rtc_app`) for its live view: `MeshApp(name: "better-messages", version: "3.1.4")`.
public struct MeshApp: Sendable, Hashable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// A mesh node's codec policy (1.0.3, rtc-client 1.0.8's `MeshCodecPolicy`), `Room.meshCodecPolicy`: each list the
/// codecs it would have a camera or a screen go out in, first choice first (`h265:hw` only from hardware), and what goes
/// behind a camera. A preference: the product takes the first its device sends.
public struct MeshCodecPolicy: Sendable, Hashable {
    public let camera: [String]?
    public let screen: [String]?
    public let backup: String?

    public init(camera: [String]? = nil, screen: [String]? = nil, backup: String? = nil) {
        self.camera = camera
        self.screen = screen
        self.backup = backup
    }
}

/// A mesh node's refusal of a join, from its 429 (`X-Mesh-Refused`, `X-Mesh-Node`, `Retry-After`).
public struct MeshRefusal: Sendable {
    /// `busy`, `slot` or `full`; nil from a server that names none.
    public let kind: String?
    /// The refusing node's id, as the region list names it.
    public let node: String?
    /// How long until the node takes the join, when it said.
    public let retryAfter: TimeInterval?

    init(kind: String?, node: String?, retryAfter: TimeInterval?) {
        self.kind = ["busy", "slot", "full"].contains(kind ?? "") ? kind : nil
        self.node = node?.isEmpty == false ? node : nil
        self.retryAfter = retryAfter
    }

    /// A Retry-After header: seconds, or an HTTP date.
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = Double(header), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

enum Mesh {
    /// How long a join keeps trying before it reports its last error, unless the product says otherwise.
    static let joinBudget: TimeInterval = 30

    /// How long a resume waits for its server before moving on, at least: a live node answers within about a second,
    /// even across continents, and a dead one would otherwise hold the attempt past the mesh's hold of its
    /// participants.
    static let resumeTimeout: TimeInterval = 5

    /// How long a resume waits for its server (1.0.2, rtc-client 1.0.5's resumeWaitMs): four of the round trips the
    /// connection last measured, at least `resumeTimeout` and at most the socket's own timeout. A connection whose
    /// round trip had grown to seconds, a phone behind a full queue, took 5 s for a server that is gone and moved on
    /// from one that was up (a large audio chat, 2026-10-17: 2 to 28 s).
    static func resumeWait(rttMs: Int64, cap: TimeInterval) -> TimeInterval {
        min(cap, max(resumeTimeout, 4 * Double(max(rttMs, 0)) / 1000))
    }

    /// How long a probe of whether a server answers may take (1.0.2).
    static let serverProbeTimeout: TimeInterval = 3

    /// How many servers a failed resume probes before it stays where it is (1.0.2, rtc-client 1.0.12).
    static let resumeMoveTries = 3

    /// Whether a server answers an HTTP request within the timeout (1.0.2, rtc-client 1.0.5): its signal URL's origin
    /// over HTTP(S). A server that is up answers any request, whatever its status; one that is gone, or out of this
    /// client's reach, doesn't.
    static func serverAnswers(_ url: URL, timeout: TimeInterval = serverProbeTimeout) async -> Bool {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host != nil else { return false }
        components.scheme = components.scheme?.replacingOccurrences(of: "ws", with: "http")
        components.path = "/"
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { return false }
        var request = URLRequest(url: origin, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        do {
            _ = try await probeSession.data(for: request)
            return true
        } catch {
            return false
        }
    }

    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Whether a failed resume goes to another server of the region list (1.0.2, rtc-client 1.0.5): only when its own
    /// server has stopped answering and that one answers. When its own still answers, the server is up and the resume
    /// failed on the way. When neither answers, it is this client's network that is down, and every server would fail
    /// alike: walking the list then took a phone in a call on France's node to Limburg and on to Canada during its own
    /// outage, and kept it there for the rest of the call (a large audio chat, 2026-10-17).
    static func resumeMoves(ownAnswers: Bool, nextAnswers: Bool) -> Bool {
        !ownAnswers && nextAnswers
    }

    /// Whether two signal URLs name the same server, by host and port (1.0.2, rtc-client 1.0.12).
    static func sameServer(_ a: URL, _ b: URL) -> Bool {
        a.host?.lowercased() == b.host?.lowercased() && a.port == b.port
    }

    /// How long the region list's fetch, or the validation after a failed join, may take before it counts as
    /// unreachable: stock has no timeout on either, and each held a lock the next attempt waited on.
    static let requestTimeout: TimeInterval = 3

    /// How long after a join a node has to send its region list before it is fetched instead.
    static let regionsWait: TimeInterval = 3

    /// The mesh's wait when every node is full, if its 429 names none.
    static let fullRetry: TimeInterval = 5

    /// The signal response field a node sends its region list in: one LiveKit's protocol hasn't got, so any other
    /// client skips it.
    static let regionsField: UInt64 = 100

    /// How long to wait before trying a failed join again, or nil when it isn't one to try again or the deadline
    /// comes first: a full mesh after its Retry-After, within a second after it (or 5 s, give or take half); a
    /// server that couldn't be reached after 1 to 3 s.
    static func joinRetry(_ error: Error, deadline: Date, now: Date = Date()) -> TimeInterval? {
        let delay: TimeInterval
        if let refusal = (error as? LiveKitError)?.meshRefusal {
            delay = refusal.retryAfter.map { $0 + Double.random(in: 0 ..< 1) } ?? fullRetry * Double.random(in: 0.5 ..< 1.5)
        } else if error.isRetryableForRegionFailover {
            delay = 1 + Double.random(in: 0 ..< 2)
        } else {
            return nil
        }
        return now.addingTimeInterval(delay) < deadline ? delay : nil
    }

    /// The WordPlus RTC client for Swift's own version, which a mesh node is told on each join (`rtc_client`) beside
    /// upstream's, which the client reports as its SDK's and servers gate protocol features on. build.sh refuses a
    /// patch whose version here isn't the one its revisions list.
    static let clientVersion = "1.0.4"

    /// What this client can do beyond upstream's, which a mesh node is told on each join (`mesh_caps`, 1.0.3, as
    /// rtc-client 1.0.7 and 1.0.8): it stops sending an audio track nobody hears when its node says so
    /// (`LocalAudioTrack.setMeshHeard`), and its room hands the node's codec policy to the product
    /// (`Room.meshCodecPolicy`).
    static let caps = "audio-pause,codec-policy"

    /// What a join to a mesh's server says beside upstream's parameters (upstream already names the network's type,
    /// `network`):
    /// - `mesh_client`: it walks and waits, so a busy node may refuse it;
    /// - `mesh_hwdec`: the codecs it decodes in hardware;
    /// - `mesh_wait`: it waits on this node (from the URL the walk gave it);
    /// - `rtc_client`, `mesh_caps`, `rtc_app`, `device_type` (1.0.3, rtc-client 1.0.6 to 1.0.8): its own version, what
    ///   it can do, the room's product and the device kind, for the node's live view;
    /// - `mesh_hwenc` (1.0.3, rtc-client 1.0.8): the codecs it encodes in hardware.
    /// Nothing for any other server.
    static func queryItems(for url: URL, connectOptions: ConnectOptions) -> [URLQueryItem] {
        guard url.isMeshServer else { return [] }
        var items = [URLQueryItem(name: "mesh_client", value: "1")]
        if !connectOptions.meshHardwareDecoders.isEmpty {
            items.append(URLQueryItem(name: "mesh_hwdec", value: connectOptions.meshHardwareDecoders.joined(separator: ",")))
        }
        if !connectOptions.meshHardwareEncoders.isEmpty {
            items.append(URLQueryItem(name: "mesh_hwenc", value: connectOptions.meshHardwareEncoders.joined(separator: ",")))
        }
        items.append(URLQueryItem(name: "rtc_client", value: clientVersion))
        items.append(URLQueryItem(name: "mesh_caps", value: caps))
        if let app = appParam(connectOptions.meshApp) {
            items.append(URLQueryItem(name: "rtc_app", value: app))
        }
        if let device = deviceType() {
            items.append(URLQueryItem(name: "device_type", value: device))
        }
        if url.isMeshWait {
            items.append(URLQueryItem(name: "mesh_wait", value: "1"))
        }
        return items
    }

    /// A room's product as a join names it (`rtc_app`, rtc-client 1.0.6's meshAppParam), "better-messages/3.1.4":
    /// letters, digits and . _ - only, 40 of each; none without a name.
    static func appParam(_ app: MeshApp?) -> String? {
        func clean(_ s: String?) -> String {
            String((s ?? "").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
                .prefix(40).map(Character.init))
        }
        let name = clean(app?.name)
        return name.isEmpty ? nil : "\(name)/\(clean(app?.version))"
    }

    /// The device kind a join names (`device_type`, rtc-client 1.0.6): an iPhone a phone, an iPad a tablet, a Mac, or
    /// an iPhone or iPad app running on one, a desktop; none for anything else.
    static func deviceType() -> String? {
        #if os(macOS)
        return "desktop"
        #else
        if ProcessInfo.processInfo.isMacCatalystApp { return "desktop" }
        if #available(iOS 14.0, tvOS 14.0, *), ProcessInfo.processInfo.isiOSAppOnMac { return "desktop" }
        return deviceType(model: Utils.modelIdentifier(), simulatorModel: ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"])
        #endif
    }

    /// The device kind of a model identifier, "iPhone17,1" or "iPad16,3", a simulator's by the model it simulates.
    static func deviceType(model: String?, simulatorModel: String?) -> String? {
        let name = (model?.hasPrefix("iOSSimulator") == true ? simulatorModel : model) ?? ""
        if name.hasPrefix("iPhone") || name.hasPrefix("iPod") { return "phone" }
        if name.hasPrefix("iPad") { return "tablet" }
        return nil
    }

    /// The join response field a node sends its codec policy in (1.0.3, WordPlus Mesh 1.0.33's `mesh.codec_policy`):
    /// one LiveKit's JoinResponse hasn't got, so any other client skips it.
    static let codecPolicyField: UInt64 = 1001

    /// The codec policy a join response's unknown fields carry (`codecPolicyField`), if any: only lists of names (eight,
    /// 16 characters each) and a name are kept, so whatever else a server sends can't reach a product's codec choice.
    static func codecPolicy(inJoinResponseUnknownFields data: Data) -> MeshCodecPolicy? {
        guard let raw = lengthDelimitedField(codecPolicyField, in: data),
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return nil }
        func names(_ value: Any?) -> [String]? {
            guard let list = value as? [Any] else { return nil }
            return Array(list.compactMap { $0 as? String }.filter { $0.count <= 16 }.prefix(8))
        }
        let backup = (object["backup"] as? String).flatMap { $0.count <= 16 ? $0 : nil }
        return MeshCodecPolicy(camera: names(object["camera"]), screen: names(object["screen"]), backup: backup)
    }

    /// The first length-delimited field `no` of a protobuf message's bytes, or nil when it has none or can't be read.
    static func lengthDelimitedField(_ no: UInt64, in data: Data) -> Data? {
        var at = data.startIndex

        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while at < data.endIndex, shift < 64 {
                let byte = data[at]
                at = data.index(after: at)
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }

        while at < data.endIndex {
            guard let tag = varint() else { return nil }
            let field = tag >> 3
            switch tag & 0x7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                at = data.index(at, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
            case 2:
                guard let length = varint(), let end = data.index(at, offsetBy: Int(length), limitedBy: data.endIndex) else { return nil }
                if field == no { return Data(data[at ..< end]) }
                at = end
            case 5:
                at = data.index(at, offsetBy: 4, limitedBy: data.endIndex) ?? data.endIndex
            default:
                return nil
            }
        }
        return nil
    }

    /// A length-delimited field's bytes as a message carries it: its tag, its length, then the data (1.0.3's encoder
    /// reports go so, in a request with no message of LiveKit's).
    static func lengthDelimited(_ no: UInt64, _ data: Data) -> Data {
        func varint(_ value: UInt64) -> Data {
            var out = Data()
            var n = value
            while n >= 0x80 {
                out.append(UInt8(n & 0x7F) | 0x80)
                n >>= 7
            }
            out.append(UInt8(n))
            return out
        }
        return varint(no << 3 | 2) + varint(UInt64(data.count)) + data
    }

    /// The busy server to wait on: the home region's that frees first, another region's only if it had none.
    static func waitOn(_ busy: [(url: URL, region: String?, freeAt: Date)], home: String?) -> (url: URL, region: String?, freeAt: Date)? {
        let near = busy.filter { home != nil && $0.region == home }
        return (near.isEmpty ? busy : near).min { $0.freeAt < $1.freeAt }
    }

    /// The region list a node sent in a signal response (`regionsField`), or nil when the message is another.
    static func regions(inSignalMessage data: Data) -> [RegionInfo]? {
        lengthDelimitedField(regionsField, in: data).flatMap { regions(json: $0) }
    }

    /// A region list as `/settings/regions` answers it, each entry with the node it leads to: a mesh's carry `node`,
    /// which a stock client's parse refuses as an unknown field.
    static func regions(json data: Data) -> [RegionInfo]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["regions"] as? [[String: Any]] else { return nil }

        let regions: [RegionInfo] = list.compactMap { entry in
            guard let region = entry["region"] as? String, let url = entry["url"] as? String else { return nil }
            let distance: Int64 = if let text = entry["distance"] as? String { Int64(text) ?? 0 } else { (entry["distance"] as? NSNumber)?.int64Value ?? 0 }
            return RegionInfo(region: region, url: url, distance: distance, node: entry["node"] as? String)
        }

        return regions.isEmpty ? nil : regions
    }
}

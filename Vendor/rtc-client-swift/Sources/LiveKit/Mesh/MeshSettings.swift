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

// WordPlus Mesh (1.0.10): the settings a mesh node hands this client for its calls, from the mesh's settings document
// (the mesh's pkg/clientsettings), so a product takes its numbers from the server and not from its own constants. They
// come with the join response (field 1002) and again on a running call whenever they change (signal response field
// 102), the same JSON: {"rev": 57, "applyNow": true, "set": {"camera.capHeight": 720}, "probe": [...]}. A client takes
// each message whole: a setting the next one leaves out goes back to its default. Every value is checked again here,
// against the schema compiled in (MeshSettingsSchema.swift, generated from the mesh's schema.json): a key this client
// doesn't know is left out, a value of the wrong type is the key's default, a number outside its range is held to it.
// The device's own rules (which codecs it can send, VP8 in an encrypted room) stay the product's, above every value.

/// When a client takes a change of a setting: at once, at the next camera or screen turned on, at the next camera or
/// microphone open, at the next connect, or at the next call.
public enum MeshSettingClass: String, Sendable {
    case live
    case publish
    case capture
    case join
    case room
}

enum MeshSettingType: Sendable {
    case number
    case int
    case bool
    case enumeration
    case codecs
    case codecRules
    case layers
    case ints
}

/// One key of the schema (generated into MeshSettingsSchema.keys).
struct MeshSettingKey: Sendable {
    let type: MeshSettingType
    let keyClass: MeshSettingClass
    let min: Double?
    let max: Double?
    let values: [String]?
    let maxLength: Int
    let defaultJSON: String
}

/// The schema the client was built with: the keys, generated from the mesh's schema.json, and each key's default read
/// once from them.
enum MeshSettingsSchema {
    static let defaults: [String: MeshSettingValue] = {
        var out: [String: MeshSettingValue] = [:]
        for (name, key) in keys {
            guard let data = key.defaultJSON.data(using: .utf8),
                  let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let value = MeshSettings.check(any, as: key) else { continue }
            out[name] = value
        }
        return out
    }()
}

/// A camera ladder's layer: its height in lines, its bitrate and frame rate.
public struct MeshLayer: Sendable, Hashable {
    public let height: Int
    public let kbps: Int
    public let fps: Int

    public init(height: Int, kbps: Int, fps: Int) {
        self.height = height
        self.kbps = kbps
        self.fps = fps
    }
}

/// One of `camera.codecRules`: the camera's codec list for the machines whose given fields all match.
public struct MeshCodecRule: Sendable, Hashable {
    public let os: String?
    public let browser: String?
    public let gpu: String?
    public let device: String?
    public let camera: [String]
}

/// A node to measure the round trip to (`probe`, while `probe.enabled` is on for this client): one a region.
public struct MeshProbeTarget: Sendable, Hashable {
    public let region: String
    /// The node's origin over HTTP(S): its `/mesh/ping` is measured.
    public let url: URL
}

/// A setting's value, as checked.
public enum MeshSettingValue: Sendable, Hashable {
    case number(Double)
    case bool(Bool)
    case word(String)
    case names([String])
    case numbers([Int])
    case layers([MeshLayer])
    case codecRules([MeshCodecRule])
}

/// The settings a mesh node sent this client last (`Room.meshSettings`), each value checked against the schema, and
/// every key's default where the node set none.
public struct MeshSettings: Sendable, Hashable {
    /// The settings document's revision (0: the node holds none, and only overrides apply); the client reports it in
    /// its health report (`cfg`).
    public let rev: Int64
    /// The revision's publish settings may reach a camera or screen already on, by a republish (`MeshSettings
    /// .republishDelay`); without it they wait for its next turn on.
    public let applyNow: Bool
    /// What the node set, checked: the keys this client knows, with values their keys take.
    public let values: [String: MeshSettingValue]
    /// The nodes to measure the round trip to, one a region; empty unless `probe.enabled` is on for this client.
    public let probe: [MeshProbeTarget]

    /// No settings from any node: every key at its default.
    public static let none = MeshSettings(rev: 0, applyNow: false, values: [:], probe: [])

    public init(rev: Int64, applyNow: Bool, values: [String: MeshSettingValue], probe: [MeshProbeTarget]) {
        self.rev = rev
        self.applyNow = applyNow
        self.values = values
        self.probe = probe
    }

    /// Whether the node set the key (a key at its default is not set).
    public func isSet(_ key: String) -> Bool { values[key] != nil }

    /// A key's value: the node's, or its default; nil where the default is the client's own rule (null).
    public func value(_ key: String) -> MeshSettingValue? { values[key] ?? MeshSettingsSchema.defaults[key] }

    public func number(_ key: String) -> Double? {
        if case let .number(v)? = value(key) { return v }
        return nil
    }

    public func int(_ key: String) -> Int? { number(key).map { Int($0.rounded()) } }

    public func bool(_ key: String) -> Bool? {
        if case let .bool(v)? = value(key) { return v }
        return nil
    }

    public func word(_ key: String) -> String? {
        if case let .word(v)? = value(key) { return v }
        return nil
    }

    public func names(_ key: String) -> [String]? {
        if case let .names(v)? = value(key) { return v }
        return nil
    }

    public func numbers(_ key: String) -> [Int]? {
        if case let .numbers(v)? = value(key) { return v }
        return nil
    }

    public func layers(_ key: String) -> [MeshLayer]? {
        if case let .layers(v)? = value(key) { return v }
        return nil
    }

    public func codecRules(_ key: String) -> [MeshCodecRule]? {
        if case let .codecRules(v)? = value(key) { return v }
        return nil
    }

    /// Whether the server speaks for the key: it set it, or a settings document is in use (`rev` above 0), in which a
    /// key it doesn't set is the schema's default. Without either, a product keeps its own value for the key, so a
    /// client on a node with no document behaves as it did before it read settings.
    public func speaks(_ key: String) -> Bool { isSet(key) || rev > 0 }

    /// The reconnect waits (`reconnect.delaysMs`) in seconds, for `ConnectOptions.meshReconnectDelays`.
    public var reconnectDelays: [TimeInterval]? { numbers("reconnect.delaysMs").map { $0.map { Double($0) / 1000 } } }

    /// When a client takes a change of the key; nil for a key this client doesn't know.
    public static func keyClass(_ key: String) -> MeshSettingClass? { MeshSettingsSchema.keys[key]?.keyClass }

    /// The keys whose value (the node's or the default) differs from `other`'s.
    public func changed(from other: MeshSettings) -> Set<String> {
        Set(values.keys).union(other.values.keys).filter { value($0) != other.value($0) }
    }

    /// The live caps over the camera's encodings (`camera.capHeight`, `camera.capFps`, `camera.capKbps`), 0 for none.
    public var cameraCaps: MeshCaps {
        MeshCaps(height: max(0, int("camera.capHeight") ?? 0), fps: max(0, int("camera.capFps") ?? 0), kbps: max(0, int("camera.capKbps") ?? 0))
    }

    /// The degradation preference a word of `camera.degradation` names, nil for `default` (the publish's own).
    public static func degradation(_ word: String?) -> DegradationPreference? {
        switch word {
        case "balanced": .balanced
        case "maintain-framerate": .maintainFramerate
        case "maintain-resolution": .maintainResolution
        default: nil
        }
    }

    /// How long after a revision with `applyNow` this client re-publishes a camera or screen whose publish settings it
    /// changed: a moment within 60 s by its identity's hash, so a room doesn't switch all at once.
    public static func republishDelay(identity: String) -> TimeInterval {
        var hash: UInt32 = 2_166_136_261
        for byte in identity.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 60000) / 1000
    }

    // MARK: - Reading

    /// The settings a message's JSON holds, each value checked; nil when it isn't settings at all.
    public static func parse(_ data: Data) -> MeshSettings? {
        guard data.count <= 512 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rev = (object["rev"] as? NSNumber).flatMap({ isBoolean($0) ? nil : $0 })?.int64Value else { return nil }
        var values: [String: MeshSettingValue] = [:]
        if let set = object["set"] as? [String: Any] {
            for (name, raw) in set {
                guard let key = MeshSettingsSchema.keys[name], let value = check(raw, as: key) else { continue }
                values[name] = value
            }
        }
        var probe: [MeshProbeTarget] = []
        for entry in (object["probe"] as? [[String: Any]] ?? []).prefix(16) {
            guard let region = entry["region"] as? String, isRegionName(region),
                  let text = entry["url"] as? String, let url = probeOrigin(text) else { continue }
            probe.append(MeshProbeTarget(region: region, url: url))
        }
        return MeshSettings(rev: max(0, rev), applyNow: jsonBoolean(object["applyNow"]) == true, values: values, probe: probe)
    }

    /// A value as its key takes it, or nil where it doesn't (the default then applies): numbers held to the range,
    /// whole where the key wants whole, a word of the key's in its spelling, codecs the client knows.
    static func check(_ raw: Any, as key: MeshSettingKey) -> MeshSettingValue? {
        func number(_ any: Any) -> Double? {
            guard let n = any as? NSNumber, !isBoolean(n) else { return nil }
            let v = n.doubleValue
            return v.isFinite ? v : nil
        }
        func held(_ v: Double, whole: Bool) -> Double {
            var out = whole ? v.rounded() : v
            if let lo = key.min { out = Swift.max(out, lo) }
            if let hi = key.max { out = Swift.min(out, hi) }
            return out
        }
        switch key.type {
        case .number, .int:
            return number(raw).map { .number(held($0, whole: key.type == .int)) }
        case .bool:
            return jsonBoolean(raw).map { .bool($0) }
        case .enumeration:
            guard let word = (raw as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
            return key.values?.first { $0.caseInsensitiveCompare(word) == .orderedSame }.map { .word($0) }
        case .codecs:
            let list = codecs(raw)
            return list.isEmpty ? nil : .names(list)
        case .codecRules:
            guard let list = raw as? [Any] else { return nil }
            var rules: [MeshCodecRule] = []
            for entry in list.prefix(16) {
                guard let rule = entry as? [String: Any] else { continue }
                let camera = codecs(rule["camera"] ?? [])
                guard !camera.isEmpty else { continue }
                func word(_ name: String) -> String? {
                    (rule[name] as? String).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.count > 16 ? nil : $0 }
                }
                rules.append(MeshCodecRule(os: word("os"), browser: word("browser"), gpu: word("gpu"), device: word("device"), camera: camera))
            }
            return .codecRules(rules)
        case .layers:
            guard let list = raw as? [Any], !list.isEmpty, key.maxLength == 0 || list.count <= key.maxLength else { return nil }
            var layers: [MeshLayer] = []
            for entry in list {
                guard let layer = entry as? [String: Any], let h = layer["h"].flatMap(number), let kbps = layer["kbps"].flatMap(number),
                      let fps = layer["fps"].flatMap(number) else { return nil }
                let next = MeshLayer(height: Int(Swift.min(Swift.max(h.rounded(), 90), 2160)),
                                     kbps: Int(Swift.min(Swift.max(kbps.rounded(), 30), 20000)),
                                     fps: Int(Swift.min(Swift.max(fps.rounded(), 1), 60)))
                if let last = layers.last, next.height <= last.height { return nil }
                layers.append(next)
            }
            return .layers(layers)
        case .ints:
            guard let list = raw as? [Any], !list.isEmpty, key.maxLength == 0 || list.count <= key.maxLength else { return nil }
            var out: [Int] = []
            for entry in list {
                guard let v = number(entry) else { return nil }
                out.append(Int(held(v, whole: true)))
            }
            return .numbers(out)
        }
    }

    /// 1 to 8 codecs the client knows (vp8, h264, h265, vp9, av1, each with :hw or not), in lower case, none twice.
    static func codecs(_ raw: Any) -> [String] {
        guard let list = raw as? [Any] else { return [] }
        var out: [String] = []
        for entry in list {
            guard let text = entry as? String else { continue }
            let name = text.lowercased().trimmingCharacters(in: .whitespaces)
            let parts = name.split(separator: ":", omittingEmptySubsequences: false)
            guard ["vp8", "h264", "h265", "vp9", "av1"].contains(String(parts[0])), parts.count == 1 || (parts.count == 2 && parts[1] == "hw"),
                  !out.contains(name) else { continue }
            out.append(name)
            if out.count == 8 { break }
        }
        return out
    }

    static func isBoolean(_ n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }

    static func jsonBoolean(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, isBoolean(n) else { return nil }
        return n.boolValue
    }

    static func isRegionName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 40 && s.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "-" }
    }

    /// A probe target's origin over HTTP(S): a node's signal URL (wss://...) or its origin as given.
    static func probeOrigin(_ text: String) -> URL? {
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        switch components.scheme?.lowercased() {
        case "wss", "https": components.scheme = "https"
        case "ws", "http": components.scheme = "http"
        default: return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - Kept for the next connect

    /// How old the settings kept for a server may be when the next connect takes them.
    static let keptFor: TimeInterval = 7 * 24 * 3600

    static func keptName(_ url: URL) -> String? {
        url.host.map { "wordplus-mesh-settings:\($0.lowercased())" }
    }

    /// The settings this client last had from the server at `url`, at most 7 days old: what a product connects with,
    /// for the settings of the join and room classes, which a connect can't take from a node it hasn't reached yet.
    public static func cached(for url: URL, now: Date = Date(), defaults store: UserDefaults = .standard) -> MeshSettings? {
        guard let name = keptName(url), let kept = store.dictionary(forKey: name),
              let at = (kept["at"] as? NSNumber)?.doubleValue, now.timeIntervalSince1970 - at <= keptFor, at <= now.timeIntervalSince1970 + 60,
              let text = kept["settings"] as? String, let data = text.data(using: .utf8) else { return nil }
        return parse(data)
    }

    /// Keeps the settings the server at `url` sent, as it sent them.
    static func keep(_ data: Data, for url: URL, now: Date = Date(), defaults store: UserDefaults = .standard) {
        guard let name = keptName(url), let text = String(data: data, encoding: .utf8) else { return }
        store.set(["at": now.timeIntervalSince1970, "settings": text], forKey: name)
    }
}

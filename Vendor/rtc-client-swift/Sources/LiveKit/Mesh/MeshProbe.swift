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

/// WordPlus Mesh (1.0.10): the round trip from this device to each region's node, measured in the background while the
/// node's settings name the nodes (`MeshSettings.probe`, `probe.enabled`) and said on the next join (`mesh_rtt`), so
/// the mesh can place the client in its fastest region rather than the region of the node DNS led it to. Never on a
/// join's path: a join says what was measured before, for the network it is on, within `probe.cacheMin`.
///
/// Each node's `/mesh/ping` is asked once to open the connection, then `probe.samples` times on it, the fastest kept;
/// one region after the other, so the measures don't crowd each other.
actor MeshProbe {
    static let shared = MeshProbe()

    static let storeName = "wordplus-mesh-probe"

    private var running: Task<Void, Never>?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    /// The network a measure belongs to: the kind of interface the device uses now (Wi-Fi, cellular, wired), read from
    /// the system's current path, as coarse as the browser's own key (its connection's type and effective type). Not its
    /// address, which the path monitor learns a moment after it starts, so a measure and the join after it would name two.
    nonisolated static func network() -> String {
        ConnectivityListener.shared.activeInterfaceType().map { String(describing: $0) } ?? "none"
    }

    /// Measures the targets in the background, unless this network has a measure of the same regions that is still
    /// fresh, or a measure runs already.
    func measure(_ targets: [MeshProbeTarget], samples: Int, cacheMinutes: Int, defaults store: UserDefaults = .standard) {
        guard !targets.isEmpty, running == nil else { return }
        let network = Self.network()
        let regions = Set(targets.map(\.region))
        if let kept = Self.kept(network: network, defaults: store), Set(kept.keys) == regions { return }
        let samples = min(max(samples, 1), 10)
        running = Task { [session] in
            var rtt: [String: Int] = [:]
            for target in targets.prefix(16) {
                if Task.isCancelled { break }
                if let ms = await Self.roundTrip(to: target.url, samples: samples, session: session) { rtt[target.region] = ms }
            }
            if !rtt.isEmpty { Self.keep(rtt, network: network, minutes: cacheMinutes, defaults: store) }
            self.done()
        }
    }

    private func done() { running = nil }

    /// The fastest of `samples` asks of the node's `/mesh/ping` on an open connection, whole ms from 1 to 5000; nil when
    /// the node doesn't answer.
    static func roundTrip(to origin: URL, samples: Int, session: URLSession) async -> Int? {
        let url = origin.appendingPathComponent("mesh/ping")
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 3)
        guard (try? await session.data(for: request)) != nil else { return nil }
        var best: TimeInterval?
        for _ in 0 ..< samples {
            let start = Date()
            guard (try? await session.data(for: request)) != nil else { continue }
            let took = Date().timeIntervalSince(start)
            best = min(best ?? took, took)
        }
        return best.map { min(max(Int(($0 * 1000).rounded()), 1), 5000) }
    }

    /// What this network measured, by region, while fresh.
    nonisolated static func kept(network: String, now: Date = Date(), defaults store: UserDefaults = .standard) -> [String: Int]? {
        guard let all = store.dictionary(forKey: storeName), let entry = all[network] as? [String: Any],
              let at = (entry["at"] as? NSNumber)?.doubleValue, let minutes = (entry["minutes"] as? NSNumber)?.doubleValue,
              now.timeIntervalSince1970 - at <= minutes * 60, let rtt = entry["rtt"] as? [String: NSNumber] else { return nil }
        return rtt.mapValues(\.intValue)
    }

    /// The newest measure still fresh, of whichever network.
    nonisolated static func freshest(now: Date = Date(), defaults store: UserDefaults = .standard) -> [String: Int]? {
        guard let all = store.dictionary(forKey: storeName) else { return nil }
        return all.keys.compactMap { network -> (at: Double, rtt: [String: Int])? in
            guard let rtt = kept(network: network, now: now, defaults: store),
                  let at = ((all[network] as? [String: Any])?["at"] as? NSNumber)?.doubleValue else { return nil }
            return (at, rtt)
        }.max { $0.at < $1.at }?.rtt
    }

    nonisolated static func keep(_ rtt: [String: Int], network: String, minutes: Int, now: Date = Date(), defaults store: UserDefaults = .standard) {
        var all = store.dictionary(forKey: storeName) ?? [:]
        // only the networks measured within the day are kept beside this one
        all = all.filter { (($0.value as? [String: Any])?["at"] as? NSNumber).map { now.timeIntervalSince1970 - $0.doubleValue < 86400 } ?? false }
        all[network] = ["at": now.timeIntervalSince1970, "minutes": min(max(minutes, 1), 1440), "rtt": rtt]
        store.set(all, forKey: storeName)
    }

    /// What a join says (`mesh_rtt`): this network's fresh measure, "fr:12,lim:18", nil without one. Before the system has
    /// named the path ("none": a join right after the app starts, before the path monitor's first report), the freshest
    /// measure of any network: the first join after a cold start named none otherwise.
    nonisolated static func joinParam(network: String = network(), now: Date = Date(), defaults store: UserDefaults = .standard) -> String? {
        let measured = kept(network: network, now: now, defaults: store) ?? (network == "none" ? freshest(now: now, defaults: store) : nil)
        guard let rtt = measured, !rtt.isEmpty else { return nil }
        return rtt.keys.sorted().prefix(16).compactMap { region in
            MeshSettings.isRegionName(region) ? "\(region):\(min(max(rtt[region] ?? 0, 1), 5000))" : nil
        }.joined(separator: ",")
    }
}

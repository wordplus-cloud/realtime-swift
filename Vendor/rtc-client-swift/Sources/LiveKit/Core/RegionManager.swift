/*
 * Copyright 2026 LiveKit
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

// MARK: - RegionManager

actor RegionManager: Loggable {
    struct State {
        var lastRequested: Date?
        var all: [RegionInfo] = []
        var remaining: [RegionInfo] = []
        /// WordPlus Mesh: the list came over the signal connection, which a node sends again whenever the mesh's
        /// nodes change, so it isn't fetched.
        var signal = false
        /// WordPlus Mesh: nodes that said they are busy, left out of the servers tried next.
        var skippedNodes = Set<String>()
    }

    static let cacheInterval: TimeInterval = 30

    nonisolated let providedUrl: URL
    private var state = State()
    private var settingsFetchTask: Task<[RegionInfo], Error>?
    private var settingsFetchTaskId: UUID?

    init(providedUrl: URL) {
        self.providedUrl = providedUrl
    }

    func cancel() {
        settingsFetchTask?.cancel()
        settingsFetchTask = nil
        settingsFetchTaskId = nil
    }

    func resetAttempts(onlyIfExhausted: Bool = false) {
        if onlyIfExhausted {
            guard state.remaining.isEmpty else { return }
        }
        state.skippedNodes.removeAll()
        guard !state.all.isEmpty else { return }
        state.remaining = state.all
    }

    // MARK: - WordPlus Mesh

    /// The region list a node sent over the signal connection, taken as it comes and never fetched while it does.
    func setSignalRegions(_ regions: [RegionInfo]) {
        let failed = Set(state.all).subtracting(state.remaining)
        log("[Region] Region list from the server (\(regions.count))", .debug)
        state.all = regions
        state.remaining = regions.filter { !failed.contains($0) }
        state.lastRequested = Date()
        state.signal = true
    }

    /// Whether a node sends this server's list over the signal connection.
    func hasSignalRegions() -> Bool {
        state.signal
    }

    /// A node that said it is busy, left out of the servers tried next until the attempts are reset.
    func skipNode(_ node: String) {
        state.skippedNodes.insert(node)
    }

    /// The region this client is nearest, the list's first.
    func homeRegion() -> String? {
        state.all.first?.regionId
    }

    /// A node's own entry in the list, by its id.
    func nodeEntry(_ node: String) -> RegionInfo? {
        state.all.first { $0.node == node }
    }

    /// The list, fetched if there is none yet; nothing changes if it can't be.
    func loadRegions(token: String) async {
        guard state.all.isEmpty else { return }
        try? await requestSettingsIfNeeded(token: token)
    }

    /// The best server not tried yet, leaving out a node (one that said it is busy). `skipUrl` (1.0.2) leaves out the
    /// entry at that server's address, the one that just failed; `preferNode` (1.0.2) gives that node's entry first
    /// while it is left, the node a session is on. Nil when there is none.
    func next(token: String, skipNode node: String?, skipUrl: URL? = nil, preferNode: String? = nil) async -> RegionInfo? {
        if let node { state.skippedNodes.insert(node) }
        try? await requestSettingsIfNeeded(token: token)
        let left = state.remaining.filter { region in
            (region.node == nil || !state.skippedNodes.contains(region.node!)) &&
                !(skipUrl.map { Mesh.sameServer(region.url, $0) } ?? false)
        }
        let found = (preferNode.flatMap { node in left.first { $0.node == node } }) ?? left.first
        if let found { state.remaining.removeAll { $0 == found } }
        return found
    }

    func resetAll() {
        state = State()
    }

    func markFailed(region: RegionInfo) {
        state.remaining.removeAll { $0 == region }
    }

    func shouldRequestSettings() -> Bool {
        guard providedUrl.isCloud else { return false }
        guard !state.signal else { return false }
        guard let lastRequested = state.lastRequested else { return true }
        return Date().timeIntervalSince(lastRequested) > Self.cacheInterval
    }

    func prepareSettingsFetch(token: String) {
        guard shouldRequestSettings() else { return }
        _ = startSettingsFetchIfNeeded(token: token)
    }

    /// The best region still worth trying, or `nil` once every region has been marked failed.
    ///
    /// Exhaustion is a `nil` result rather than a thrown error so callers can tell it apart from a
    /// failure to fetch or parse the region settings, which still throws `.regionManager`. The
    /// failover loop needs that distinction: on exhaustion it is holding the connection error that
    /// drove it there, and that error — a 403 the server explained — is what the caller needs, not
    /// "No more remaining regions."
    func resolveBest(token: String) async throws -> RegionInfo? {
        try await requestSettingsIfNeeded(token: token)
        guard let selected = state.remaining.first else {
            log("[Region] No remaining regions to try", .debug)
            return nil
        }

        log("[Region] Resolved region: \(String(describing: selected))", .debug)
        return selected
    }

    func updateFromServerReportedRegions(_ regions: Livekit_RegionSettings) {
        guard providedUrl.isCloud else { return }
        // WordPlus Mesh: a leave's list has no node ids, which the list a node sends over the signal connection has.
        guard !state.signal else { return }

        let allRegions = regions.regions.compactMap { $0.toLKType() }
        guard !allRegions.isEmpty else { return }

        // Keep previously failed regions excluded when updating the list.
        let allIds = Set(state.all.map(\.regionId))
        let remainingIds = Set(state.remaining.map(\.regionId))
        let failedRegionIds = allIds.subtracting(remainingIds)

        let remainingRegions = allRegions.filter { !failedRegionIds.contains($0.regionId) }
        log("[Region] Updating regions from server-reported settings (\(allRegions.count)), remaining: \(remainingRegions.count)", .info)

        state.all = allRegions
        state.remaining = remainingRegions
        state.lastRequested = Date()
    }

    // MARK: - Testing

    func snapshot() -> State { state }

    func setStateForTesting(_ state: State) {
        self.state = state
    }

    // MARK: - Private

    private func startSettingsFetchIfNeeded(token: String) -> Task<[RegionInfo], Error> {
        if let task = settingsFetchTask { return task }

        let taskId = UUID()
        settingsFetchTaskId = taskId

        let task = Task { [providedUrl, token, taskId] in
            defer { clearSettingsFetchTask(matching: taskId) }
            do {
                let data = try await Self.fetchRegionSettings(providedUrl: providedUrl, token: token)
                let allRegions = try Self.parseRegionSettings(data: data)
                try Task.checkCancellation()
                applyFetchedRegions(allRegions)
                return allRegions
            } catch {
                log("[Region] Failed to fetch region settings: \(error)", .error)
                throw error
            }
        }

        settingsFetchTask = task
        return task
    }

    private func requestSettingsIfNeeded(token: String) async throws {
        guard providedUrl.isCloud else {
            throw LiveKitError(.onlyForCloud)
        }

        guard shouldRequestSettings() else { return }
        let task = startSettingsFetchIfNeeded(token: token)
        do {
            _ = try await task.value
        } catch {
            // WordPlus Mesh: the refresh goes through the shared name, which after a crash may still lead to the
            // dead node: the last list stands rather than none.
            guard providedUrl.isMeshServer, !state.all.isEmpty, !(error is CancellationError) else { throw error }
            log("[Region] Region list unreachable, using the last one", .info)
        }
    }

    private func applyFetchedRegions(_ allRegions: [RegionInfo]) {
        log("[Region] all regions: \(String(describing: allRegions))", .debug)

        // Failed regions stay excluded across a refresh, matching
        // ``updateFromServerReportedRegions``. Resetting `remaining` to every region here would
        // refill the list from inside the failover loop: once per-region failure takes longer than
        // `cacheInterval`, the refresh puts regions back faster than `markFailed` removes them and
        // the loop never exhausts. `resetAttempts()` is what deliberately clears the failed set,
        // at the start of a new connect.
        let failedRegionIds = Set(state.all.map(\.regionId))
            .subtracting(state.remaining.map(\.regionId))

        state.all = allRegions
        state.remaining = allRegions.filter { !failedRegionIds.contains($0.regionId) }
        state.lastRequested = Date()
    }

    private func clearSettingsFetchTask(matching taskId: UUID) {
        guard settingsFetchTaskId == taskId else { return }
        settingsFetchTaskId = nil
        settingsFetchTask = nil
    }

    // MARK: - Static helpers (non-isolated)

    private nonisolated static func fetchRegionSettings(providedUrl: URL, token: String) async throws -> Data {
        var request = URLRequest(url: providedUrl.regionSettingsUrl(),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        // WordPlus Mesh: a fetch that never answers counts as unreachable after a while, not after a minute.
        if providedUrl.isMeshServer { request.timeoutInterval = Mesh.requestTimeout }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.regionManager, message: "Failed to fetch region settings")
        }

        let statusCode = httpResponse.statusCode
        guard (200 ..< 300).contains(statusCode) else {
            let details = "HTTP \(statusCode): \(HTTP.describeErrorBody(data))"

            if (400 ..< 500).contains(statusCode) {
                throw LiveKitError(.validation, message: "Region settings error: \(details)")
            }

            throw LiveKitError(.regionManager, message: "Failed to fetch region settings: \(details)")
        }

        return data
    }

    /// Cloud region settings arrive as JSON over HTTPS; the nanopb-backed
    /// protocol layer has no JSON codec, so this endpoint is decoded with a
    /// Codable mirror of `livekit.RegionSettings`.
    private struct RegionSettingsJSON: Decodable {
        struct Region: Decodable {
            var region: String?
            var url: String?
            // proto3 JSON serializes int64 as a string; accept both.
            var distance: FlexibleInt64?
        }

        struct FlexibleInt64: Decodable {
            var value: Int64
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int64.self) {
                    value = number
                } else {
                    value = try Int64(container.decode(String.self)) ?? 0
                }
            }
        }

        var regions: [Region]?
    }

    private nonisolated static func parseRegionSettings(data: Data) throws -> [RegionInfo] {
        // WordPlus Mesh: a mesh's entries carry `node`, an unknown field to the protobuf parse below.
        if let regions = Mesh.regions(json: data) { return regions }

        do {
            let json = try JSONDecoder().decode(RegionSettingsJSON.self, from: data)
            let allRegions = (json.regions ?? []).compactMap { region in
                Livekit_RegionInfo.with {
                    $0.region = region.region ?? ""
                    $0.url = region.url ?? ""
                    $0.distance = region.distance?.value ?? 0
                }.toLKType()
            }
            guard !allRegions.isEmpty else {
                throw LiveKitError(.regionManager, message: "Fetched region data is empty.")
            }
            return allRegions
        } catch {
            throw LiveKitError(.regionManager, message: "Failed to parse region settings with error: \(error)")
        }
    }
}

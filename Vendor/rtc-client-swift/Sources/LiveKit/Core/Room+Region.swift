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

// MARK: - Room+Region

extension Room {
    // MARK: - Internal

    func regionManager(for providedUrl: URL) async -> RegionManager? {
        guard providedUrl.isCloud, providedUrl.host != nil else {
            let old = _regionManager.mutate { manager -> RegionManager? in
                let old = manager
                manager = nil
                return old
            }
            if let old { await old.cancel() }
            return nil
        }

        let (manager, old) = _regionManager.mutate { current -> (RegionManager, RegionManager?) in
            if let manager = current, manager.providedUrl.matchesRegionManagerKey(of: providedUrl) {
                return (manager, nil)
            }

            let old = current
            let manager = RegionManager(providedUrl: providedUrl)
            current = manager
            return (manager, old)
        }

        if let old { await old.cancel() }
        return manager
    }

    // MARK: - Public

    // prepareConnection should be called as soon as the page is loaded, in order
    // to speed up the connection attempt.
    //
    // With LiveKit Cloud, it will also determine the best edge data center for
    // the current client to connect to if a token is provided.
    public func prepareConnection(url providedUrlString: String, token: String? = nil) async throws {
        // Must be in disconnected state.
        guard _state.connectionState == .disconnected else {
            throw LiveKitError(.stateMismatch, message: "Cannot prepare connection when in state \(_state.connectionState)")
        }

        guard let providedUrl = URL(string: providedUrlString), providedUrl.isValidForConnect else {
            throw LiveKitError(.failedToParseUrl, message: "Invalid URL: \(providedUrlString)")
        }

        log("Preparing connection to \(providedUrlString)")

        if providedUrl.isCloud, let token {
            _state.mutate {
                $0.providedUrl = providedUrl
                $0.token = token
                $0.preparedRegion = nil
            }

            guard let regionManager = await regionManager(for: providedUrl) else {
                Task {
                    await HTTP.prewarmConnection(url: providedUrl)
                    log("Prepared connection to \(providedUrl)")
                }
                return
            }

            // Nothing to prewarm if every region has already been tried; the connect path will
            // surface why.
            if let bestRegion = try await regionManager.resolveBest(token: token) {
                _state.mutate { $0.preparedRegion = bestRegion }
                Task {
                    await HTTP.prewarmConnection(url: bestRegion.url)
                    log("Prepared connection to \(bestRegion.url)")
                }
            }
        } else {
            // Not cloud or no token, just warm the provided URL
            Task {
                await HTTP.prewarmConnection(url: providedUrl)
                log("Prepared connection to \(providedUrl)")
            }
        }
    }

    // MARK: - Internal

    func consumePreparedRegion(for providedUrl: URL) -> RegionInfo? {
        let snapshot = _state.read { (region: $0.preparedRegion, url: $0.providedUrl) }
        let isPreparedUrlMatching = if let existing = snapshot.url {
            existing.matchesRegionManagerKey(of: providedUrl)
        } else {
            false
        }

        if snapshot.region != nil, !isPreparedUrlMatching {
            log("Discarding prepared region, URL changed to \(providedUrl)", .info)
        }

        return _state.mutate { state -> RegionInfo? in
            let prepared = isPreparedUrlMatching ? snapshot.region : nil
            state.preparedRegion = nil
            return prepared
        }
    }

    /// Bounds ``connectWithCloudRegionFailover``, independently of how the region list is
    /// maintained.
    ///
    /// The list is refreshed from the server *inside* the loop, so termination must not rest on an
    /// invariant about how `remaining` is kept. rust-sdks gets this structurally — its fallback
    /// iterates a list fetched once (`for region_url in urls.iter()` in `livekit-signaling`), so
    /// nothing can refill it mid-loop. Until this loop is reshaped the same way, the cap is what
    /// guarantees `connect` returns rather than hangs. Comfortably above any real region count.
    private static let maxRegionFailoverAttempts = 10

    /// Connects using LiveKit Cloud region settings and fails over across regions on retryable errors.
    func connectWithCloudRegionFailover(
        regionManager: RegionManager,
        initialUrl: URL,
        initialRegion: RegionInfo?,
        token: String,
    ) async throws -> URL {
        if regionManager.providedUrl.isMeshServer {
            return try await connectWithMeshWalk(regionManager: regionManager, initialUrl: initialUrl, token: token)
        }

        var nextUrl = initialUrl
        var nextRegion = initialRegion
        var attempts = 0

        while true {
            do {
                try await fullConnectSequence(nextUrl, token)

                // Scope the failed set to this failover cycle. Regions excluded by `markFailed`
                // now survive a settings refresh, so without clearing them on success a region
                // that failed transiently before another one connected would stay excluded for
                // the life of the manager — and a later failover would skip it even once it
                // recovered. Only a successful *reconnect* used to clear them.
                await regionManager.resetAttempts()
                return nextUrl
            } catch {
                // Re-throw if is cancel.
                if error is CancellationError {
                    throw error
                }

                // Validation errors are terminal — another region will reject the same token the
                // same way — except for the 403 Cloud uses to signal project-level region pinning,
                // which is precisely the case region failover exists to recover from.
                // `isRetryableForRegionFailover` makes that distinction on the HTTP status.
                guard error.isRetryableForRegionFailover else {
                    throw error
                }

                if let region = nextRegion {
                    nextRegion = nil
                    log("Connect failed with region: \(region)")
                    await regionManager.markFailed(region: region)
                }

                try Task.checkCancellation()

                await cleanUp(isFullReconnect: true)

                // Counts regions resolved from the manager, not total connects — the provided URL
                // failed before any of them and must not consume part of the budget, or a project
                // with exactly this many regions would never reach its last one.
                attempts += 1
                guard attempts <= Self.maxRegionFailoverAttempts else {
                    log("Region failover giving up after \(attempts - 1) region attempts", .warning)
                    throw error
                }

                // Every way of failing to get another region surfaces the *connection* error:
                // exhaustion, and a failure to fetch or parse the region settings alike. The
                // caller asked to connect, not to look up regions, so replacing "the server
                // rejected your token with 403" by "no more remaining regions" or "failed to
                // parse region settings" loses the half they can act on. rust-sdks makes the same
                // call explicitly — it logs the lookup failure and returns the original connect
                // error rather than masking it.
                let nextCandidate: RegionInfo?
                do {
                    nextCandidate = try await regionManager.resolveBest(token: token)
                } catch is CancellationError {
                    // Cancellation is not a lookup failure: the caller asked to stop, and the
                    // loop's own guard above rethrows it rather than reporting a connect error.
                    throw CancellationError()
                } catch let lookupError {
                    log("Failed to resolve next region: \(lookupError); surfacing the connection error", .warning)
                    nextCandidate = nil
                }

                guard let region = nextCandidate else {
                    throw error
                }
                nextUrl = region.url
                nextRegion = region
            }
        }
    }

    /// WordPlus Mesh: a join on a mesh keeps trying until `ConnectOptions.meshJoinBudget`, as @wordplus/rtc-client's:
    /// - a node `busy` (past its entry rate or its CPU) is left out and the list's next server tried at once, its home
    ///   region's other nodes first; with every server busy, the join goes back to the home region's node that frees
    ///   first and waits there (`mesh_wait=1`), which keeps it a slot of its own;
    /// - a `slot` held for it, or a `full` cluster (a slot held), is come back to by that node's own name when its
    ///   Retry-After says;
    /// - a server that can't be reached is left for the list's next, and once every one has failed the join starts
    ///   over from the best after 1 to 3 s.
    /// A refusal of the token (401, 403) or a cancel ends it at once. `ConnectOptions.onMeshWait` hears each wait.
    func connectWithMeshWalk(regionManager: RegionManager, initialUrl: URL, token: String) async throws -> URL {
        let options = _state.connectOptions
        let deadline = Date().addingTimeInterval(options.meshJoinBudget)
        var busy: [(url: URL, region: String?, freeAt: Date)] = []
        var nextUrl = initialUrl

        while true {
            do {
                try await fullConnectSequence(nextUrl, token)
                return nextUrl
            } catch {
                if error is CancellationError { throw error }

                if let liveKitError = error as? LiveKitError, liveKitError.type == .validation || liveKitError.type == .cancelled {
                    throw liveKitError
                }

                try Task.checkCancellation()
                try checkStillJoining()

                await cleanUp(isFullReconnect: true)

                let tried = nextUrl
                let refusal = (error as? LiveKitError)?.meshRefusal

                if refusal?.kind == "busy", !tried.isMeshWait, Date() < deadline {
                    if let node = refusal?.node { await regionManager.skipNode(node) }

                    let next = await regionManager.next(token: token, skipNode: nil)
                    let entry: RegionInfo? = if let node = refusal?.node { await regionManager.nodeEntry(node) } else { nil }
                    let home = await regionManager.homeRegion()

                    busy.append((url: entry?.url ?? tried, region: entry?.regionId ?? home, freeAt: Date().addingTimeInterval(refusal?.retryAfter ?? 1)))

                    if let next {
                        log("[Mesh] Server busy, trying \(next.url)", .info)
                        nextUrl = next.url
                        continue
                    }

                    guard let waitOn = Mesh.waitOn(busy, home: home) else { throw error }

                    log("[Mesh] Every server busy, waiting for a slot on \(waitOn.url)", .info)
                    options.onMeshWait?(MeshWait(until: waitOn.freeAt, reason: .busy))
                    nextUrl = waitOn.url.withMeshWait()
                    continue
                }

                // Another server, unless the mesh said none has room.
                if refusal == nil, error.isRetryableForRegionFailover, let next = await regionManager.next(token: token, skipNode: nil) {
                    log("[Mesh] Connect to \(tried) failed, trying \(next.url)", .info)
                    nextUrl = next.url
                    continue
                }

                guard let retryIn = Mesh.joinRetry(error, deadline: deadline) else { throw error }

                let reason = refusal?.kind.flatMap { MeshWaitReason(rawValue: $0) } ?? .unreachable

                log("[Mesh] Connect failed (\(error)), trying again in \(String(format: "%.1f", retryIn)) s", .info)
                options.onMeshWait?(MeshWait(until: Date().addingTimeInterval(retryIn), reason: reason))

                try await Task.sleep(nanoseconds: UInt64(retryIn * 1_000_000_000))
                try checkStillJoining()

                if refusal?.kind == "slot" || refusal?.kind == "full" {
                    await regionManager.loadRegions(token: token)

                    let entry: RegionInfo? = if let node = refusal?.node { await regionManager.nodeEntry(node) } else { nil }

                    nextUrl = (entry?.url ?? tried).withMeshWait()
                } else {
                    nextUrl = initialUrl
                }

                await regionManager.resetAttempts()
                busy.removeAll()
            }
        }
    }

    /// WordPlus Mesh: the walk goes on only while the room is joining. `disconnect()` doesn't cancel a join that is
    /// under way, so a walk the app had left kept trying for the rest of its budget, minutes of it on a full mesh,
    /// and joined a room nobody was in any more.
    private func checkStillJoining() throws {
        guard case .connecting = _state.connectionState else {
            throw LiveKitError(.cancelled, message: "Left while joining")
        }
    }

    /// WordPlus Mesh: the region list fetched once a join is in, if its node hasn't sent it over the signal
    /// connection within `Mesh.regionsWait`: an older node, which doesn't. A failover then has a list to go on.
    func fetchMeshRegionsLate(providedUrl: URL, token: String) {
        guard providedUrl.isMeshServer else { return }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Mesh.regionsWait * 1_000_000_000))

            guard let self, case .connected = self._state.connectionState,
                  let regionManager = await self.regionManager(for: providedUrl),
                  !(await regionManager.hasSignalRegions()) else { return }

            self.log("[Region] No region list from the server, fetching it", .debug)
            await regionManager.loadRegions(token: token)
        }
    }

    /// WordPlus Mesh: the next resume goes to another server of the region list, only when its own server has
    /// stopped answering while that one answers (1.0.2, rtc-client 1.0.5, `Mesh.resumeMoves`): a client whose own
    /// network is down stays where it is. The mesh takes over a session it doesn't hold from the client's sync state,
    /// so the others see a freeze, not a leave, if it lands within the mesh's hold of the lost node's participants
    /// (15 s).
    ///
    /// Since 1.0.2 (rtc-client 1.0.12) the candidates are tried in turn, at most `Mesh.resumeMoveTries`, the node the
    /// session is on first and never the address that just failed. A drain moves a session by a resume that reaches
    /// the new node through the draining one, and the new node's answer names it as the client's node: 1.0.1 left
    /// exactly that node out ("the node this client was on") and took the dead node's own entry for the next server,
    /// so a phone whose address was a node removed after its drain spent a resume on the dead node and then landed on
    /// whichever node came next, not the one holding its session (a burst node's removal, 2026-10-20).
    func moveResumeToNextServer() async {
        guard let providedUrl = _state.providedUrl, providedUrl.isMeshServer,
              let token = _state.token,
              let regionManager = await regionManager(for: providedUrl) else { return }

        let failed = _state.read { $0.connectedUrl } ?? providedUrl
        let session = serverNodeId
        let ownProbe = Task { await Mesh.serverAnswers(failed) }
        var own: Bool?

        for _ in 0 ..< Mesh.resumeMoveTries {
            guard let next = await regionManager.next(token: token, skipNode: nil, skipUrl: failed, preferNode: session) else { break }
            async let other = Mesh.serverAnswers(next.url)
            let ownNow = await ownProbe.value
            own = ownNow
            if ownNow { break }
            if await Mesh.resumeMoves(ownAnswers: ownNow, nextAnswers: other) {
                log("[Mesh] Resuming on another server next: \(next.url), its own no longer answers", .warning)
                _state.mutate { $0.connectedUrl = next.url }
                return
            }
        }

        // the list's servers stay untried: the next failed resume asks again
        await regionManager.resetAttempts()
        let answers = if let own { own } else { await ownProbe.value }
        log(answers ? "[Mesh] Resuming on the same server: it still answers"
            : "[Mesh] Resuming on the same server: no server answers, this connection is down", .warning)
    }
}

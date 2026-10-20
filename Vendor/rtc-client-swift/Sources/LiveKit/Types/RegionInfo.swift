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

@objcMembers
public class RegionInfo: NSObject, @unchecked Sendable {
    let regionId: String
    let url: URL
    let distance: Int64
    /// WordPlus Mesh: the node this entry leads to, which a mesh's list names and a region of several nodes repeats
    /// its region for.
    let node: String?

    init?(region: String, url: String, distance: Int64, node: String? = nil) {
        guard let url = URL(string: url) else { return nil }
        regionId = region
        self.url = url
        self.distance = distance
        self.node = node?.isEmpty == false ? node : nil
    }

    // MARK: - Equal

    // A mesh's region of several nodes lists each under the same region, so an entry is its region and its node.
    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return regionId == other.regionId && node == other.node && url == other.url
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(regionId)
        hasher.combine(node)
        return hasher.finalize()
    }

    //

    override public var description: String {
        "RegionInfo(id: \(regionId), url: \(url), distance: \(distance)\(node.map { ", node: \($0)" } ?? ""))"
    }
}

extension Livekit_RegionInfo {
    func toLKType() -> RegionInfo? {
        RegionInfo(region: region,
                   url: url,
                   distance: distance)
    }
}

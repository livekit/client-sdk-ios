/*
 * Copyright 2024 LiveKit
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

@objc
public class RegionInfo: NSObject {
    let regionId: String
    let url: URL
    let distance: Int64

    init?(region: String, url: String, distance: Int64) {
        guard let url = URL(string: url) else { return nil }
        regionId = region
        self.url = url
        self.distance = distance
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return regionId == other.regionId
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(regionId)
        return hasher.finalize()
    }

    //

    override public var description: String {
        "RegionInfo(id: \(regionId), url: \(url), distance: \(distance))"
    }
}

extension Livekit_RegionInfo {
    func toLKType() -> RegionInfo? {
        RegionInfo(region: region,
                   url: url,
                   distance: distance)
    }
}

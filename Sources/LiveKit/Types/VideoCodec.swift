/*
 * Copyright 2023 LiveKit
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
public class VideoCodec: NSObject, Identifiable {
    public static let h264 = VideoCodec(id: "h264", backup: true)
    public static let vp8 = VideoCodec(id: "vp8", backup: true)
    public static let vp9 = VideoCodec(id: "vp9")
    public static let av1 = VideoCodec(id: "av1")

    public static let all: [VideoCodec] = [.h264, .vp8, .vp9, .av1]
    public static let allBackup: [VideoCodec] = [.h264, .vp8]

    // codec Id
    public let id: String
    // Whether the codec can be used as `backup`
    public let backup: Bool

    // Internal only
    init(id: String, backup: Bool = false) {
        self.id = id
        self.backup = backup
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return id == other.id
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(id)
        return hasher.finalize()
    }
}

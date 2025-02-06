/*
 * Copyright 2025 LiveKit
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
public final class ScreenShareCaptureOptions: NSObject, VideoCaptureOptions, Sendable {
    @objc
    public let dimensions: Dimensions

    @objc
    public let fps: Int

    /// Only used for macOS
    @objc
    public let showCursor: Bool

    @objc
    public let appAudio: Bool

    /// Use broadcast extension for screen capture (iOS only).
    ///
    /// If a broadcast extension has been properly configured, this defaults to `true`.
    ///
    @objc
    public let useBroadcastExtension: Bool

    @objc
    public let includeCurrentApplication: Bool

    public static let defaultToBroadcastExtension: Bool = {
        #if os(iOS)
        return BroadcastBundleInfo.hasExtension
        #else
        return false
        #endif
    }()

    public init(dimensions: Dimensions = .h1080_169,
                fps: Int = 30,
                showCursor: Bool = true,
                appAudio: Bool = true,
                useBroadcastExtension: Bool = defaultToBroadcastExtension,
                includeCurrentApplication: Bool = false)
    {
        self.dimensions = dimensions
        self.fps = fps
        self.showCursor = showCursor
        self.appAudio = appAudio
        self.useBroadcastExtension = useBroadcastExtension
        self.includeCurrentApplication = includeCurrentApplication
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return dimensions == other.dimensions &&
            fps == other.fps &&
            showCursor == other.showCursor &&
            appAudio == other.appAudio &&
            useBroadcastExtension == other.useBroadcastExtension &&
            includeCurrentApplication == other.includeCurrentApplication
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(dimensions)
        hasher.combine(fps)
        hasher.combine(showCursor)
        hasher.combine(appAudio)
        hasher.combine(useBroadcastExtension)
        hasher.combine(includeCurrentApplication)
        return hasher.finalize()
    }
}

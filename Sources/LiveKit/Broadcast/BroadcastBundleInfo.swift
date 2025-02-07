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

#if os(iOS)

import Foundation

enum BroadcastBundleInfo {
    /// Identifier of the app group shared by the primary app and broadcast extension.
    @BundleInfo("RTCAppGroupIdentifier")
    static var groupIdentifier: String?

    /// Bundle identifier of the broadcast extension.
    @BundleInfo("RTCScreenSharingExtension")
    static var screenSharingExtension: String?

    /// Path to the socket file used for interprocess communication.
    static var socketPath: SocketPath? {
        guard let groupIdentifier else { return nil }
        return Self.socketPath(for: groupIdentifier)
    }

    /// Whether or not a broadcast extension has been configured.
    static var hasExtension: Bool {
        socketPath != nil && screenSharingExtension != nil
    }

    private static let socketFileDescriptor = "rtc_SSFD"

    private static func socketPath(for groupIdentifier: String) -> SocketPath? {
        guard let sharedContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        else { return nil }
        let path = sharedContainer.appendingPathComponent(Self.socketFileDescriptor).path
        return SocketPath(path)
    }
}

#endif

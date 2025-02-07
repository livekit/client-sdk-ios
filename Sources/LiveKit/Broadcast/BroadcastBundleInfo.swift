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
    static var groupIdentifier: String? {
        if let override = groupIdentifierOverride { return override }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        let appBundleIdentifier = bundleIdentifier.dropSuffix(".\(extensionSuffix)") ?? bundleIdentifier
        return "group.\(appBundleIdentifier)"
    }
    
    /// Bundle identifier of the broadcast extension.
    static var screenSharingExtension: String? {
        if let override = screenSharingExtensionOverride { return override }
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return nil }
        return "\(bundleIdentifier).\(extensionSuffix)"
    }

    /// Path to the socket file used for interprocess communication.
    static var socketPath: String? {
        guard let groupIdentifier else { return nil }
        return Self.socketPath(for: groupIdentifier)
    }

    /// Whether or not a broadcast extension has been configured.
    static var hasExtension: Bool {
        socketPath != nil && screenSharingExtension != nil
    }
    
    @BundleInfo("RTCAppGroupIdentifier")
    private static var groupIdentifierOverride: String?

    @BundleInfo("RTCScreenSharingExtension")
    private static var screenSharingExtensionOverride: String?

    private static let extensionSuffix = "broadcast"
    private static let socketFileDescriptor = "rtc_SSFD"

    private static func socketPath(for groupIdentifier: String) -> String? {
        guard let sharedContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
        else { return nil }
        return sharedContainer.appendingPathComponent(Self.socketFileDescriptor).path
    }
}

private extension String {
    func dropSuffix(_ suffix: String) -> Self? {
        guard hasSuffix(suffix) else { return nil }
        let trailingIndex = index(endIndex, offsetBy: -suffix.count)
        return String(self[..<trailingIndex])
    }
}

#endif

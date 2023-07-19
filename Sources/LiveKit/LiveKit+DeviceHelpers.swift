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

import AVFoundation

extension LiveKit {

    /// Helper method to ensure authorization for video(camera) / audio(microphone) permissions in a single call.
    public static func ensureDeviceAccess(for types: Set<AVMediaType>) async -> Bool {

        assert(!types.isEmpty, "Please specify at least 1 type")

        for type in types {

            assert([.video, .audio].contains(type), "types must be .video or .audio")

            let status = AVCaptureDevice.authorizationStatus(for: type)
            switch status {
            case .notDetermined:
                if !(await AVCaptureDevice.requestAccess(for: type)) {
                    return false
                }
            case .restricted, .denied:
                return false
            case .authorized:
                // No action needed for authorized status.
                break
            @unknown default:
                fatalError("Unknown AVAuthorizationStatus")
            }
        }

        return true
    }
}

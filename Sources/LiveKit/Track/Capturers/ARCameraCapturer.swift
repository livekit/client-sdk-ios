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

#if os(visionOS)
import ARKit
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@available(visionOS 2.0, *)
public class ARCameraCapturer: VideoCapturer {
    /// Required authorization types for this capturerer to work.
    static let requiredAuthorizationTypes: [ARKitSession.AuthorizationType] = [.cameraAccess]

    private let capturer = RTC.createVideoCapturer()
    private let arKitSession = ARKitSession()
    private let cameraFrameProvider = CameraFrameProvider()

    /// The ``ARCaptureOptions`` used for this capturer.
    public let options: ARCameraCaptureOptions

    private var _captureTask: Task<Void, Never>?

    init(delegate: LKRTCVideoCapturerDelegate, options: ARCameraCaptureOptions) {
        self.options = options
        super.init(delegate: delegate)
    }

    override public func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()
        // Already started
        guard didStart else { return false }

        let cameraAccessStatus = await arKitSession.queryAuthorization(for: [.cameraAccess])

        switch cameraAccessStatus[.cameraAccess] {
        case .denied:
            // If camera access is denied, we can't continue.
            throw LiveKitError(.deviceAccessDenied)

        case .notDetermined:
            // Request authorization.
            let requestResult = await arKitSession.requestAuthorization(for: [.cameraAccess])
            if requestResult[.cameraAccess] != .allowed {
                throw LiveKitError(.deviceAccessDenied)
            }

        case .allowed:
            // Camera access is already allowed, continue.
            break

        default:
            // Handle any other potential cases, if necessary.
            throw LiveKitError(.deviceAccessDenied)
        }

        try await arKitSession.run([cameraFrameProvider])

        let formats = CameraVideoFormat.supportedVideoFormats(for: .main, cameraPositions: [.left])
        guard let firstFormat = formats.first else {
            throw LiveKitError(.invalidState)
        }

        guard let frameUpdates = cameraFrameProvider.cameraFrameUpdates(for: firstFormat) else {
            throw LiveKitError(.invalidState)
        }

        _captureTask = Task.detached { [weak self] in
            guard let self else { return }
            for await frame in frameUpdates {
                if let sample = frame.sample(for: .left) {
                    self.capture(pixelBuffer: sample.pixelBuffer,
                                 capturer: self.capturer,
                                 options: self.options)
                }
            }
        }

        return true
    }

    override public func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()
        // Already stopped
        guard didStop else { return false }

        arKitSession.stop()
        _captureTask?.cancel()
        _captureTask = nil

        return true
    }
}

@available(visionOS 2.0, *)
public extension LocalVideoTrack {
    /// Creates a track that can directly capture `CVPixelBuffer` or `CMSampleBuffer` for convienience
    static func createARCameraTrack(name: String = Track.cameraName,
                                    source: VideoTrack.Source = .camera,
                                    options: ARCameraCaptureOptions = ARCameraCaptureOptions(),
                                    reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: false)
        let capturer = ARCameraCapturer(delegate: videoSource, options: options)
        return LocalVideoTrack(name: name,
                               source: source,
                               capturer: capturer,
                               videoSource: videoSource,
                               reportStatistics: reportStatistics)
    }
}
#endif

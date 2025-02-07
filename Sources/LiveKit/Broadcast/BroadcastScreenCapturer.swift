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

#if canImport(UIKit)
import UIKit
#endif

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

class BroadcastScreenCapturer: BufferCapturer {
    private var receiver: BroadcastReceiver?

    override func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()

        guard didStart else { return false }

        let bounds = await UIScreen.main.bounds
        let width = bounds.size.width
        let height = bounds.size.height
        let screenDimension = Dimensions(width: Int32(width), height: Int32(height))

        // pre fill dimensions, so that we don't have to wait for the broadcast to start to get actual dimensions.
        // should be able to safely predict using actual screen dimensions.
        let targetDimensions = screenDimension
            .aspectFit(size: options.dimensions.max)
            .toEncodeSafeDimensions()

        set(dimensions: targetDimensions)
        return createReceiver()
    }

    private func createReceiver() -> Bool {
        guard receiver == nil else {
            return false
        }
        guard let socketPath = BroadcastBundleInfo.socketPath else {
            logger.error("Bundle settings improperly configured for screen capture")
            return false
        }
        Task { [weak self] in
            do {
                let receiver = try await BroadcastReceiver(socketPath: socketPath)
                logger.debug("Broadcast receiver connected")
                self?.receiver = receiver

                for try await sample in receiver.incomingSamples {
                    switch sample {
                    case let .image(imageBuffer, rotation):
                        self?.capture(imageBuffer, rotation: rotation)
                    }
                }
                logger.debug("Broadcast receiver closed")
            } catch {
                logger.error("Broadcast receiver error: \(error)")
            }
            _ = try? await self?.stopCapture()
        }
        return true
    }

    override func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }
        receiver?.close()
        return true
    }
}

public extension LocalVideoTrack {
    /// Creates a track that captures screen capture from a broadcast upload extension
    static func createBroadcastScreenCapturerTrack(name: String = Track.screenShareVideoName,
                                                   source: VideoTrack.Source = .screenShareVideo,
                                                   options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                                   reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = BroadcastScreenCapturer(delegate: videoSource, options: BufferCaptureOptions(from: options))
        return LocalVideoTrack(
            name: name,
            source: source,
            capturer: capturer,
            videoSource: videoSource,
            reportStatistics: reportStatistics
        )
    }
}

#endif

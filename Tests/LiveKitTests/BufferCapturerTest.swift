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

import AVFoundation
@testable import LiveKit
import XCTest

@available(iOS 15.0, *)
class BufferCapturerTest: XCTestCase {
    func testPublishBufferTrack() async throws {
        try await with2Rooms { room1, room2 in

            let targetDimensions: Dimensions = .h1080_169

            let bufferTrack = LocalVideoTrack.createBufferTrack(
                options: BufferCaptureOptions(dimensions: targetDimensions)
            )

            let bufferCapturer = bufferTrack.capturer as! BufferCapturer

            let captureTask = try await self.createSampleVideoTrack { buffer in
                bufferCapturer.capture(buffer)
            }

            try await room1.localParticipant.publish(videoTrack: bufferTrack)

            guard let publisherIdentity = room1.localParticipant.identity else {
                XCTFail("Publisher's identity is nil")
                return
            }

            // Get publisher's participant
            guard let remoteParticipant = room2.remoteParticipants[publisherIdentity] else {
                XCTFail("Failed to lookup Publisher (RemoteParticipant)")
                return
            }

            // Set up expectation...
            let didSubscribeToRemoteVideoTrack = self.expectation(description: "Did subscribe to remote video track")
            didSubscribeToRemoteVideoTrack.assertForOverFulfill = false

            var remoteVideoTrack: RemoteVideoTrack?

            // Start watching RemoteParticipant for audio track...
            let watchParticipant = remoteParticipant.objectWillChange.sink { _ in
                if let track = remoteParticipant.videoTracks.first?.track as? RemoteVideoTrack, remoteVideoTrack == nil {
                    remoteVideoTrack = track
                    didSubscribeToRemoteVideoTrack.fulfill()
                }
            }

            // Wait for track...
            print("Waiting for first video track...")
            await self.fulfillment(of: [didSubscribeToRemoteVideoTrack], timeout: 30)

            guard let remoteVideoTrack else {
                XCTFail("RemoteVideoTrack is nil")
                return
            }

            // Received RemoteAudioTrack...
            print("remoteVideoTrack: \(String(describing: remoteVideoTrack))")

            let videoTrackWatcher = VideoTrackWatcher(id: "watcher01")
            remoteVideoTrack.add(videoRenderer: videoTrackWatcher)
            remoteVideoTrack.add(delegate: videoTrackWatcher)

            print("Waiting for target dimensions: \(targetDimensions)")
            let expectTargetDimensions = videoTrackWatcher.expect(dimensions: targetDimensions)
            await self.fulfillment(of: [expectTargetDimensions], timeout: 30)
            print("Did render target dimensions: \(targetDimensions)")

            // Wait until finish reading buffer...
            try await captureTask.value
            // Clean up
            watchParticipant.cancel()
        }
    }
}

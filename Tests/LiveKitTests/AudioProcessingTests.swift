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

import Accelerate
import AVFoundation
import Foundation
import LiveKitWebRTC

@testable import LiveKit
import XCTest

class AudioProcessingTests: XCTestCase, AudioCustomProcessingDelegate {
    var _initSampleRate: Double = 0.0
    var _initChannels: Int = 0

    func audioProcessingInitialize(sampleRate: Int, channels: Int) {
        // 48000, 1
        print("sampleRate: \(sampleRate), channels: \(channels)")
        _initSampleRate = Double(sampleRate)
        _initChannels = channels
    }

    func audioProcessingProcess(audioBuffer: LiveKit.LKAudioBuffer) {
        guard let pcm = audioBuffer.toAVAudioPCMBuffer() else {
            XCTFail("Failed to convert audio buffer to AVAudioPCMBuffer")
            return
        }

        print("pcm: \(pcm), " + "sampleRate: \(pcm.format.sampleRate), " + "channels: \(pcm.format.channelCount), " + "frameLength: \(pcm.frameLength), " + "frameCapacity: \(pcm.frameCapacity)")

        XCTAssert(pcm.format.sampleRate == _initSampleRate)
        XCTAssert(pcm.format.channelCount == _initChannels)
    }

    func audioProcessingRelease() {
        //
    }

    func testConvertAudioBufferToPCM() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            // Alias to Room1
            let room1 = rooms[0]
            // Set processing delegate
            AudioManager.shared.capturePostProcessingDelegate = self
            // Publish mic
            try await room1.localParticipant.setMicrophone(enabled: true)
            // 3 secs...
            let ns = UInt64(5 * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
        }
    }

    func testOptionsAppliedToAudioProcessingModule() async throws {
        try await withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
            // Alias to Room1
            let room1 = rooms[0]

            let allOnOptions = AudioCaptureOptions(
                echoCancellation: true,
                noiseSuppression: true,
                autoGainControl: true,
                highpassFilter: true
            )

            let allOffOptions = AudioCaptureOptions(
                echoCancellation: false,
                noiseSuppression: false,
                autoGainControl: false,
                highpassFilter: false
            )

            let pub1 = try await room1.localParticipant.setMicrophone(enabled: true, captureOptions: allOnOptions)
            guard let pub1 else {
                XCTFail("Publication is nil")
                return
            }

            let ns = UInt64(3 * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)

            // Directly read config from the apm
            let allOnConfigResult = RTC.audioProcessingModule.config
            print("Config result for all on: \(allOnConfigResult.toDebugString()))")
            XCTAssert(allOnConfigResult.isEchoCancellationEnabled)
            XCTAssert(allOnConfigResult.isNoiseSuppressionEnabled)
            XCTAssert(allOnConfigResult.isAutoGainControl1Enabled)
            XCTAssert(allOnConfigResult.isHighpassFilterEnabled)

            try await room1.localParticipant.unpublish(publication: pub1)

            let pub2 = try await room1.localParticipant.setMicrophone(enabled: true, captureOptions: allOffOptions)
            guard let pub2 else {
                XCTFail("Publication is nil")
                return
            }

            try await Task.sleep(nanoseconds: ns)

            // Directly read config from the apm
            let allOffConfigResult = RTC.audioProcessingModule.config
            print("Config result for all off: \(allOffConfigResult.toDebugString())")
            XCTAssert(!allOffConfigResult.isEchoCancellationEnabled)
            XCTAssert(!allOffConfigResult.isNoiseSuppressionEnabled)
            XCTAssert(!allOffConfigResult.isAutoGainControl1Enabled)
            XCTAssert(!allOffConfigResult.isHighpassFilterEnabled)

            try await room1.localParticipant.unpublish(publication: pub2)
        }
    }
}

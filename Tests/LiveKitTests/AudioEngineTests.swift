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

import AVFoundation
@testable import LiveKit
import LiveKitWebRTC
import XCTest

class AudioEngineTests: XCTestCase {
    override class func setUp() {
        LiveKitSDK.setLoggerStandardOutput()
        RTCSetMinDebugLogLevel(.info)
    }

    override func tearDown() async throws {}

    #if !targetEnvironment(simulator)
    // Test if mic is authorized. Only works on device.
    func testMicAuthorized() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != .authorized {
            let result = await AVCaptureDevice.requestAccess(for: .audio)
            XCTAssert(result)
        }

        XCTAssert(status == .authorized)
    }
    #endif

    // Test if state transitions pass internal checks.
    func testStateTransitions() async {
        let adm = AudioManager.shared
        // Start Playout
        adm.initPlayout()
        XCTAssert(adm.isPlayoutInitialized)
        adm.startPlayout()
        XCTAssert(adm.isPlaying)

        // Start Recording
        adm.initRecording()
        XCTAssert(adm.isRecordingInitialized)
        adm.startRecording()
        XCTAssert(adm.isRecording)

        // Stop engine
        adm.stopRecording()
        XCTAssert(!adm.isRecording)
        XCTAssert(!adm.isRecordingInitialized)

        adm.stopPlayout()
        XCTAssert(!adm.isPlaying)
        XCTAssert(!adm.isPlayoutInitialized)
    }

    func testRecordingAlwaysPreparedMode() async {
        let adm = AudioManager.shared

        // Ensure initially not initialized.
        XCTAssert(!adm.isRecordingInitialized)

        // Ensure recording is initialized after set to true.
        adm.isRecordingAlwaysPrepared = true
        XCTAssert(adm.isRecordingInitialized)

        adm.startRecording()
        XCTAssert(adm.isRecordingInitialized)

        // Should be still initialized after stopRecording() is called.
        adm.stopRecording()
        XCTAssert(adm.isRecordingInitialized)
    }

    func testConfigureDucking() async {
        AudioManager.shared.isAdvancedDuckingEnabled = false
        XCTAssert(!AudioManager.shared.isAdvancedDuckingEnabled)

        AudioManager.shared.isAdvancedDuckingEnabled = true
        XCTAssert(AudioManager.shared.isAdvancedDuckingEnabled)

        if #available(iOS 17, macOS 14.0, visionOS 1.0, *) {
            AudioManager.shared.duckingLevel = .default
            XCTAssert(AudioManager.shared.duckingLevel == .default)

            AudioManager.shared.duckingLevel = .min
            XCTAssert(AudioManager.shared.duckingLevel == .min)

            AudioManager.shared.duckingLevel = .max
            XCTAssert(AudioManager.shared.duckingLevel == .max)

            AudioManager.shared.duckingLevel = .mid
            XCTAssert(AudioManager.shared.duckingLevel == .mid)
        }
    }

    // Test start generating local audio buffer without joining to room.
    func testPrejoinLocalAudioBuffer() async throws {
        // Set up expectation...
        let didReceiveAudioFrame = expectation(description: "Did receive audio frame")
        didReceiveAudioFrame.assertForOverFulfill = false

        // Start watching for audio frame...
        let audioFrameWatcher = AudioTrackWatcher(id: "notifier01") { _ in
            didReceiveAudioFrame.fulfill()
        }

        let localMicTrack = LocalAudioTrack.createTrack()
        // Attach audio frame watcher...
        localMicTrack.add(audioRenderer: audioFrameWatcher)

        Task.detached {
            print("Starting audio track in 3 seconds...")
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            AudioManager.shared.startLocalRecording()
        }

        // Wait for audio frame...
        print("Waiting for first audio frame...")
        await fulfillment(of: [didReceiveAudioFrame], timeout: 10)

        // Remove audio frame watcher...
        localMicTrack.remove(audioRenderer: audioFrameWatcher)
    }

    // Test the manual rendering mode (no-device mode) of AVAudioEngine based AudioDeviceModule.
    // In manual rendering, no device access will be initialized such as mic and speaker.
    func testManualRenderingMode() async throws {
        // Set manual rendering mode...
        AudioManager.shared.isManualRenderingMode = true
        // Attach sine wave generator when engine requests input node.
        // inputMixerNode will automatically convert to RTC's internal format (int16).
        AudioManager.shared.set(engineObservers: [RewriteInputToSineWaveGenerator()])

        // Check if manual rendering mode is set...
        let isManualRenderingMode = AudioManager.shared.isManualRenderingMode
        print("manualRenderingMode: \(isManualRenderingMode)")
        XCTAssert(isManualRenderingMode)

        let recorder = try AudioRecorder()

        // Note: AudioCaptureOptions will not be applied since track is not published.
        let track = LocalAudioTrack.createTrack(options: .noProcessing)
        track.add(audioRenderer: recorder)

        // Start engine...
        AudioManager.shared.startLocalRecording()

        // Render for 5 seconds...
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)

        recorder.close()
        print("Written to: \(recorder.filePath)")

        // Stop engine
        AudioManager.shared.stopRecording()

        // Play the recorded file...
        let player = try AVAudioPlayer(contentsOf: recorder.filePath)
        player.play()
        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
    }
}

final class RewriteInputToSineWaveGenerator: AudioEngineObserver {
    func setNext(_: any LiveKit.AudioEngineObserver) {}
    func engineWillConnectInput(_ engine: AVAudioEngine, src _: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat) -> Bool {
        print("engineWillConnectInput")
        let sin = SineWaveSourceNode()
        engine.attach(sin)
        engine.connect(sin, to: dst, format: format)
        return true
    }
}

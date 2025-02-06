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

@preconcurrency import AVFoundation
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
    func testPreconnectAudioBuffer() async throws {
        print("Setting recording always prepared mode...")
        AudioManager.shared.isRecordingAlwaysPrepared = true

        var counter = 0
        // Executes 10 times by default.
        measure {
            counter += 1
            print("Measuring attempt \(counter)...")
            // Set up expectation...
            let didReceiveAudioFrame = expectation(description: "Did receive audio frame")
            didReceiveAudioFrame.assertForOverFulfill = false

            let didConnectToRoom = expectation(description: "Did connect to room")
            didConnectToRoom.assertForOverFulfill = false

            // Create an audio frame watcher...
            let audioFrameWatcher = AudioTrackWatcher(id: "notifier01") { _ in
                didReceiveAudioFrame.fulfill()
            }

            let localMicTrack = LocalAudioTrack.createTrack()
            // Attach audio frame watcher...
            localMicTrack.add(audioRenderer: audioFrameWatcher)

            Task.detached {
                print("Starting local recording...")
                AudioManager.shared.startLocalRecording()
            }

            // Wait for audio frame...
            print("Waiting for first audio frame...")
            // await fulfillment(of: [didReceiveAudioFrame], timeout: 10)
            wait(for: [didReceiveAudioFrame], timeout: 30)

            Task.detached {
                print("Connecting to room...")
                try await self.withRooms([RoomTestingOptions(canPublish: true)]) { rooms in
                    print("Publishing mic...")
                    try await rooms[0].localParticipant.setMicrophone(enabled: true)
                    didConnectToRoom.fulfill()
                }
            }

            print("Waiting for room to connect & disconnect...")
            wait(for: [didConnectToRoom], timeout: 30)

            localMicTrack.remove(audioRenderer: audioFrameWatcher)
        }
    }

    // Test the manual rendering mode (no-device mode) of AVAudioEngine based AudioDeviceModule.
    // In manual rendering, no device access will be initialized such as mic and speaker.
    func testManualRenderingModeSineGenerator() async throws {
        // Set manual rendering mode...
        AudioManager.shared.isManualRenderingMode = true
        // Attach sine wave generator when engine requests input node.
        // inputMixerNode will automatically convert to RTC's internal format (int16).
        AudioManager.shared.set(engineObservers: [SineWaveNodeHook()])

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
        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
        }
    }

    func testManualRenderingModeAudioFile() async throws {
        // Sample audio
        let url = URL(string: "https://github.com/rafaelreis-hotmart/Audio-Sample-files/raw/refs/heads/master/sample.wav")!

        print("Downloading sample audio from \(url)...")
        let (downloadedLocalUrl, _) = try await URLSession.shared.downloadBackport(from: url)

        // Move the file to a new temporary location with a more descriptive name, if desired
        let tempLocalUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try FileManager.default.moveItem(at: downloadedLocalUrl, to: tempLocalUrl)
        print("Original file: \(tempLocalUrl)")

        let audioFile = try AVAudioFile(forReading: tempLocalUrl)
        let audioFileFormat = audioFile.processingFormat // AVAudioFormat object

        print("Sample Rate: \(audioFileFormat.sampleRate)")
        print("Channel Count: \(audioFileFormat.channelCount)")
        print("Common Format: \(audioFileFormat.commonFormat)")
        print("Interleaved: \(audioFileFormat.isInterleaved)")

        // Set manual rendering mode...
        AudioManager.shared.isManualRenderingMode = true

        let playerNodeHook = PlayerNodeHook(playerNodeFormat: audioFileFormat)
        AudioManager.shared.set(engineObservers: [playerNodeHook])

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

        let scheduleAndPlayTask = Task {
            print("Will scheduleFile")
            await playerNodeHook.playerNode.scheduleFile(audioFile, at: nil)
            print("Did scheduleFile")
        }

        // Wait for audio file to be consumed...
        playerNodeHook.playerNode.play()
        await scheduleAndPlayTask.value

        recorder.close()
        print("Processed file: \(recorder.filePath)")

        // Stop engine
        AudioManager.shared.stopRecording()

        // Play the recorded file...
        let player = try AVAudioPlayer(contentsOf: recorder.filePath)
        player.play()
        while player.isPlaying {
            try? await Task.sleep(nanoseconds: 1 * 100_000_000) // 10ms
        }
    }

    #if os(iOS) || os(visionOS) || os(tvOS)
    func testBackwardCompatibility() async throws {
        struct TestState {
            var trackState: AudioManager.TrackState = .none
        }
        let _testState = StateSync(TestState())

        AudioManager.shared.customConfigureAudioSessionFunc = { newState, oldState in
            print("New trackState: \(newState.trackState), Old trackState: \(oldState.trackState)")
            _testState.mutate { $0.trackState = newState.trackState }
        }

        // Configure session since we are setting a empty config func.
        let config = AudioSessionConfiguration.playAndRecordSpeaker
        let session = LKRTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        try session.setConfiguration(config.toRTCType(), active: true)
        session.unlockForConfiguration()

        XCTAssert(_testState.trackState == .none)

        AudioManager.shared.initPlayout()
        XCTAssert(_testState.trackState == .remoteOnly)

        AudioManager.shared.initRecording()
        XCTAssert(_testState.trackState == .localAndRemote)

        AudioManager.shared.stopRecording()
        XCTAssert(_testState.trackState == .remoteOnly)

        AudioManager.shared.stopPlayout()
        XCTAssert(_testState.trackState == .none)
    }

    func testDefaultAudioSessionConfiguration() async throws {
        AudioManager.shared.initPlayout()
        AudioManager.shared.initRecording()
        AudioManager.shared.stopRecording()
        AudioManager.shared.stopPlayout()
    }
    #endif
}

final class SineWaveNodeHook: AudioEngineObserver {
    var next: (any LiveKit.AudioEngineObserver)?

    let sineWaveNode = SineWaveSourceNode()

    func engineDidCreate(_ engine: AVAudioEngine) {
        engine.attach(sineWaveNode)
    }

    func engineWillRelease(_ engine: AVAudioEngine) {
        engine.detach(sineWaveNode)
    }

    func engineWillConnectInput(_ engine: AVAudioEngine, src _: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context _: [AnyHashable: Any]) {
        print("engineWillConnectInput")
        engine.connect(sineWaveNode, to: dst, format: format)
    }
}

final class PlayerNodeHook: AudioEngineObserver {
    var next: (any LiveKit.AudioEngineObserver)?

    public let playerNode = AVAudioPlayerNode()
    public let playerMixerNode = AVAudioMixerNode()
    public let playerNodeFormat: AVAudioFormat

    init(playerNodeFormat: AVAudioFormat) {
        self.playerNodeFormat = playerNodeFormat
    }

    public func engineDidCreate(_ engine: AVAudioEngine) {
        engine.attach(playerNode)
        engine.attach(playerMixerNode)
    }

    public func engineWillRelease(_ engine: AVAudioEngine) {
        engine.detach(playerNode)
        engine.detach(playerMixerNode)
    }

    func engineWillConnectInput(_ engine: AVAudioEngine, src _: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context _: [AnyHashable: Any]) {
        print("engineWillConnectInput")
        engine.connect(playerNode, to: playerMixerNode, format: playerNodeFormat)
        engine.connect(playerMixerNode, to: dst, format: format)
    }
}

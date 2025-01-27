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
import Combine

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Wrapper for LKRTCAudioBuffer
@objc
public class LKAudioBuffer: NSObject {
    private let _audioBuffer: LKRTCAudioBuffer

    @objc
    public var channels: Int { _audioBuffer.channels }

    @objc
    public var frames: Int { _audioBuffer.frames }

    @objc
    public var framesPerBand: Int { _audioBuffer.framesPerBand }

    @objc
    public var bands: Int { _audioBuffer.bands }

    @objc
    @available(*, deprecated, renamed: "rawBuffer(forChannel:)")
    public func rawBuffer(for channel: Int) -> UnsafeMutablePointer<Float> {
        _audioBuffer.rawBuffer(forChannel: channel)
    }

    @objc
    public func rawBuffer(forChannel channel: Int) -> UnsafeMutablePointer<Float> {
        _audioBuffer.rawBuffer(forChannel: channel)
    }

    init(audioBuffer: LKRTCAudioBuffer) {
        _audioBuffer = audioBuffer
    }
}

// Audio Session Configuration related
public class AudioManager: Loggable {
    #if os(iOS)
    class AudioSessionDelegateObserver: NSObject, Loggable, LKRTCAudioSessionDelegate {
        func audioSessionDidStartPlayOrRecord(_: LKRTCAudioSession) {
            log()
        }

        func audioSession(_: LKRTCAudioSession, audioUnitWillInitialize isRecord: Bool) {
            log("isRecord: \(isRecord)")
            let config = LKRTCAudioSessionConfiguration.webRTC()
            config.category = AVAudioSession.Category.playAndRecord.rawValue
            config.categoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
            config.mode = AVAudioSession.Mode.videoChat.rawValue
            LKRTCAudioSessionConfiguration.setWebRTC(config)
        }

        func audioSessionDidStopPlayOrRecord(_: LKRTCAudioSession) {
            log()
        }
    }
    #endif

    // MARK: - Public

    #if compiler(>=6.0)
    public nonisolated(unsafe) static let shared = AudioManager()
    #else
    public static let shared = AudioManager()
    #endif

    public typealias DeviceUpdateFunc = (_ audioManager: AudioManager) -> Void
    public typealias OnSpeechUpdate = (_ audioManager: AudioManager, _ event: Int) -> Void

    #if os(iOS) || os(visionOS) || os(tvOS)

    public typealias ConfigureAudioSessionFunc = @Sendable (_ newState: State,
                                                            _ oldState: State) -> Void

    /// Use this to provide a custom function to configure the audio session, overriding the default behavior
    /// provided by ``defaultConfigureAudioSessionFunc(newState:oldState:)``.
    ///
    /// - Important: This method should return immediately and must not block.
    /// - Note: Once set, the following properties will no longer be effective:
    ///   - ``sessionConfiguration``
    ///   - ``isSpeakerOutputPreferred``
    ///
    /// If you want to revert to default behavior, set this to `nil`.
    public var customConfigureAudioSessionFunc: ConfigureAudioSessionFunc? {
        get { state.customConfigureFunc }
        set { state.mutate { $0.customConfigureFunc = newValue } }
    }

    /// Determines whether the device's built-in speaker or receiver is preferred for audio output.
    ///
    /// - Defaults to `true`, indicating that the speaker is preferred.
    /// - Set to `false` if the receiver is preferred instead of the speaker.
    /// - Note: This property only applies when the audio output is routed to the built-in speaker or receiver.
    ///
    /// This property is ignored if ``customConfigureAudioSessionFunc`` is set.
    public var isSpeakerOutputPreferred: Bool {
        get { state.isSpeakerOutputPreferred }
        set { state.mutate { $0.isSpeakerOutputPreferred = newValue } }
    }

    /// Specifies a fixed configuration for the audio session, overriding dynamic adjustments.
    ///
    /// If this property is set, it will take precedence over any dynamic configuration logic, including
    /// the value of ``isSpeakerOutputPreferred``.
    ///
    /// This property is ignored if ``customConfigureAudioSessionFunc`` is set.
    public var sessionConfiguration: AudioSessionConfiguration? {
        get { state.sessionConfiguration }
        set { state.mutate { $0.sessionConfiguration = newValue } }
    }
    #endif

    public enum TrackState {
        case none
        case localOnly
        case remoteOnly
        case localAndRemote
    }

    public struct State: Equatable, Sendable {
        // Only consider State mutated when public vars change
        public static func == (lhs: AudioManager.State, rhs: AudioManager.State) -> Bool {
            var isEqual = lhs.localTracksCount == rhs.localTracksCount &&
                lhs.remoteTracksCount == rhs.remoteTracksCount

            #if os(iOS) || os(visionOS) || os(tvOS)
            isEqual = isEqual &&
                lhs.isSpeakerOutputPreferred == rhs.isSpeakerOutputPreferred &&
                lhs.sessionConfiguration == rhs.sessionConfiguration
            #endif

            return isEqual
        }

        public var localTracksCount: Int = 0
        public var remoteTracksCount: Int = 0
        public var isSpeakerOutputPreferred: Bool = true
        #if os(iOS) || os(visionOS) || os(tvOS)
        // Keep this var within State so it's protected by UnfairLock
        public var customConfigureFunc: ConfigureAudioSessionFunc?
        public var sessionConfiguration: AudioSessionConfiguration?
        #endif

        public var trackState: TrackState {
            switch (localTracksCount > 0, remoteTracksCount > 0) {
            case (true, false): return .localOnly
            case (false, true): return .remoteOnly
            case (true, true): return .localAndRemote
            default: return .none
            }
        }
    }

    // MARK: - AudioProcessingModule

    private lazy var capturePostProcessingDelegateAdapter: AudioCustomProcessingDelegateAdapter = {
        let adapter = AudioCustomProcessingDelegateAdapter()
        RTC.audioProcessingModule.capturePostProcessingDelegate = adapter
        return adapter
    }()

    private lazy var renderPreProcessingDelegateAdapter: AudioCustomProcessingDelegateAdapter = {
        let adapter = AudioCustomProcessingDelegateAdapter()
        RTC.audioProcessingModule.renderPreProcessingDelegate = adapter
        return adapter
    }()

    let capturePostProcessingDelegateSubject = CurrentValueSubject<AudioCustomProcessingDelegate?, Never>(nil)

    /// Add a delegate to modify the local audio buffer before it is sent to the network
    /// - Note: Only one delegate can be set at a time, but you can create one to wrap others if needed
    /// - Note: If you only need to observe the buffer (rather than modify it), use ``add(localAudioRenderer:)`` instead
    public var capturePostProcessingDelegate: AudioCustomProcessingDelegate? {
        get { capturePostProcessingDelegateAdapter.target }
        set {
            capturePostProcessingDelegateAdapter.set(target: newValue)
            capturePostProcessingDelegateSubject.send(newValue)
        }
    }

    /// Add a delegate to modify the combined remote audio buffer (all tracks) before it is played to the user
    /// - Note: Only one delegate can be set at a time, but you can create one to wrap others if needed
    /// - Note: If you only need to observe the buffer (rather than modify it), use ``add(remoteAudioRenderer:)`` instead
    /// - Note: If you need to observe the buffer for individual tracks, use ``RemoteAudioTrack/add(audioRenderer:)`` instead
    public var renderPreProcessingDelegate: AudioCustomProcessingDelegate? {
        get { renderPreProcessingDelegateAdapter.target }
        set { renderPreProcessingDelegateAdapter.set(target: newValue) }
    }

    // MARK: - AudioDeviceModule

    public let defaultOutputDevice = AudioDevice(ioDevice: LKRTCIODevice.defaultDevice(with: .output))

    public let defaultInputDevice = AudioDevice(ioDevice: LKRTCIODevice.defaultDevice(with: .input))

    public var outputDevices: [AudioDevice] {
        RTC.audioDeviceModule.outputDevices.map { AudioDevice(ioDevice: $0) }
    }

    public var inputDevices: [AudioDevice] {
        RTC.audioDeviceModule.inputDevices.map { AudioDevice(ioDevice: $0) }
    }

    public var outputDevice: AudioDevice {
        get { AudioDevice(ioDevice: RTC.audioDeviceModule.outputDevice) }
        set { RTC.audioDeviceModule.outputDevice = newValue._ioDevice }
    }

    public var inputDevice: AudioDevice {
        get { AudioDevice(ioDevice: RTC.audioDeviceModule.inputDevice) }
        set { RTC.audioDeviceModule.inputDevice = newValue._ioDevice }
    }

    public var onDeviceUpdate: DeviceUpdateFunc? {
        didSet {
            RTC.audioDeviceModule.setDevicesDidUpdateCallback { [weak self] in
                guard let self else { return }
                self.onDeviceUpdate?(self)
            }
        }
    }

    public var onSpeechEvent: OnSpeechUpdate? {
        didSet {
            RTC.audioDeviceModule.setSpeechActivityCallback { [weak self] event in
                guard let self else { return }
                self.onSpeechEvent?(self, event.rawValue)
            }
        }
    }

    // MARK: - Internal

    enum `Type` {
        case local
        case remote
    }

    let state = StateSync(State())

    // MARK: - Private

    func trackDidStart(_ type: Type) async throws {
        state.mutate { state in
            if type == .local { state.localTracksCount += 1 }
            if type == .remote { state.remoteTracksCount += 1 }
        }
    }

    func trackDidStop(_ type: Type) async throws {
        state.mutate { state in
            if type == .local { state.localTracksCount = max(state.localTracksCount - 1, 0) }
            if type == .remote { state.remoteTracksCount = max(state.remoteTracksCount - 1, 0) }
        }
    }

    #if os(iOS)
    let _audioSessionDelegateObserver = AudioSessionDelegateObserver()

    init() {
        LKRTCAudioSession.sharedInstance().add(_audioSessionDelegateObserver)
    }

    deinit {
        LKRTCAudioSession.sharedInstance().remove(_audioSessionDelegateObserver)
    }
    #endif
}

public extension AudioManager {
    /// Add an ``AudioRenderer`` to receive pcm buffers from local input (mic).
    /// Only ``AudioRenderer/render(pcmBuffer:)`` will be called.
    /// Usage: `AudioManager.shared.add(localAudioRenderer: localRenderer)`
    func add(localAudioRenderer delegate: AudioRenderer) {
        capturePostProcessingDelegateAdapter.add(delegate: delegate)
    }

    func remove(localAudioRenderer delegate: AudioRenderer) {
        capturePostProcessingDelegateAdapter.remove(delegate: delegate)
    }
}

public extension AudioManager {
    /// Add an ``AudioRenderer`` to receive pcm buffers from combined remote audio.
    /// Only ``AudioRenderer/render(pcmBuffer:)`` will be called.
    /// To receive buffer for individual tracks, use ``RemoteAudioTrack/add(audioRenderer:)`` instead.
    /// Usage: `AudioManager.shared.add(remoteAudioRenderer: localRenderer)`
    func add(remoteAudioRenderer delegate: AudioRenderer) {
        renderPreProcessingDelegateAdapter.add(delegate: delegate)
    }

    func remove(remoteAudioRenderer delegate: AudioRenderer) {
        renderPreProcessingDelegateAdapter.remove(delegate: delegate)
    }
}

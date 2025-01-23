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

// Audio Session Configuration related
public class AudioManager: Loggable {
    // MARK: - Public

    #if compiler(>=6.0)
    public nonisolated(unsafe) static let shared = AudioManager()
    #else
    public static let shared = AudioManager()
    #endif

    public typealias DeviceUpdateFunc = (_ audioManager: AudioManager) -> Void

    public typealias OnSpeechActivityEvent = (_ audioManager: AudioManager, _ event: SpeechActivityEvent) -> Void

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

        public var engineObservers = [any AudioEngineObserver]()

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

    public var onDeviceUpdate: DeviceUpdateFunc?

    /// Detect voice activity even if the mic is muted.
    /// Internal audio engine must be initialized by calling ``prepareRecording()`` or
    /// connecting to a room and subscribing to a remote audio track or publishing a local audio track.
    public var onMutedSpeechActivityEvent: OnSpeechActivityEvent?

    public var isManualRenderingMode: Bool {
        get { RTC.audioDeviceModule.isManualRenderingMode }
        set {
            let result = RTC.audioDeviceModule.setManualRenderingMode(newValue)
            if !result {
                log("Failed to set manual rendering mode", .error)
            }
        }
    }

    /// Enables advanced ducking which ducks other audio based on the presence of voice activity from local and remote chat participants.
    /// Default: true.
    public var isAdvancedDuckingEnabled: Bool {
        get { RTC.audioDeviceModule.isAdvancedDuckingEnabled }
        set { RTC.audioDeviceModule.isAdvancedDuckingEnabled = newValue }
    }

    /// The ducking(audio reducing) level of other audio.
    @available(iOS 17, macOS 14.0, visionOS 1.0, *)
    public var duckingLevel: AudioDuckingLevel {
        get { AudioDuckingLevel(rawValue: RTC.audioDeviceModule.duckingLevel) ?? .default }
        set { RTC.audioDeviceModule.duckingLevel = newValue.rawValue }
    }

    // MARK: - Recording

    /// Keep recording initialized (mic input) and pre-warm voice processing etc.
    /// Mic permission is required and dialog will appear if not already granted.
    /// This will per persisted accross Rooms and connections.
    public var isRecordingAlwaysPrepared: Bool {
        get { RTC.audioDeviceModule.isInitRecordingPersistentMode }
        set { RTC.audioDeviceModule.isInitRecordingPersistentMode = newValue }
    }

    /// Starts mic input to the SDK even without any ``Room`` or a connection.
    /// Audio buffers will flow into ``LocalAudioTrack/add(audioRenderer:)`` and ``capturePostProcessingDelegate``.
    public func startLocalRecording() {
        RTC.audioDeviceModule.initAndStartRecording()
    }

    /// Set a chain of ``AudioEngineObserver``s.
    /// Defaults to having a single ``DefaultAudioSessionObserver`` initially.
    ///
    /// The first object will be invoked and is responsible for calling the next object.
    /// See ``NextInvokable`` protocol for details.
    ///
    /// Objects set here will be retained.
    public func set(engineObservers: [any AudioEngineObserver]) {
        state.mutate { $0.engineObservers = engineObservers }
    }

    // MARK: - For testing

    var isPlayoutInitialized: Bool {
        RTC.audioDeviceModule.isPlayoutInitialized
    }

    var isPlaying: Bool {
        RTC.audioDeviceModule.isPlaying
    }

    var isRecordingInitialized: Bool {
        RTC.audioDeviceModule.isRecordingInitialized
    }

    var isRecording: Bool {
        RTC.audioDeviceModule.isRecording
    }

    func initPlayout() {
        RTC.audioDeviceModule.initPlayout()
    }

    func startPlayout() {
        RTC.audioDeviceModule.startPlayout()
    }

    func stopPlayout() {
        RTC.audioDeviceModule.stopPlayout()
    }

    func initRecording() {
        RTC.audioDeviceModule.initRecording()
    }

    func startRecording() {
        RTC.audioDeviceModule.startRecording()
    }

    func stopRecording() {
        RTC.audioDeviceModule.stopRecording()
    }

    // MARK: - Internal

    enum `Type` {
        case local
        case remote
    }

    let state: StateSync<State>

    let admDelegateAdapter = AudioDeviceModuleDelegateAdapter()

    public weak var screenShareAppAudioPlayerNode: AVAudioPlayerNode?

    init() {
        state = StateSync(State(engineObservers: [DefaultAudioSessionObserver()]))
        admDelegateAdapter.audioManager = self
        RTC.audioDeviceModule.observer = admDelegateAdapter
    }

    // MARK: - Private

    func trackDidStart(_ type: Type) async throws {
        state.mutate { state in
            let oldState = state
            if type == .local { state.localTracksCount += 1 }
            if type == .remote { state.remoteTracksCount += 1 }
            return (state, oldState)
        }
    }

    func trackDidStop(_ type: Type) async throws {
        state.mutate { state in
            let oldState = state
            if type == .local { state.localTracksCount = max(state.localTracksCount - 1, 0) }
            if type == .remote { state.remoteTracksCount = max(state.remoteTracksCount - 1, 0) }
            return (state, oldState)
        }
    }

    #if os(iOS) || os(visionOS) || os(tvOS)
    /// The default implementation when audio session configuration is requested by the SDK.
    /// Configure the `RTCAudioSession` of `WebRTC` framework.
    ///
    /// > Note: It is recommended to use `RTCAudioSessionConfiguration.webRTC()` to obtain an instance of `RTCAudioSessionConfiguration` instead of instantiating directly.
    ///
    /// - Parameters:
    ///   - configuration: A configured RTCAudioSessionConfiguration
    ///   - setActive: passing true/false will call `AVAudioSession.setActive` internally
    public func defaultConfigureAudioSessionFunc(newState: State, oldState: State) {
        // Lazily computed config
        let computeConfiguration: (() -> AudioSessionConfiguration) = {
            switch newState.trackState {
            case .none:
                // Use .soloAmbient configuration
                return .soloAmbient
            case .remoteOnly where newState.isSpeakerOutputPreferred:
                // Use .playback configuration with spoken audio
                return .playback
            default:
                // Use .playAndRecord configuration
                return newState.isSpeakerOutputPreferred ? .playAndRecordSpeaker : .playAndRecordReceiver
            }
        }

        let configuration = newState.sessionConfiguration ?? computeConfiguration()

        var setActive: Bool?
        if newState.trackState != .none, oldState.trackState == .none {
            // activate audio session when there is any local/remote audio track
            setActive = true
        } else if newState.trackState == .none, oldState.trackState != .none {
            // deactivate audio session when there are no more local/remote audio tracks
            setActive = false
        }

        let session = LKRTCAudioSession.sharedInstance()
        // Check if needs setConfiguration
        guard configuration != session.toAudioSessionConfiguration() else {
            log("Skipping configure audio session, no changes")
            return
        }

        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }

        do {
            log("Configuring audio session: \(String(describing: configuration))")
            if let setActive {
                try session.setConfiguration(configuration.toRTCType(), active: setActive)
            } else {
                try session.setConfiguration(configuration.toRTCType())
            }
        } catch {
            log("Failed to configure audio session with error: \(error)", .error)
        }
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

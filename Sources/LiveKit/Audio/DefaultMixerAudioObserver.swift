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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

public final class DefaultMixerAudioObserver: AudioEngineObserver, Loggable {
    public var next: (any AudioEngineObserver)? {
        get { _state.next }
        set { _state.mutate { $0.next = newValue } }
    }

    /// Adjust the volume of captured app audio. Range is 0.0 ~ 1.0.
    public var appVolume: Float {
        get { _state.read { $0.appMixerNode.outputVolume } }
        set { _state.mutate { $0.appMixerNode.outputVolume = newValue } }
    }

    /// Adjust the volume of microphone audio. Range is 0.0 ~ 1.0.
    public var micVolume: Float {
        get { _state.read { $0.micMixerNode.outputVolume } }
        set { _state.mutate { $0.micMixerNode.outputVolume = newValue } }
    }

    // MARK: - Internal

    var appAudioNode: AVAudioPlayerNode {
        _state.read { $0.appNode }
    }

    var micAudioNode: AVAudioPlayerNode {
        _state.read { $0.micNode }
    }

    struct State {
        var next: (any AudioEngineObserver)?

        // AppAudio
        public let appNode = AVAudioPlayerNode()
        public let appMixerNode = AVAudioMixerNode()

        // Not connected for device rendering mode.
        public let micNode = AVAudioPlayerNode()
        public let micMixerNode = AVAudioMixerNode()
    }

    let _state = StateSync(State())

    public init() {}

    public func setNext(_ handler: any AudioEngineObserver) {
        next = handler
    }

    public func engineDidCreate(_ engine: AVAudioEngine) {
        let (appNode, appMixerNode, micNode, micMixerNode) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode)
        }

        engine.attach(appNode)
        engine.attach(appMixerNode)
        engine.attach(micNode)
        engine.attach(micMixerNode)

        // Invoke next
        next?.engineDidCreate(engine)
    }

    public func engineWillRelease(_ engine: AVAudioEngine) {
        // Invoke next
        next?.engineWillRelease(engine)

        let (appNode, appMixerNode, micNode, micMixerNode) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode)
        }

        engine.detach(appNode)
        engine.detach(appMixerNode)
        engine.detach(micNode)
        engine.detach(micMixerNode)
    }

    public func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any]) {
        // Get the main mixer
        guard let mainMixerNode = context[kRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode else {
            // If failed to get main mixer, call next and return.
            next?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context)
            return
        }

        // Read nodes from state lock.
        let (appNode, appMixerNode, micNode, micMixerNode) = _state.read {
            ($0.appNode, $0.appMixerNode, $0.micNode, $0.micMixerNode)
        }

        // TODO: Investigate if possible to get this format prior to starting screen capture.
        // <AVAudioFormat 0x600003055180:  2 ch,  48000 Hz, Float32, deinterleaved>
        let appAudioNodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: format.sampleRate, // Assume same sample rate
                                               channels: 2,
                                               interleaved: false)

        log("Connecting app -> appMixer -> mainMixer")
        // appAudio -> appAudioMixer -> mainMixer
        engine.connect(appNode, to: appMixerNode, format: appAudioNodeFormat)
        engine.connect(appMixerNode, to: mainMixerNode, format: format)

        // src is not null if device rendering mode.
        if let src {
            log("Connecting src (device) to micMixer -> mainMixer")
            // mic (device) -> micMixer -> mainMixer
            engine.connect(src, to: micMixerNode, format: format)
        }

        // TODO: Investigate if possible to get this format prior to starting screen capture.
        let micNodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: format.sampleRate, // Assume same sample rate
                                          channels: 1, // Mono
                                          interleaved: false)

        log("Connecting micAudio (player) to micMixer -> mainMixer")
        // mic (player) -> micMixer -> mainMixer
        engine.connect(micNode, to: micMixerNode, format: micNodeFormat)
        // Always connect micMixer to mainMixer
        engine.connect(micMixerNode, to: mainMixerNode, format: format)

        // Invoke next
        next?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context)
    }
}

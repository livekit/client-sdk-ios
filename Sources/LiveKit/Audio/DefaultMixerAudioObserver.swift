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

enum AudioPort: Sendable {
    case defaultInput
    case custom(AVAudioPlayerNode)
}

public final class DefaultMixerAudioObserver: AudioEngineObserver, Loggable {
    public var next: (any AudioEngineObserver)? {
        get { _state.next }
        set { _state.mutate { $0.next = newValue } }
    }

    /// Adjust the volume of captured app audio. Range is 0.0 ~ 1.0.
    public var appAudioVolume: Float {
        get { _state.read { $0.appAudioMixerNode.outputVolume } }
        set { _state.mutate { $0.appAudioMixerNode.outputVolume = newValue } }
    }

    // MARK: - Internal

    // <AVAudioFormat 0x600003055180:  2 ch,  48000 Hz, Float32, deinterleaved>
    let appAudioNodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: 48000,
                                           channels: 2,
                                           interleaved: false)

    var appAudioNode: AVAudioPlayerNode {
        _state.read { $0.appAudioNode }
    }

    struct State {
        var next: (any AudioEngineObserver)?
        public let appAudioNode = AVAudioPlayerNode()
        public let appAudioMixerNode = AVAudioMixerNode()
        public let micMixerNode = AVAudioMixerNode()
    }

    let _state = StateSync(State())

    public init() {}

    public func setNext(_ handler: any AudioEngineObserver) {
        next = handler
    }

    public func engineDidCreate(_ engine: AVAudioEngine) {
        let (playerNode, playerMixerNode, micMixerNode) = _state.read {
            ($0.appAudioNode, $0.appAudioMixerNode, $0.micMixerNode)
        }

        engine.attach(playerNode)
        engine.attach(playerMixerNode)
        engine.attach(micMixerNode)

        // Invoke next
        next?.engineDidCreate(engine)
    }

    public func engineWillRelease(_ engine: AVAudioEngine) {
        // Invoke next
        next?.engineWillRelease(engine)

        let (playerNode, playerMixerNode, micMixerNode) = _state.read {
            ($0.appAudioNode, $0.appAudioMixerNode, $0.micMixerNode)
        }

        engine.detach(playerNode)
        engine.detach(playerMixerNode)
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
        let (appAudioNode, appAudioMixerNode, micMixerNode) = _state.read {
            ($0.appAudioNode, $0.appAudioMixerNode, $0.micMixerNode)
        }

        // appAudio -> appAudioMixer -> mainMixer
        engine.connect(appAudioNode, to: appAudioMixerNode, format: appAudioNodeFormat)
        engine.connect(appAudioMixerNode, to: mainMixerNode, format: format)

        if let src {
            log("Connecting src to micMixer -> mainMixer")
            // mic -> micMixer -> mainMixer
            engine.connect(src, to: micMixerNode, format: format)
            engine.connect(micMixerNode, to: mainMixerNode, format: format)
        }

        // Invoke next
        next?.engineWillConnectInput(engine, src: src, dst: dst, format: format, context: context)
    }
}

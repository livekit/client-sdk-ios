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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

public final class AudioEngineAudioInputObserver: AudioEngineObserver, Loggable {
    public let playerNode = AVAudioPlayerNode()
    public let playerMixerNode = AVAudioMixerNode()
    public let micMixerNode = AVAudioMixerNode()

    // <AVAudioFormat 0x600003055180:  2 ch,  48000 Hz, Float32, deinterleaved>
    let playerNodeFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48000,
                                         channels: 2,
                                         interleaved: false)

    var next: (any AudioEngineObserver)?

    public init() {}

    public func setNext(_ handler: any AudioEngineObserver) {
        next = handler
    }

    public func engineDidCreate(_ engine: AVAudioEngine) {
        engine.attach(playerNode)
        engine.attach(playerMixerNode)
        engine.attach(micMixerNode)

        micMixerNode.outputVolume = 0.0
    }

    public func engineWillRelease(_ engine: AVAudioEngine) {
        engine.detach(playerNode)
        engine.detach(playerMixerNode)
        engine.detach(micMixerNode)
    }

    public func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode, format: AVAudioFormat) -> Bool {
        // inputPlayer -> playerMixer -> mainMixer
        engine.connect(playerNode, to: playerMixerNode, format: playerNodeFormat)
        engine.connect(playerMixerNode, to: dst, format: format)

        // mic -> micMixer -> mainMixer
        engine.connect(src, to: micMixerNode, format: format)
        engine.connect(micMixerNode, to: dst, format: format)

        return true
    }
}

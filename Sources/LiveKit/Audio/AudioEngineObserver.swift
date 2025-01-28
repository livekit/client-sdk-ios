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

import AVFAudio

/// Do not retain the engine object.
public protocol AudioEngineObserver: NextInvokable, Sendable {
    func setNext(_ handler: any AudioEngineObserver)

    func engineDidCreate(_ engine: AVAudioEngine)
    func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
    func engineWillStart(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
    func engineDidStop(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
    func engineDidDisable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool)
    func engineWillRelease(_ engine: AVAudioEngine)

    /// Provide custom implementation for internal AVAudioEngine's output configuration.
    /// Buffers flow from `src` to `dst`. Preferred format to connect node is provided as `format`.
    /// Return true if custom implementation is provided, otherwise default implementation will be used.
    func engineWillConnectOutput(_ engine: AVAudioEngine, src: AVAudioNode, dst: AVAudioNode?, format: AVAudioFormat) -> Bool
    /// Provide custom implementation for internal AVAudioEngine's input configuration.
    /// Buffers flow from `src` to `dst`. Preferred format to connect node is provided as `format`.
    /// Return true if custom implementation is provided, otherwise default implementation will be used.
    func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode, format: AVAudioFormat) -> Bool
}

/// Default implementation to make it optional.
public extension AudioEngineObserver {
    func engineDidCreate(_: AVAudioEngine) {}
    func engineWillEnable(_: AVAudioEngine, isPlayoutEnabled _: Bool, isRecordingEnabled _: Bool) {}
    func engineWillStart(_: AVAudioEngine, isPlayoutEnabled _: Bool, isRecordingEnabled _: Bool) {}
    func engineDidStop(_: AVAudioEngine, isPlayoutEnabled _: Bool, isRecordingEnabled _: Bool) {}
    func engineDidDisable(_: AVAudioEngine, isPlayoutEnabled _: Bool, isRecordingEnabled _: Bool) {}
    func engineWillRelease(_: AVAudioEngine) {}

    func engineWillConnectOutput(_: AVAudioEngine, src _: AVAudioNode, dst _: AVAudioNode?, format _: AVAudioFormat) -> Bool { false }
    func engineWillConnectInput(_: AVAudioEngine, src _: AVAudioNode?, dst _: AVAudioNode, format _: AVAudioFormat) -> Bool { false }
}

extension [any AudioEngineObserver] {
    func buildChain() -> Element? {
        guard let first else { return nil }

        for i in 0 ..< count - 1 {
            self[i].setNext(self[i + 1])
        }

        return first
    }
}

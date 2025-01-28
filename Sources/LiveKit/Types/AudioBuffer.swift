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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

import Foundation

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

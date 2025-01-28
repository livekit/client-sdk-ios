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

public final class DefaultAudioSessionObserver: AudioEngineObserver, Loggable {
    var next: (any AudioEngineObserver)?
    var isSessionActive = false

    public func setNext(_ handler: any AudioEngineObserver) {
        next = handler
    }

    public func engineWillEnable(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        #if os(iOS) || os(visionOS) || os(tvOS)
        log("Configuring audio session...")
        let session = LKRTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }

        let config: AudioSessionConfiguration = isRecordingEnabled ? .playAndRecordSpeaker : .playback
        do {
            if isSessionActive {
                log("AudioSession switching category to: \(config.category)")
                try session.setConfiguration(config.toRTCType())
            } else {
                log("AudioSession activating category to: \(config.category)")
                try session.setConfiguration(config.toRTCType(), active: true)
                isSessionActive = true
            }
        } catch {
            log("AudioSession failed to configure with error: \(error)", .error)
        }

        log("AudioSession activationCount: \(session.activationCount), webRTCSessionCount: \(session.webRTCSessionCount)")
        #endif

        // Call next last
        next?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    public func engineDidStop(_ engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        // Call next first
        next?.engineDidStop(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)

        #if os(iOS) || os(visionOS) || os(tvOS)
        log("Configuring audio session...")
        let session = LKRTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }

        do {
            if isPlayoutEnabled, !isRecordingEnabled {
                let config: AudioSessionConfiguration = .playback
                log("AudioSession switching category to: \(config.category)")
                try session.setConfiguration(config.toRTCType())
            }
            if !isPlayoutEnabled, !isRecordingEnabled {
                log("AudioSession deactivating")
                try session.setActive(false)
                isSessionActive = false
            }
        } catch {
            log("AudioSession failed to configure with error: \(error)", .error)
        }

        log("AudioSession activationCount: \(session.activationCount), webRTCSessionCount: \(session.webRTCSessionCount)")
        #endif
    }
}

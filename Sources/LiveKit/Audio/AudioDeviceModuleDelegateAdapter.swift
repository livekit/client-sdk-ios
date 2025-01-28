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

import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Invoked on WebRTC's worker thread, do not block.
class AudioDeviceModuleDelegateAdapter: NSObject, LKRTCAudioDeviceModuleDelegate {
    weak var audioManager: AudioManager?

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent speechActivityEvent: RTCSpeechActivityEvent) {
        guard let audioManager else { return }
        audioManager.onMutedSpeechActivityEvent?(audioManager, speechActivityEvent.toLKType())
    }

    func audioDeviceModuleDidUpdateDevices(_: LKRTCAudioDeviceModule) {
        guard let audioManager else { return }
        audioManager.onDeviceUpdate?(audioManager)
    }

    // Engine events

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) {
        guard let audioManager else { return }
        let entryPoint = audioManager.state.engineObservers.buildChain()
        entryPoint?.engineDidCreate(engine)
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        guard let audioManager else { return }
        let entryPoint = audioManager.state.engineObservers.buildChain()
        entryPoint?.engineWillEnable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        guard let audioManager else { return }
        let entryPoint = audioManager.state.engineObservers.buildChain()
        entryPoint?.engineWillStart(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        guard let audioManager else { return }
        let entryPoint = audioManager.state.engineObservers.buildChain()
        entryPoint?.engineDidStop(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine, isPlayoutEnabled: Bool, isRecordingEnabled: Bool) {
        guard let audioManager else { return }
        let entryPoint = audioManager.state.engineObservers.buildChain()
        entryPoint?.engineDidDisable(engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled)
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) {
        guard let audioManager else { return }
        let entryPoint = audioManager.state.engineObservers.buildChain()
        entryPoint?.engineWillRelease(engine)
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource src: AVAudioNode?, toDestination dst: AVAudioNode, format: AVAudioFormat) -> Bool {
        guard let audioManager else { return false }
        let entryPoint = audioManager.state.engineObservers.buildChain()
        return entryPoint?.engineWillConnectInput(engine, src: src, dst: dst, format: format) ?? false
    }

    func audioDeviceModule(_: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource src: AVAudioNode, toDestination dst: AVAudioNode?, format: AVAudioFormat) -> Bool {
        guard let audioManager else { return false }
        let entryPoint = audioManager.state.engineObservers.buildChain()
        return entryPoint?.engineWillConnectOutput(engine, src: src, dst: dst, format: format) ?? false
    }
}

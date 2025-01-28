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

class SineWaveSourceNode: AVAudioSourceNode {
    private let sampleRate: Double
    private let frequency: Double

    init(frequency: Double = 400.0, sampleRate: Double = 48000.0) {
        self.frequency = frequency
        self.sampleRate = sampleRate

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let twoPi = 2 * Float.pi
        let amplitude: Float = 0.5
        var currentPhase: Float = 0.0
        let phaseIncrement: Float = (twoPi / Float(sampleRate)) * Float(frequency)

        let renderBlock: AVAudioSourceNodeRenderBlock = { _, _, frameCount, audioBufferList in
            print("AVAudioSourceNodeRenderBlock frameCount: \(frameCount)")
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)

            // Generate sine wave samples
            for frame in 0 ..< Int(frameCount) {
                // Get the signal value for this frame at time.
                let value = sin(currentPhase) * amplitude
                // Advance the phase for the next frame.
                currentPhase += phaseIncrement
                if currentPhase >= twoPi {
                    currentPhase -= twoPi
                }
                if currentPhase < 0.0 {
                    currentPhase += twoPi
                }
                // Set the same value on all channels (due to the inputFormat, there's only one channel though).
                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    buf[frame] = value
                }
            }

            return noErr
        }

        super.init(format: format, renderBlock: renderBlock)
    }
}

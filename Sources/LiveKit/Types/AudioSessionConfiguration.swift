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

#if os(iOS) || os(visionOS) || os(tvOS)

import AVFoundation
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Defaults
public extension AudioSessionConfiguration {
    // Default for iOS apps.
    static let soloAmbient = AudioSessionConfiguration(category: .soloAmbient,
                                                       categoryOptions: [],
                                                       mode: .default)

    static let playback = AudioSessionConfiguration(category: .playback,
                                                    categoryOptions: [.mixWithOthers],
                                                    mode: .spokenAudio)

    static let playAndRecordSpeaker = AudioSessionConfiguration(category: .playAndRecord,
                                                                categoryOptions: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay],
                                                                mode: .videoChat)

    static let playAndRecordReceiver = AudioSessionConfiguration(category: .playAndRecord,
                                                                 categoryOptions: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay],
                                                                 mode: .voiceChat)
}

@objc
public final class AudioSessionConfiguration: NSObject, Sendable {
    @objc
    public let category: AVAudioSession.Category

    @objc
    public let categoryOptions: AVAudioSession.CategoryOptions

    @objc
    public let mode: AVAudioSession.Mode

    @objc
    public init(category: AVAudioSession.Category,
                categoryOptions: AVAudioSession.CategoryOptions,
                mode: AVAudioSession.Mode)
    {
        self.category = category
        self.categoryOptions = categoryOptions
        self.mode = mode
    }

    @objc
    override public convenience init() {
        let webRTCConfiguration = LKRTCAudioSessionConfiguration.webRTC()
        self.init(category: AVAudioSession.Category(rawValue: webRTCConfiguration.category),
                  categoryOptions: webRTCConfiguration.categoryOptions,
                  mode: AVAudioSession.Mode(rawValue: webRTCConfiguration.mode))
    }

    // MARK: - Equal

    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? Self else { return false }
        return category == other.category &&
            categoryOptions == other.categoryOptions &&
            mode == other.mode
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(category)
        hasher.combine(categoryOptions.rawValue)
        hasher.combine(mode)
        return hasher.finalize()
    }
}

public extension AudioSessionConfiguration {
    func copyWith(category: ValueOrAbsent<AVAudioSession.Category> = .absent,
                  categoryOptions: ValueOrAbsent<AVAudioSession.CategoryOptions> = .absent,
                  mode: ValueOrAbsent<AVAudioSession.Mode> = .absent) -> AudioSessionConfiguration
    {
        AudioSessionConfiguration(category: category.value(ifAbsent: self.category),
                                  categoryOptions: categoryOptions.value(ifAbsent: self.categoryOptions),
                                  mode: mode.value(ifAbsent: self.mode))
    }
}

extension AudioSessionConfiguration {
    func toRTCType() -> LKRTCAudioSessionConfiguration {
        let configuration = LKRTCAudioSessionConfiguration.webRTC()
        configuration.category = category.rawValue
        configuration.categoryOptions = categoryOptions
        configuration.mode = mode.rawValue
        return configuration
    }
}

extension LKRTCAudioSession {
    func toAudioSessionConfiguration() -> AudioSessionConfiguration {
        AudioSessionConfiguration(category: AVAudioSession.Category(rawValue: category),
                                  categoryOptions: categoryOptions,
                                  mode: AVAudioSession.Mode(rawValue: mode))
    }
}

public extension AudioSessionConfiguration {
    override var description: String {
        "AudioSessionConfiguration(category: \(category), categoryOptions: \(categoryOptions), mode: \(mode))"
    }
}

#endif

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
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

extension TrackSettings: CustomStringConvertible {
    public var description: String {
        "TrackSettings(enabled: \(isEnabled), dimensions: \(dimensions), videoQuality: \(videoQuality))"
    }
}

extension Livekit_VideoLayer: CustomStringConvertible {
    public var description: String {
        "VideoLayer(quality: \(quality), dimensions: \(width)x\(height), bitrate: \(bitrate))"
    }
}

public extension TrackPublication {
    override var description: String {
        "\(String(describing: type(of: self)))(sid: \(sid), kind: \(kind), source: \(source))"
    }
}

extension Livekit_AddTrackRequest: CustomStringConvertible {
    public var description: String {
        "AddTrackRequest(cid: \(cid), name: \(name), type: \(type), source: \(source), width: \(width), height: \(height), muted: \(muted))"
    }
}

extension Livekit_TrackInfo: CustomStringConvertible {
    public var description: String {
        "TrackInfo(sid: \(sid), " +
            "name: \(name), " +
            "type: \(type), " +
            "source: \(source), " +
            "width: \(width), " +
            "height: \(height), " +
            "isMuted: \(muted), " +
            "simulcast: \(simulcast), " +
            "codecs: \(codecs.map { String(describing: $0) }), " +
            "layers: \(layers.map { String(describing: $0) }))"
    }
}

extension Livekit_SubscribedQuality: CustomStringConvertible {
    public var description: String {
        "SubscribedQuality(quality: \(quality), enabled: \(enabled))"
    }
}

extension Livekit_SubscribedCodec: CustomStringConvertible {
    public var description: String {
        "SubscribedCodec(codec: \(codec), qualities: \(qualities.map { String(describing: $0) }.joined(separator: ", "))"
    }
}

extension Livekit_ServerInfo: CustomStringConvertible {
    public var description: String {
        "ServerInfo(edition: \(edition), " +
            "version: \(version), " +
            "protocol: \(`protocol`), " +
            "region: \(region), " +
            "nodeID: \(nodeID), " +
            "debugInfo: \(debugInfo))"
    }
}

// MARK: - NSObject

public extension Room {
    override var description: String {
        "Room(sid: \(String(describing: sid)), name: \(name ?? "nil"), serverVersion: \(serverVersion ?? "nil"), serverRegion: \(serverRegion ?? "nil"))"
    }
}

public extension Participant {
    override var description: String {
        "\(String(describing: type(of: self)))(sid: \(String(describing: sid)))"
    }
}

public extension Track {
    override var description: String {
        "\(String(describing: type(of: self)))(sid: \(String(describing: sid)), name: \(name), source: \(source))"
    }
}

extension RTCPeerConnectionState {
    var description: String {
        switch self {
        case .new: return ".new"
        case .connecting: return ".connecting"
        case .connected: return ".connected"
        case .disconnected: return ".disconnected"
        case .failed: return ".failed"
        case .closed: return ".closed"
        @unknown default: return "unknown"
        }
    }
}

extension ConnectionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .disconnected: return ".disconnected"
        case .connecting: return ".connecting"
        case .reconnecting: return ".reconnecting"
        case .connected: return ".connected"
        }
    }
}

extension ReconnectMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .quick: return ".quick"
        case .full: return ".full"
        }
    }
}

extension Livekit_SignalResponse: CustomStringConvertible {
    var description: String {
        "Livekit_SignalResponse(\(String(describing: message)))"
    }
}

extension VideoView.RenderMode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .auto: return ".auto"
        case .metal: return ".metal"
        case .sampleBuffer: return ".sampleBuffer"
        }
    }
}

extension LKRTCRtpEncodingParameters {
    func toDebugString() -> String {
        "RTCRtpEncodingParameters(" +
            "rid: \(String(describing: rid)), " +
            "isActive: \(String(describing: isActive)), " +
            "minBitrateBps: \(String(describing: minBitrateBps))" +
            "maxBitrateBps: \(String(describing: maxBitrateBps))" +
            "maxFramerate: \(String(describing: maxFramerate))" +
            "scaleResolutionDownBy: \(String(describing: scaleResolutionDownBy))" +
            ")"
    }
}

extension AVCaptureDevice.Format {
    func toDebugString() -> String {
        var values: [String] = []
        values.append("fps: \(fpsRange())")
        #if os(iOS)
        values.append("isMulticamSupported: \(isMultiCamSupported)")
        #endif
        return "Format(\(values.joined(separator: ", ")))"
    }
}

extension LKRTCAudioProcessingConfig {
    func toDebugString() -> String {
        "RTCAudioProcessingConfig(" +
            "isEchoCancellationEnabled: \(isEchoCancellationEnabled), " +
            "isNoiseSuppressionEnabled: \(isNoiseSuppressionEnabled), " +
            "isAutoGainControl1Enabled: \(isAutoGainControl1Enabled), " +
            "isHighpassFilterEnabled: \(isHighpassFilterEnabled)" +
            ")"
    }
}

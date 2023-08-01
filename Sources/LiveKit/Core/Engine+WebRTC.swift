/*
 * Copyright 2023 LiveKit
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
import WebRTC
import Promises

private extension Array where Element: RTCVideoCodecInfo {

    func rewriteCodecsIfNeeded() -> [RTCVideoCodecInfo] {
        // rewrite H264's profileLevelId to 42e032
        let codecs = map { $0.name == kRTCVideoCodecH264Name ? Engine.h264BaselineLevel5CodecInfo : $0 }
        // logger.log("supportedCodecs: \(codecs.map({ "\($0.name) - \($0.parameters)" }).joined(separator: ", "))", type: Engine.self)
        return codecs
    }
}

private class VideoEncoderFactory: RTCDefaultVideoEncoderFactory {

    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

private class VideoDecoderFactory: RTCDefaultVideoDecoderFactory {

    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

private class VideoEncoderFactorySimulcast: RTCVideoEncoderFactorySimulcast {

    override func supportedCodecs() -> [RTCVideoCodecInfo] {
        super.supportedCodecs().rewriteCodecsIfNeeded()
    }
}

internal extension Engine {

    static var bypassVoiceProcessing: Bool = false

    static let h264BaselineLevel5CodecInfo: RTCVideoCodecInfo = {

        // this should never happen
        guard let profileLevelId = RTCH264ProfileLevelId(profile: .constrainedBaseline, level: .level5) else {
            logger.log("failed to generate profileLevelId", .error, type: Engine.self)
            fatalError("failed to generate profileLevelId")
        }

        // create a new H264 codec with new profileLevelId
        return RTCVideoCodecInfo(name: kRTCH264CodecName,
                                 parameters: ["profile-level-id": profileLevelId.hexString,
                                              "level-asymmetry-allowed": "1",
                                              "packetization-mode": "1"])
    }()

    static let vp8CodecInfo: RTCVideoCodecInfo = RTCVideoCodecInfo(name: kRTCVp8CodecName)
    static let av1CodecInfo: RTCVideoCodecInfo = RTCVideoCodecInfo(name: kRTCAv1CodecName)

    // global properties are already lazy

    static private let encoderFactory: RTCVideoEncoderFactory = {
        let encoderFactory = VideoEncoderFactory()
        #if LK_USE_LIVEKIT_WEBRTC_BUILD
        return VideoEncoderFactorySimulcast(primary: encoderFactory,
                                            fallback: encoderFactory)

        #else
        return encoderFactory
        #endif
    }()

    static private let decoderFactory = VideoDecoderFactory()

    static let canEncodeH264 = encoderFactory.supportedCodecs().contains { $0.name == kRTCH264CodecName }
    static let canDecodeH264 = decoderFactory.supportedCodecs().contains { $0.name == kRTCH264CodecName }
    static let canEncodeAndDecodeH264 = canEncodeH264 && canDecodeH264

    static let canEncodeVP8 = encoderFactory.supportedCodecs().contains { $0.name == kRTCVp8CodecName }
    static let canDecodeVP8 = decoderFactory.supportedCodecs().contains { $0.name == kRTCVp8CodecName }
    static let canEncodeAndDecodeVP8 = canEncodeVP8 && canDecodeVP8

    static let canEncodeVP9 = encoderFactory.supportedCodecs().contains { $0.name == kRTCVp9CodecName }
    static let canDecodeVP9 = decoderFactory.supportedCodecs().contains { $0.name == kRTCVp9CodecName }
    static let canEncodeAndDecodeVP9 = canEncodeVP9 && canDecodeVP9

    static let canEncodeAV1 = encoderFactory.supportedCodecs().contains { $0.name == kRTCAv1CodecName }
    static let canDecodeAV1 = decoderFactory.supportedCodecs().contains { $0.name == kRTCAv1CodecName }
    static let canEncodeAndDecodeAV1 = canEncodeAV1 && canDecodeAV1

    static let videoSenderCapabilities = peerConnectionFactory.rtpSenderCapabilities(for: .video)
    static let audioSenderCapabilities = peerConnectionFactory.rtpSenderCapabilities(for: .audio)

    static let peerConnectionFactory: RTCPeerConnectionFactory = {

        logger.log("Initializing SSL...", type: Engine.self)

        RTCInitializeSSL()

        logger.log("Initializing Field trials...", type: Engine.self)

        let fieldTrials = [kRTCFieldTrialUseNWPathMonitor: kRTCFieldTrialEnabledValue]
        RTCInitFieldTrialDictionary(fieldTrials)

        logger.log("Initializing PeerConnectionFactory...", type: Engine.self)

        logger.log("canEncode H264: \(canEncodeH264 ? "YES" : "NO"), VP8: \(canEncodeVP8 ? "YES" : "NO"), VP9: \(canEncodeVP9 ? "YES" : "NO"), AV1: \(canEncodeAV1 ? "YES" : "NO")", type: Engine.self)
        logger.log("canDecode H264: \(canDecodeH264 ? "YES" : "NO"), VP8: \(canDecodeVP8 ? "YES" : "NO"), VP9: \(canDecodeVP9 ? "YES" : "NO"), AV1: \(canDecodeAV1 ? "YES" : "NO")", type: Engine.self)
        logger.log("supportedCodecs: \(encoderFactory.supportedCodecs().map({ String(describing: $0) }).joined(separator: ", "))", type: Engine.self)

        #if LK_USE_LIVEKIT_WEBRTC_BUILD
        return RTCPeerConnectionFactory(bypassVoiceProcessing: bypassVoiceProcessing,
                                        encoderFactory: encoderFactory,
                                        decoderFactory: decoderFactory)
        #else
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory,
                                        decoderFactory: decoderFactory)
        #endif
    }()

    // forbid direct access

    static var audioDeviceModule: RTCAudioDeviceModule {
        peerConnectionFactory.audioDeviceModule
    }

    static func createPeerConnection(_ configuration: RTCConfiguration,
                                     constraints: RTCMediaConstraints) -> RTCPeerConnection? {
        DispatchQueue.webRTC.sync { peerConnectionFactory.peerConnection(with: configuration,
                                                                         constraints: constraints,
                                                                         delegate: nil) }
    }

    static func createVideoSource(forScreenShare: Bool) -> RTCVideoSource {
        #if LK_USE_LIVEKIT_WEBRTC_BUILD
        DispatchQueue.webRTC.sync { peerConnectionFactory.videoSource(forScreenCast: forScreenShare) }
        #else
        DispatchQueue.webRTC.sync { peerConnectionFactory.videoSource() }
        #endif
    }

    static func createVideoTrack(source: RTCVideoSource) -> RTCVideoTrack {
        DispatchQueue.webRTC.sync { peerConnectionFactory.videoTrack(with: source,
                                                                     trackId: UUID().uuidString) }
    }

    static func createAudioSource(_ constraints: RTCMediaConstraints?) -> RTCAudioSource {
        DispatchQueue.webRTC.sync { peerConnectionFactory.audioSource(with: constraints) }
    }

    static func createAudioTrack(source: RTCAudioSource) -> RTCAudioTrack {
        DispatchQueue.webRTC.sync { peerConnectionFactory.audioTrack(with: source,
                                                                     trackId: UUID().uuidString) }
    }

    static func createDataChannelConfiguration(ordered: Bool = true,
                                               maxRetransmits: Int32 = -1) -> RTCDataChannelConfiguration {
        let result = DispatchQueue.webRTC.sync { RTCDataChannelConfiguration() }
        result.isOrdered = ordered
        result.maxRetransmits = maxRetransmits
        return result
    }

    static func createDataBuffer(data: Data) -> RTCDataBuffer {
        DispatchQueue.webRTC.sync { RTCDataBuffer(data: data, isBinary: true) }
    }

    static func createIceCandidate(fromJsonString: String) throws -> RTCIceCandidate {
        try DispatchQueue.webRTC.sync { try RTCIceCandidate(fromJsonString: fromJsonString) }
    }

    static func createSessionDescription(type: RTCSdpType, sdp: String) -> RTCSessionDescription {
        DispatchQueue.webRTC.sync { RTCSessionDescription(type: type, sdp: sdp) }
    }

    static func createVideoCapturer() -> RTCVideoCapturer {
        DispatchQueue.webRTC.sync { RTCVideoCapturer() }
    }

    static func createRtpEncodingParameters(rid: String? = nil,
                                            encoding: MediaEncoding? = nil,
                                            scaleDownBy: Double? = nil,
                                            scalabilityMode: ScalabilityMode? = nil,
                                            active: Bool = true) -> RTCRtpEncodingParameters {

        let result = DispatchQueue.webRTC.sync { RTCRtpEncodingParameters() }

        result.isActive = active
        result.rid = rid

        if let scaleDownBy = scaleDownBy {
            result.scaleResolutionDownBy = NSNumber(value: scaleDownBy)
        }

        if let encoding = encoding {
            result.maxBitrateBps = NSNumber(value: encoding.maxBitrate)

            // VideoEncoding specific
            if let videoEncoding = encoding as? VideoEncoding {
                result.maxFramerate = NSNumber(value: videoEncoding.maxFps)
            }
        }

        if let scalabilityMode = scalabilityMode {
            result.scalabilityMode = scalabilityMode.rawStringValue
        }

        return result
    }
}

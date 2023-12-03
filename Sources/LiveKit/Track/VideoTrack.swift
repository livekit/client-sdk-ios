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

@_implementationOnly import WebRTC

@objc
public protocol VideoTrack where Self: Track {
    @objc(addVideoRenderer:)
    func add(videoRenderer: VideoRenderer)

    @objc(removeVideoRenderer:)
    func remove(videoRenderer: VideoRenderer)
}

// Directly add/remove renderers for better performance
protocol VideoTrack_Internal where Self: Track {
    func add(rtcVideoRenderer: LKRTCVideoRenderer)

    func remove(rtcVideoRenderer: LKRTCVideoRenderer)
}

extension VideoTrack {
    func _set(subscribedCodecs codecs: [Livekit_SubscribedCodec]) -> [VideoCodec] {
        // ...
        var missingCodecs: [VideoCodec] = []

        for e in codecs {
            guard let videoCodec = VideoCodec.from(id: e.codec) else {
                log("VideoCodec for id: \(e.codec) not found", .warning)
                continue
            }

            // Check if main sender is sending the codec...
            if let rtpSender, videoCodec == _videoCodec {
                rtpSender._set(subscribedQualities: e.qualities)
                continue
            }

            // Find simulcast sender for codec...
            if let rtpSender = _simulcastRtpSenders[videoCodec] {
                rtpSender._set(subscribedQualities: e.qualities)
                continue
            }

            log("Sender for codec \(e.codec) not found", .info)
            missingCodecs.append(videoCodec)
        }

        // TODO: Publish missing codecs...
        return missingCodecs
    }
}

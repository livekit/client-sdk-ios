/*
 * Copyright 2022 LiveKit
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

@objc
public class TrackStatistics: NSObject {

    public let codec: [CodecStatistics]
    public let transportStats: TransportStatistics?
    public let videoSource: [VideoSourceStatistics]

    public let certificate: [CertificateStatistics]
    public let iceCandidatePair: [IceCandidatePairStatistics]

    public let localIceCandidate: LocalIceCandidateStatistics?
    public let remoteIceCandidate: RemoteIceCandidateStatistics?

    public let inboundRtpStream: [InboundRtpStreamStatistics]
    public let outboundRtpStream: [OutboundRtpStreamStatistics]

    public let remoteInboundRtpStream: [RemoteInboundRtpStreamStatistics]
    public let remoteOutboundRtpStream: [RemoteOutboundRtpStreamStatistics]

    init(from stats: [RTCStatistics], prevStatistics: TrackStatistics?) {

        let stats = stats.map { $0.toLKType(prevStatistics: prevStatistics) }.compactMap { $0 }

        self.codec = stats.compactMap { $0 as? CodecStatistics }
        self.videoSource = stats.compactMap { $0 as? VideoSourceStatistics }
        self.certificate = stats.compactMap { $0 as? CertificateStatistics }
        self.iceCandidatePair = stats.compactMap { $0 as? IceCandidatePairStatistics }
        self.inboundRtpStream = stats.compactMap { $0 as? InboundRtpStreamStatistics }
        self.outboundRtpStream = stats.compactMap { $0 as? OutboundRtpStreamStatistics }
        self.remoteInboundRtpStream = stats.compactMap { $0 as? RemoteInboundRtpStreamStatistics }
        self.remoteOutboundRtpStream = stats.compactMap { $0 as? RemoteOutboundRtpStreamStatistics }

        let t = stats.compactMap { $0 as? TransportStatistics }
        assert(t.count <= 1, "More than 1 TransportStatistics exists")
        self.transportStats = t.first

        let l = stats.compactMap { $0 as? LocalIceCandidateStatistics }
        assert(l.count <= 1, "More than 1 LocalIceCandidateStatistics exists")
        self.localIceCandidate = l.first

        let r = stats.compactMap { $0 as? RemoteIceCandidateStatistics }
        assert(r.count <= 1, "More than 1 RemoteIceCandidateStatistics exists")
        self.remoteIceCandidate = r.first
    }
}

extension TrackStatistics {

    public override var description: String {
        "TrackStatistics(inboundRtpStream: \(String(describing: inboundRtpStream)))"
    }
}

extension OutboundRtpStreamStatistics {

    /// Index of the rid.
    var ridIndex: Int {
        guard let rid = rid, let idx = VideoQuality.rids.firstIndex(of: rid) else {
            return -1
        }
        return idx
    }
}

extension Sequence where Element == OutboundRtpStreamStatistics {

    public func sortedByRidIndex() -> [OutboundRtpStreamStatistics] {
        sorted { $0.ridIndex > $1.ridIndex }
    }
}

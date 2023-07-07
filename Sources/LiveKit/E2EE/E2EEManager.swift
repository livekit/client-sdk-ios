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
public class E2EEManager: NSObject, ObservableObject, Loggable {
    internal var room: Room?
    internal var enabled: Bool = true
    public var e2eeOptions: E2EEOptions
    internal var frameCryptors = [String: RTCFrameCryptor]()
    internal var trackPublications = [String: TrackPublication]()
    
    public init(e2eeOptions: E2EEOptions) {
        self.e2eeOptions = e2eeOptions
    }

    public func setup(room: Room){
        if(self.room != room) {
            cleanUp()
        }
        self.room = room
        self.room?.delegates.add(delegate: self)
        
    }

    public func enableE2EE(enabled: Bool) {
        self.enabled = enabled
        for (_, frameCryptor) in frameCryptors {
            frameCryptor.enabled = enabled
        }
    }

    func addRtpSender(sender: RTCRtpSender, participantId: String, trackId: String, kind: String) -> String {
        let pid = String(format: "%@-sender-%@-%@", kind, participantId, trackId)
        self.log("addRtpSender \(pid) to E2EEManager")
        let frameCryptor = RTCFrameCryptor(rtpSender: sender, participantId: pid, algorithm: RTCCyrptorAlgorithm.aesGcm, keyProvider: self.e2eeOptions.keyProvider.rtcKeyProvider!)
        frameCryptor.delegate = self
        frameCryptors[pid] = frameCryptor
        frameCryptor.enabled = self.enabled

        if self.e2eeOptions.keyProvider.isSharedKey == true {
            self.e2eeOptions.keyProvider.setKey(key: self.e2eeOptions.keyProvider.sharedKey!, participantId: pid, index: 0)
            frameCryptor.keyIndex = 0
        }

        return pid
    }
    
    func addRtpReceiver(receiver: RTCRtpReceiver, participantId: String, trackId: String, kind: String) -> String {
        let pid = String(format: "%@-receiver-%@-%@", kind, participantId, trackId)
        self.log("addRtpReceiver \(pid)  to E2EEManager")
        let frameCryptor = RTCFrameCryptor(rtpReceiver: receiver, participantId: pid, algorithm: RTCCyrptorAlgorithm.aesGcm, keyProvider: self.e2eeOptions.keyProvider.rtcKeyProvider!)
        frameCryptor.delegate = self
        frameCryptors[pid] = frameCryptor
        frameCryptor.enabled = self.enabled

        if self.e2eeOptions.keyProvider.isSharedKey == true {
            self.e2eeOptions.keyProvider.setKey(key: self.e2eeOptions.keyProvider.sharedKey!, participantId: pid, index: 0)
            frameCryptor.keyIndex = 0
        }

        return pid
    }
    
    public func cleanUp() {
        self.room?.delegates.remove(delegate: self)
    }
}

extension E2EEManager: RTCFrameCryptorDelegate {

    public func frameCryptor(_ frameCryptor: RTCFrameCryptor, didStateChangeWithParticipantId participantId: String, with state: FrameCryptionState) {
        self.log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue)")
        let publication: TrackPublication? = trackPublications[participantId]
        if publication == nil {
            self.log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue) publication is nil")
            return
        }
        if self.room == nil {
            self.log("frameCryptor didStateChangeWithParticipantId \(participantId) with state \(state.rawValue) room is nil")
            return
        
        }
        self.room?.delegates.notify { delegate in
            delegate.room?(self.room!, publication: publication!, didUpdate: state.toLKType())
        }
    }
}

extension E2EEManager: RoomDelegate {

    public func room(_ room: Room, localParticipant: LocalParticipant, didPublish publication: LocalTrackPublication) {
        let kind = publication.kind == .video ? "video" : "audio"
        let pid = addRtpSender(sender: localParticipant.rtpSender!, participantId: localParticipant.identity, trackId: publication.sid, kind: kind)
        trackPublications[pid] = publication
    }

    public func room(_ room: Room, participant: RemoteParticipant, didSubscribe publication: RemoteTrackPublication, track: Track) {
        let kind = publication.kind == .video ? "video" : "audio"
        let pid = addRtpReceiver(receiver: participant.rtpReceiver!, participantId: participant.identity, trackId: publication.sid, kind: kind)
        trackPublications[pid] = publication
    }
}

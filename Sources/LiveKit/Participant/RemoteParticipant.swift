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
import Promises

@objc
public class RemoteParticipant: Participant {

    internal init(sid: Sid,
                  info: Livekit_ParticipantInfo?,
                  room: Room) {

        super.init(sid: sid,
                   identity: info?.identity ?? "",
                   name: info?.name ?? "",
                   room: room)

        if let info = info {
            updateFromInfo(info: info)
        }
    }

    internal func getTrackPublication(sid: Sid) -> RemoteTrackPublication? {
        _state.tracks[sid] as? RemoteTrackPublication
    }

    override func updateFromInfo(info: Livekit_ParticipantInfo) {

        super.updateFromInfo(info: info)

        var validTrackPublications = [String: RemoteTrackPublication]()
        var newTrackPublications = [String: RemoteTrackPublication]()

        for trackInfo in info.tracks {
            var publication = getTrackPublication(sid: trackInfo.sid)
            if publication == nil {
                publication = RemoteTrackPublication(info: trackInfo, participant: self)
                newTrackPublications[trackInfo.sid] = publication
                addTrack(publication: publication!)
            } else {
                publication!.updateFromInfo(info: trackInfo)
            }
            validTrackPublications[trackInfo.sid] = publication!
        }

        room.engine.executeIfConnected { [weak self] in
            guard let self = self else { return }

            for publication in newTrackPublications.values {

                self.delegates.notify(label: { "participant.didPublish \(publication)" }) {
                    $0.participant?(self, didPublish: publication)
                }
                self.room.delegates.notify(label: { "room.didPublish \(publication)" }) {
                    $0.room?(self.room, participant: self, didPublish: publication)
                }
            }
        }

        let unpublishPromises = _state.tracks.values
            .filter { validTrackPublications[$0.sid] == nil }
            .compactMap { $0 as? RemoteTrackPublication }
            .map { unpublish(publication: $0) }

        // TODO: Return a promise
        unpublishPromises.all(on: queue).catch(on: queue) { error in
            self.log("Failed to unpublish with error: \(error)")
        }
    }

    internal func addSubscribedMediaTrack(rtcTrack: RTCMediaStreamTrack, sid: Sid) -> Promise<Void> {
        var track: Track

        guard let publication = getTrackPublication(sid: sid) else {
            log("Could not subscribe to mediaTrack \(sid), unable to locate track publication. existing sids: (\(_state.tracks.keys.joined(separator: ", ")))", .error)
            let error = TrackError.state(message: "Could not find published track with sid: \(sid)")
            delegates.notify(label: { "participant.didFailToSubscribe trackSid: \(sid)" }) {
                $0.participant?(self, didFailToSubscribe: sid, error: error)
            }
            room.delegates.notify(label: { "room.didFailToSubscribe trackSid: \(sid)" }) {
                $0.room?(self.room, participant: self, didFailToSubscribe: sid, error: error)
            }
            return Promise(error)
        }

        switch rtcTrack.kind {
        case "audio":
            track = RemoteAudioTrack(name: publication.name,
                                     source: publication.source,
                                     track: rtcTrack)
        case "video":
            track = RemoteVideoTrack(name: publication.name,
                                     source: publication.source,
                                     track: rtcTrack)
        default:
            let error = TrackError.type(message: "Unsupported type: \(rtcTrack.kind.description)")
            delegates.notify(label: { "participant.didFailToSubscribe trackSid: \(sid)" }) {
                $0.participant?(self, didFailToSubscribe: sid, error: error)
            }
            room.delegates.notify(label: { "room.didFailToSubscribe trackSid: \(sid)" }) {
                $0.room?(self.room, participant: self, didFailToSubscribe: sid, error: error)
            }
            return Promise(error)
        }

        publication.set(track: track)
        publication.set(subscriptionAllowed: true)
        track._state.mutate { $0.sid = publication.sid }

        addTrack(publication: publication)
        return track.start().then(on: queue) { _ -> Void in
            self.delegates.notify(label: { "participant.didSubscribe \(publication)" }) {
                $0.participant?(self, didSubscribe: publication, track: track)
            }
            self.room.delegates.notify(label: { "room.didSubscribe \(publication)" }) {
                $0.room?(self.room, participant: self, didSubscribe: publication, track: track)
            }
        }
    }

    internal override func cleanUp(notify _notify: Bool = true) -> Promise<Void> {
        super.cleanUp(notify: _notify).then(on: queue) {
            self.room.delegates.notify(label: { "room.participantDidLeave" }) {
                $0.room?(self.room, participantDidLeave: self)
            }
        }
    }
    
    public override func _unpublishAll(notify: Bool = true) async {
        await withUnsafeContinuation { continuation in
            _state.tracks.values.compactMap { $0 as? RemoteTrackPublication }
                .map { unpublish(publication: $0, notify: notify) }
                .all(on: queue).then(on: queue) {
                    continuation.resume()
                }
        }
    }
    
    public override func unpublishAll(notify _notify: Bool = true) -> Promise<Void> {
        // build a list of promises
        let promises = _state.tracks.values.compactMap { $0 as? RemoteTrackPublication }
            .map { unpublish(publication: $0, notify: _notify) }
        // combine promises to wait all to complete
        return promises.all(on: queue)
    }

    internal func unpublish(publication: RemoteTrackPublication, notify _notify: Bool = true) -> Promise<Void> {

        func notifyUnpublish() -> Promise<Void> {

            Promise<Void>(on: queue) { [weak self] in
                guard let self = self, _notify else { return }
                // notify unpublish
                self.delegates.notify(label: { "participant.didUnpublish \(publication)" }) {
                    $0.participant?(self, didUnpublish: publication)
                }
                self.room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                    $0.room?(self.room, participant: self, didUnpublish: publication)
                }
            }
        }

        // remove the publication
        _state.mutate { $0.tracks.removeValue(forKey: publication.sid) }

        // continue if the publication has a track
        guard let track = publication.track else {
            // if track is nil, only notify unpublish
            return notifyUnpublish()
        }

        return track.stop().then(on: queue) { _ -> Void in
            guard _notify else { return }
            // notify unsubscribe
            self.delegates.notify(label: { "participant.didUnsubscribe \(publication)" }) {
                $0.participant?(self, didUnsubscribe: publication, track: track)
            }
            self.room.delegates.notify(label: { "room.didUnsubscribe \(publication)" }) {
                $0.room?(self.room, participant: self, didUnsubscribe: publication, track: track)
            }
        }.then(on: queue) {
            notifyUnpublish()
        }
    }
}

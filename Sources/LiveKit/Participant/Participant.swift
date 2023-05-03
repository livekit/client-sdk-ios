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
public class Participant: NSObject, ObservableObject, Loggable {

    // MARK: - MulticastDelegate

    internal var delegates = MulticastDelegate<ParticipantDelegate>()

    internal let queue = DispatchQueue(label: "LiveKitSDK.participant", qos: .default)

    @objc
    public var sid: Sid { _state.sid }

    @objc
    public var identity: String { _state.identity }

    @objc
    public var name: String { _state.name }

    @objc
    public var audioLevel: Float { _state.audioLevel }

    @objc
    public var isSpeaking: Bool { _state.isSpeaking }

    @objc
    public var metadata: String? { _state.metadata }

    @objc
    public var connectionQuality: ConnectionQuality { _state.connectionQuality }

    @objc
    public var permissions: ParticipantPermissions { _state.permissions }

    @objc
    public var joinedAt: Date? { _state.joinedAt }

    @objc
    public var tracks: [String: TrackPublication] { _state.tracks }

    @objc
    public var audioTracks: [TrackPublication] {
        _state.tracks.values.filter { $0.kind == .audio }
    }

    @objc
    public var videoTracks: [TrackPublication] {
        _state.tracks.values.filter { $0.kind == .video }
    }

    internal var info: Livekit_ParticipantInfo?

    // Reference to the Room this Participant belongs to
    public let room: Room

    // MARK: - Internal

    internal struct State: Equatable, Hashable {
        let sid: Sid
        var identity: String
        var name: String
        var audioLevel: Float = 0.0
        var isSpeaking: Bool = false
        var metadata: String?
        var joinedAt: Date?
        var connectionQuality: ConnectionQuality = .unknown
        var permissions = ParticipantPermissions()
        var tracks = [String: TrackPublication]()
    }

    internal var _state: StateSync<State>

    internal init(sid: String,
                  identity: String,
                  name: String,
                  room: Room) {

        self.room = room

        // initial state
        _state = StateSync(State(
            sid: sid,
            identity: identity,
            name: name
        ))

        super.init()

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            if newState.isSpeaking != oldState.isSpeaking {
                self.delegates.notify(label: { "participant.didUpdate isSpeaking: \(self.isSpeaking)" }) {
                    $0.participant?(self, didUpdate: self.isSpeaking)
                }
            }

            // metadata updated
            if let metadata = newState.metadata, metadata != oldState.metadata,
               // don't notify if empty string (first time only)
               (oldState.metadata == nil ? !metadata.isEmpty : true) {

                self.delegates.notify(label: { "participant.didUpdate metadata: \(metadata)" }) {
                    $0.participant?(self, didUpdate: metadata)
                }
                self.room.delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                    $0.room?(self.room, participant: self, didUpdate: metadata)
                }
            }

            if newState.connectionQuality != oldState.connectionQuality {
                self.delegates.notify(label: { "participant.didUpdate connectionQuality: \(self.connectionQuality)" }) {
                    $0.participant?(self, didUpdate: self.connectionQuality)
                }
                self.room.delegates.notify(label: { "room.didUpdate connectionQuality: \(self.connectionQuality)" }) {
                    $0.room?(self.room, participant: self, didUpdate: self.connectionQuality)
                }
            }

            // notify object change when any state updates
            Task.detached { @MainActor in
                self.objectWillChange.send()
            }
        }
    }
    
    func _cleanUp(notify: Bool = true) async {
        await self._unpublishAll(notify: notify)
        // reset state
        self._state.mutate { $0 = State(identity: $0.identity, name: $0.name) }
    }

    @discardableResult
    internal func cleanUp(notify _notify: Bool = true) -> Promise<Void> {

        unpublishAll(notify: _notify).then(on: queue) {
            // reset state
            self._state.mutate { $0 = State(sid: $0.sid, identity: $0.identity, name: $0.name) }
        }
    }
    
    func _unpublishAll(notify: Bool = true) async {
        fatalError("implement in subclass")
    }

    internal func unpublishAll(notify _notify: Bool = true) -> Promise<Void> {
        fatalError("Unimplemented")
    }

    internal func addTrack(publication: TrackPublication) {
        _state.mutate { $0.tracks[publication.sid] = publication }
        publication.track?._state.mutate { $0.sid = publication.sid }
    }

    internal func updateFromInfo(info: Livekit_ParticipantInfo) {

        _state.mutate {
            $0.identity = info.identity
            $0.name = info.name
            $0.metadata = info.metadata
            $0.joinedAt = Date(timeIntervalSince1970: TimeInterval(info.joinedAt))
        }

        self.info = info
        set(permissions: info.permission.toLKType())
    }

    @discardableResult
    internal func set(permissions newValue: ParticipantPermissions) -> Bool {

        guard self.permissions != newValue else {
            // no change
            return false
        }

        _state.mutate { $0.permissions = newValue }

        return true
    }
}

// MARK: - Simplified API

extension Participant {

    public func isCameraEnabled() -> Bool {
        !(getTrackPublication(source: .camera)?.muted ?? true)
    }

    public func isMicrophoneEnabled() -> Bool {
        !(getTrackPublication(source: .microphone)?.muted ?? true)
    }

    public func isScreenShareEnabled() -> Bool {
        !(getTrackPublication(source: .screenShareVideo)?.muted ?? true)
    }

    internal func getTrackPublication(name: String) -> TrackPublication? {
        _state.tracks.values.first(where: { $0.name == name })
    }

    /// find the first publication matching `source` or any compatible.
    internal func getTrackPublication(source: Track.Source) -> TrackPublication? {
        // if source is unknown return nil
        guard source != .unknown else { return nil }
        // try to find a Publication with matching source
        if let result = _state.tracks.values.first(where: { $0.source == source }) {
            return result
        }
        // try to find a compatible Publication
        if let result = _state.tracks.values.filter({ $0.source == .unknown }).first(where: {
            (source == .microphone && $0.kind == .audio) ||
                (source == .camera && $0.kind == .video && $0.name != Track.screenShareVideoName) ||
                (source == .screenShareVideo && $0.kind == .video && $0.name == Track.screenShareVideoName) ||
                (source == .screenShareAudio && $0.kind == .audio && $0.name == Track.screenShareVideoName)
        }) {
            return result
        }

        return nil
    }
}

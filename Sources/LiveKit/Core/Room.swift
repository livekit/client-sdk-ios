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
import Network
import Promises
import WebRTC

public class Room: MulticastDelegate<RoomDelegate> {

    // MARK: - Public

    public var sid: Sid? { state.sid }
    public var name: String? { state.name }
    public var metadata: String? { state.metadata }
    public var serverVersion: String? { state.serverVersion }
    public var serverRegion: String? { state.serverRegion }

    public var localParticipant: LocalParticipant? { state.localParticipant }
    public var remoteParticipants: [Sid: RemoteParticipant] { state.remoteParticipants }
    public var activeSpeakers: [Participant] { state.activeSpeakers }

    // expose engine's vars
    public var url: String? { engine.url }
    public var token: String? { engine.token }
    public var connectionState: ConnectionState { engine.connectionState }
    public var connectStopwatch: Stopwatch { engine.connectStopwatch }

    // MARK: - Internal

    // Reference to Engine
    internal let engine: Engine
    internal private(set) var options: RoomOptions

    internal struct State {
        var sid: String?
        var name: String?
        var metadata: String?
        var serverVersion: String?
        var serverRegion: String?

        var localParticipant: LocalParticipant?
        var remoteParticipants = [Sid: RemoteParticipant]()
        var activeSpeakers = [Participant]()
    }

    // MARK: - Private

    private var state = StateSync(State())

    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions = ConnectOptions(),
                roomOptions: RoomOptions = RoomOptions()) {

        self.options = roomOptions
        self.engine = Engine(connectOptions: connectOptions,
                             roomOptions: roomOptions)
        super.init()

        // listen to engine & signalClient
        engine.add(delegate: self)
        engine.signalClient.add(delegate: self)

        if let delegate = delegate {
            add(delegate: delegate)
        }

        // listen to app states
        AppStateListener.shared.add(delegate: self)
    }

    deinit {
        log()
    }

    @discardableResult
    public func connect(_ url: String,
                        _ token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) -> Promise<Room> {

        // update options if specified
        self.options = roomOptions ?? self.options

        log("connecting to room", .info)
        guard state.localParticipant == nil else {
            return Promise(EngineError.state(message: "localParticipant is not nil"))
        }

        // monitor.start(queue: monitorQueue)
        return engine.connect(url, token,
                              connectOptions: connectOptions,
                              roomOptions: roomOptions).then(on: .sdk) { () -> Room in
                                self.log("connected to \(String(describing: self)) \(String(describing: self.localParticipant))", .info)
                                return self
                              }
    }

    @discardableResult
    public func disconnect() -> Promise<Void> {

        // return if already disconnected state
        if case .disconnected = connectionState { return Promise(()) }

        return engine.signalClient.sendLeave()
            .recover(on: .sdk) { self.log("Failed to send leave, error: \($0)") }
            .then(on: .sdk) {
                self.cleanUp(reason: .user)
            }
    }
}

// MARK: - Internal

internal extension Room.State {

    @discardableResult
    mutating func getOrCreateRemoteParticipant(sid: Sid, info: Livekit_ParticipantInfo? = nil, room: Room) -> RemoteParticipant {

        if let participant = remoteParticipants[sid] {
            return participant
        }

        let participant = RemoteParticipant(sid: sid, info: info, room: room)
        remoteParticipants[sid] = participant
        return participant
    }
}

// MARK: - Private

private extension Room {

    // Resets state of Room
    @discardableResult
    private func cleanUp(reason: DisconnectReason) -> Promise<Void> {

        log("reason: \(reason)")

        // Stop all local & remote tracks
        func cleanUpParticipants() -> Promise<Void> {

            let allParticipants = ([[localParticipant],
                                    state.remoteParticipants.map { $0.value }] as [[Participant?]])
                .joined()
                .compactMap { $0 }

            let cleanUpPromises = allParticipants.map { $0.cleanUp() }

            return cleanUpPromises.all(on: .sdk)
        }

        return engine.cleanUp(reason: reason)
            .then(on: .sdk) {
                cleanUpParticipants()
            }.then(on: .sdk) {
                // reset state
                self.state.mutate { $0 = State() }
            }.catch { error in
                // this should never happen
                self.log("Engine cleanUp failed", .error)
            }
    }

    @discardableResult
    func onParticipantDisconnect(sid: Sid) -> Promise<Void> {

        guard let participant = state.mutate({ $0.remoteParticipants.removeValue(forKey: sid) }) else {
            return Promise(EngineError.state(message: "Participant not found for \(sid)"))
        }

        // create array of unpublish promises
        let promises = participant.tracks.values
            .compactMap { $0 as? RemoteTrackPublication }
            .map { participant.unpublish(publication: $0) }

        return promises.all(on: .sdk).then(on: .sdk) {
            self.notify { $0.room(self, participantDidLeave: participant) }
        }
    }
}

// MARK: - Internal

internal extension Room {

    func set(metadata: String?) {
        guard self.metadata != metadata else { return }

        self.state.mutate { state in
            state.metadata = metadata
        }

        notify { $0.room(self, didUpdate: metadata) }
    }
}

// MARK: - Debugging

extension Room {

    @discardableResult
    public func sendSimulate(scenario: SimulateScenario) -> Promise<Void> {
        engine.signalClient.sendSimulate(scenario: scenario)
    }
}

// MARK: - Session Migration

internal extension Room {

    func sendTrackSettings() -> Promise<Void> {
        log()

        let promises = state.remoteParticipants.values.map {
            $0.tracks.values
                .compactMap { $0 as? RemoteTrackPublication }
                .filter { $0.subscribed }
                .map { $0.sendCurrentTrackSettings() }
        }.joined()

        return promises.all(on: .sdk)
    }

    func sendSyncState() -> Promise<Void> {

        guard let subscriber = engine.subscriber,
              let localDescription = subscriber.localDescription else {
            // No-op
            return Promise(())
        }

        let sendUnSub = engine.connectOptions.autoSubscribe
        let participantTracks = state.remoteParticipants.values.map { participant in
            Livekit_ParticipantTracks.with {
                $0.participantSid = participant.sid
                $0.trackSids = participant.tracks.values
                    .filter { $0.subscribed != sendUnSub }
                    .map { $0.sid }
            }
        }

        // Backward compatibility
        let trackSids = participantTracks.map { $0.trackSids }.flatMap { $0 }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids // Deprecated
            $0.participantTracks = participantTracks
            $0.subscribe = !sendUnSub
        }

        return engine.signalClient.sendSyncState(answer: localDescription.toPBType(),
                                                 subscription: subscription,
                                                 publishTracks: state.localParticipant?.publishedTracksInfo(),
                                                 dataChannels: engine.dataChannelInfo())
    }
}

// MARK: - SignalClientDelegate

extension Room: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didUpdate connectionState: ConnectionState, oldValue: ConnectionState) -> Bool {
        log()

        guard !connectionState.isEqual(to: oldValue, includingAssociatedValues: false) else {
            log("Skipping same conectionState")
            return true
        }

        if case .quick = self.connectionState.reconnectingWithMode,
           case .quick = connectionState.reconnectedWithMode {
            sendSyncState().catch { error in
                self.log("Failed to sendSyncState, error: \(error)", .error)
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) -> Bool {
        log()

        guard let localParticipant = state.localParticipant else { return true }
        localParticipant.onSubscribedQualitiesUpdate(trackSid: trackSid, subscribedQualities: subscribedQualities)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) -> Bool {

        log("Server version: \(joinResponse.serverVersion), region: \(joinResponse.serverRegion)", .info)

        state.mutate {
            $0.sid = joinResponse.room.sid
            $0.name = joinResponse.room.name
            $0.metadata = joinResponse.room.metadata
            $0.serverVersion = joinResponse.serverVersion
            $0.serverRegion = joinResponse.serverRegion.isEmpty ? nil : joinResponse.serverRegion

            if joinResponse.hasParticipant {
                $0.localParticipant = LocalParticipant(from: joinResponse.participant, room: self)
            }

            if !joinResponse.otherParticipants.isEmpty {
                for otherParticipant in joinResponse.otherParticipants {
                    $0.getOrCreateRemoteParticipant(sid: otherParticipant.sid, info: otherParticipant, room: self)
                }
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate room: Livekit_Room) -> Bool {
        set(metadata: room.metadata)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) -> Bool {
        log("speakers: \(speakers)", .trace)

        let activeSpeakers = state.mutate { state -> [Participant] in

            var lastSpeakers = state.activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
            for speaker in speakers {

                guard let participant = speaker.sid == state.localParticipant?.sid ? state.localParticipant : state.remoteParticipants[speaker.sid] else {
                    continue
                }

                participant.audioLevel = speaker.level
                participant.isSpeaking = speaker.active
                if speaker.active {
                    lastSpeakers[speaker.sid] = participant
                } else {
                    lastSpeakers.removeValue(forKey: speaker.sid)
                }
            }

            state.activeSpeakers = lastSpeakers.values.sorted(by: { $1.audioLevel > $0.audioLevel })

            return state.activeSpeakers
        }

        notify { $0.room(self, didUpdate: activeSpeakers) }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) -> Bool {
        log("connectionQuality: \(connectionQuality)", .trace)

        state.mutate {
            for entry in connectionQuality {
                if let localParticipant = $0.localParticipant,
                   entry.participantSid == localParticipant.sid {
                    // update for LocalParticipant
                    localParticipant.connectionQuality = entry.quality.toLKType()
                } else if let participant = $0.remoteParticipants[entry.participantSid] {
                    // udpate for RemoteParticipant
                    participant.connectionQuality = entry.quality.toLKType()
                }
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) -> Bool {
        log("trackSid: \(trackSid) muted: \(muted)")

        guard let publication = state.localParticipant?.tracks[trackSid] as? LocalTrackPublication else {
            // publication was not found but the delegate was handled
            return true
        }

        if muted {
            publication.mute()
        } else {
            publication.unmute()
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate subscriptionPermission: Livekit_SubscriptionPermissionUpdate) -> Bool {
        log("subscriptionPermission: \(subscriptionPermission)")

        guard let participant = state.remoteParticipants[subscriptionPermission.participantSid],
              let publication = participant.getTrackPublication(sid: subscriptionPermission.trackSid) else {
            return true
        }

        publication.set(subscriptionAllowed: subscriptionPermission.allowed)

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) -> Bool {

        log("trackStates: \(trackStates.map { "(\($0.trackSid): \(String(describing: $0.state)))" }.joined(separator: ", "))")

        for update in trackStates {
            // Try to find RemoteParticipant
            guard let participant = state.remoteParticipants[update.participantSid] else { continue }
            // Try to find RemoteTrackPublication
            guard let trackPublication = participant.tracks[update.trackSid] as? RemoteTrackPublication else { continue }
            // Update streamState (and notify)
            trackPublication.streamState = update.state.toLKType()
        }
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) -> Bool {
        log("participants: \(participants)")

        var disconnectedParticipants = [Sid]()
        var newParticipants = [RemoteParticipant]()

        state.mutate {

            for info in participants {

                if info.sid == $0.localParticipant?.sid {
                    $0.localParticipant?.updateFromInfo(info: info)
                    continue
                }

                let isNewParticipant = $0.remoteParticipants[info.sid] == nil
                let participant = $0.getOrCreateRemoteParticipant(sid: info.sid, info: info, room: self)

                if info.state == .disconnected {
                    disconnectedParticipants.append(info.sid)
                } else if isNewParticipant {
                    newParticipants.append(participant)
                } else {
                    participant.updateFromInfo(info: info)
                }
            }
        }

        for sid in disconnectedParticipants {
            onParticipantDisconnect(sid: sid)
        }

        for participant in newParticipants {
            notify { $0.room(self, participantDidJoin: participant) }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUnpublish localTrack: Livekit_TrackUnpublishedResponse) -> Bool {
        log()

        guard let localParticipant = localParticipant,
              let publication = localParticipant.tracks[localTrack.trackSid] as? LocalTrackPublication else {
            log("track publication not found", .warning)
            return true
        }

        localParticipant.unpublish(publication: publication).then { [weak self] _ in
            self?.log("unpublished track(\(localTrack.trackSid)")
        }.catch { [weak self] error in
            self?.log("failed to unpublish track(\(localTrack.trackSid), error: \(error)", .warning)
        }

        return true
    }
}

// MARK: - EngineDelegate

extension Room: EngineDelegate {

    func engine(_ engine: Engine, didGenerate trackStats: [TrackStats], target: Livekit_SignalTarget) {

        let allParticipants = ([[localParticipant],
                                state.remoteParticipants.map { $0.value }] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        let allTracks = allParticipants.map { $0.tracks.values.map { $0.track } }.joined()
            .compactMap { $0 }

        // this relies on the last stat entry being the latest
        for track in allTracks {
            if let stats = trackStats.last(where: { $0.trackId == track.mediaTrack.trackId }) {
                track.set(stats: stats)
            }
        }
    }

    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo]) {

        let activeSpeakers = state.mutate { state -> [Participant] in

            var activeSpeakers: [Participant] = []
            var seenSids = [String: Bool]()
            for speaker in speakers {
                seenSids[speaker.sid] = true
                if let localParticipant = state.localParticipant,
                   speaker.sid == localParticipant.sid {
                    localParticipant.audioLevel = speaker.level
                    localParticipant.isSpeaking = true
                    activeSpeakers.append(localParticipant)
                } else {
                    if let participant = state.remoteParticipants[speaker.sid] {
                        participant.audioLevel = speaker.level
                        participant.isSpeaking = true
                        activeSpeakers.append(participant)
                    }
                }
            }

            if let localParticipant = state.localParticipant, seenSids[localParticipant.sid] == nil {
                localParticipant.audioLevel = 0.0
                localParticipant.isSpeaking = false
            }

            for participant in state.remoteParticipants.values {
                if seenSids[participant.sid] == nil {
                    participant.audioLevel = 0.0
                    participant.isSpeaking = false
                }
            }

            return activeSpeakers
        }

        notify { $0.room(self, didUpdate: activeSpeakers) }
    }

    func engine(_ engine: Engine, didUpdate connectionState: ConnectionState, oldValue: ConnectionState) {
        log()

        defer { notify { $0.room(self, didUpdate: connectionState, oldValue: oldValue) } }

        guard !connectionState.isEqual(to: oldValue, includingAssociatedValues: false) else {
            log("Skipping same conectionState")
            return
        }

        // Deprecated
        if case .connected(let mode) = connectionState {
            var didReconnect = false
            if case .reconnect = mode { didReconnect = true }
            // Backward compatibility
            notify { $0.room(self, didConnect: didReconnect) }

            // Re-publish on full reconnect
            if case .reconnect(let rmode) = mode,
               case .full = rmode {
                log("Should re-publish existing tracks")
                localParticipant?.republishTracks().catch { error in
                    self.log("Failed to republish all track, error: \(error)", .error)
                }
            }

        } else if case .disconnected(let reason) = connectionState {
            if case .connected = oldValue {
                // Backward compatibility
                notify { $0.room(self, didDisconnect: reason.error ) }
            } else {
                // Backward compatibility
                notify { $0.room(self, didFailToConnect: reason.error ?? NetworkError.disconnected() ) }
            }

            cleanUp(reason: reason)
        }

        if connectionState.didReconnect {
            // Re-send track settings on a reconnect
            sendTrackSettings().catch { error in
                self.log("Failed to sendTrackSettings, error: \(error)", .error)
            }
        }
    }

    func engine(_ engine: Engine, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {

        guard !streams.isEmpty else {
            log("Received onTrack with no streams!", .warning)
            return
        }

        let unpacked = streams[0].streamId.unpack()
        let participantSid = unpacked.sid
        var trackSid = unpacked.trackId
        if trackSid == "" {
            trackSid = track.trackId
        }

        let participant = state.mutate { $0.getOrCreateRemoteParticipant(sid: participantSid, room: self) }

        log("added media track from: \(participantSid), sid: \(trackSid)")

        _ = retry(attempts: 10, delay: 0.2) { _, error in
            // if error is invalidTrackState, retry
            guard case TrackError.state = error else { return false }
            return true
        } _: {
            participant.addSubscribedMediaTrack(rtcTrack: track, sid: trackSid)
        }
    }

    func engine(_ engine: Engine, didRemove track: RTCMediaStreamTrack) {
        // find the publication
        guard let publication = state.remoteParticipants.values.map({ $0.tracks.values }).joined()
                .first(where: { $0.sid == track.trackId }) else { return }
        publication.set(track: nil)
    }

    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {
        // participant could be null if data broadcasted from server
        let participant = state.remoteParticipants[userPacket.participantSid]

        notify { $0.room(self, participant: participant, didReceive: userPacket.payload) }
        participant?.notify { [weak participant] (delegate) -> Void in
            guard let participant = participant else { return }
            delegate.participant(participant, didReceive: userPacket.payload)
        }
    }
}

// MARK: - AppStateDelegate

extension Room: AppStateDelegate {

    func appDidEnterBackground() {

        guard options.suspendLocalVideoTracksInBackground else { return }

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.map { $0.suspend() }

        guard !promises.isEmpty else { return }

        promises.all(on: .sdk).then {
            self.log("suspended all video tracks")
        }
    }

    func appWillEnterForeground() {

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.map { $0.resume() }

        guard !promises.isEmpty else { return }

        promises.all(on: .sdk).then {
            self.log("resumed all video tracks")
        }
    }

    func appWillTerminate() {
        // attempt to disconnect if already connected.
        // this is not guranteed since there is no reliable way to detect app termination.
        disconnect()
    }
}

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

#if canImport(Network)
import Network
#endif

@objc
public class Room: NSObject, ObservableObject, Loggable {

    // MARK: - MulticastDelegate

    internal var delegates = MulticastDelegate<RoomDelegateObjC>()

    internal let queue = DispatchQueue(label: "LiveKitSDK.room", qos: .default)

    // MARK: - Public

    @objc
    public var sid: Sid? { _state.sid }

    @objc
    public var name: String? { _state.name }

    /// Room's metadata.
    @objc
    public var metadata: String? { _state.metadata }

    @objc
    public var serverVersion: String? { _state.serverVersion }

    /// Region code the client is currently connected to.
    @objc
    public var serverRegion: String? { _state.serverRegion }

    @objc
    public var localParticipant: LocalParticipant? { _state.localParticipant }

    @objc
    public var remoteParticipants: [Sid: RemoteParticipant] { _state.remoteParticipants }

    @objc
    public var activeSpeakers: [Participant] { _state.activeSpeakers }

    /// If the current room has a participant with `recorder:true` in its JWT grant.
    @objc
    public var isRecording: Bool { _state.isRecording }

    // expose engine's vars
    @objc
    public var url: String? { engine._state.url }

    @objc
    public var token: String? { engine._state.token }

    /// Current ``ConnectionState`` of the ``Room``.
    public var connectionState: ConnectionState { engine._state.connectionState }

    /// Only for Objective-C.
    @objc(connectionState)
    @available(swift, obsoleted: 1.0)
    public var connectionStateObjC: ConnectionStateObjC { engine._state.connectionState.toObjCType() }

    public var connectStopwatch: Stopwatch { engine._state.connectStopwatch }

    // MARK: - Internal

    // Reference to Engine
    internal let engine: Engine

    internal struct State: Equatable {
        var options: RoomOptions

        var sid: String?
        var name: String?
        var metadata: String?
        var serverVersion: String?
        var serverRegion: String?

        var localParticipant: LocalParticipant?
        var remoteParticipants = [Sid: RemoteParticipant]()
        var activeSpeakers = [Participant]()

        var isRecording: Bool = false

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

    internal var _state: StateSync<State>

    // MARK: Objective-C Support

    @objc
    public convenience override init() {

        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    @objc
    public init(delegate: RoomDelegateObjC? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil) {

        self._state = StateSync(State(options: roomOptions ?? RoomOptions()))
        self.engine = Engine(connectOptions: connectOptions ?? ConnectOptions())
        super.init()

        log()

        // weak ref
        engine.room = self

        // listen to engine & signalClient
        engine.add(delegate: self)
        engine.signalClient.add(delegate: self)

        if let delegate = delegate {
            log("delegate: \(String(describing: delegate))")
            delegates.add(delegate: delegate)
        }

        // listen to app states
        AppStateListener.shared.add(delegate: self)

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            // metadata updated
            if let metadata = newState.metadata, metadata != oldState.metadata,
               // don't notify if empty string (first time only)
               (oldState.metadata == nil ? !metadata.isEmpty : true) {

                // proceed only if connected...
                self.engine.executeIfConnected { [weak self] in

                    guard let self = self else { return }

                    self.delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                        $0.room?(self, didUpdate: metadata)
                    }
                }
            }

            // isRecording updated
            if newState.isRecording != oldState.isRecording {
                // proceed only if connected...
                self.engine.executeIfConnected { [weak self] in

                    guard let self = self else { return }

                    self.delegates.notify(label: { "room.didUpdate isRecording: \(newState.isRecording)" }) {
                        $0.room?(self, didUpdate: newState.isRecording)
                    }
                }
            }

            Task.detached { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    deinit {
        log()
    }
    
    public func _connect(url: String, token: String, connectOptions: ConnectOptions? = nil, roomOptions: RoomOptions? = nil) async throws {

        log("connecting to room...", .info)

        let state = _state.readCopy()

        guard state.localParticipant == nil else {
            log("localParticipant is not nil", .warning)
            throw EngineError.state(message: "localParticipant is not nil")
        }

        // update options if specified
        if let roomOptions = roomOptions, roomOptions != state.options {
            _state.mutate { $0.options = roomOptions }
        }

        try await engine._connect(url: url, token: token, connectOptions: connectOptions)
        log("connected to \(String(describing: self)) \(String(describing: state.localParticipant))", .info)
    }

    @discardableResult
    public func connect(_ url: String,
                        _ token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) -> Promise<Room> {

        log("connecting to room...", .info)

        let state = _state.copy()

        guard state.localParticipant == nil else {
            log("localParticipant is not nil", .warning)
            return Promise(EngineError.state(message: "localParticipant is not nil"))
        }

        // update options if specified
        if let roomOptions = roomOptions, roomOptions != state.options {
            _state.mutate { $0.options = roomOptions }
        }

        // monitor.start(queue: monitorQueue)
        return engine.connect(url, token,
                              connectOptions: connectOptions).then(on: queue) { () -> Room in
                                self.log("connected to \(String(describing: self)) \(String(describing: state.localParticipant))", .info)
                                return self
                              }
    }
    
    public func _disconnect() async throws {

        // return if already disconnected state
        guard case .connected = connectionState else { return }

        do {
            try await engine.signalClient.sendLeave()
        } catch {
            log("Failed to send leave, error: \(error)")
        }
        
        await _cleanUp(reason: .user)
    }

    @discardableResult
    public func disconnect() -> Promise<Void> {

        // return if already disconnected state
        if case .disconnected = connectionState { return Promise(()) }

        return engine.signalClient.sendLeave()
            .recover(on: queue) { self.log("Failed to send leave, error: \($0)") }
            .then(on: queue) { [weak self] in
                guard let self = self else { return }
                self.cleanUp(reason: .user)
            }
    }
}

// MARK: - Internal

internal extension Room {

    func _cleanUp(reason: DisconnectReason? = nil, isFullReconnect: Bool = false) async {
        
        log("reason: \(String(describing: reason))")
        
        engine._state.mutate {
            $0.primaryTransportConnectedCompleter.reset()
            $0.publisherTransportConnectedCompleter.reset()

            // if isFullReconnect, keep connection related states
            $0 = isFullReconnect ? Engine.State(
                connectOptions: $0.connectOptions,
                url: $0.url,
                token: $0.token,
                nextPreferredReconnectMode: $0.nextPreferredReconnectMode,
                reconnectMode: $0.reconnectMode,
                connectionState: $0.connectionState
            ) : Engine.State(
                connectOptions: $0.connectOptions,
                connectionState: .disconnected(reason: reason)
            )
        }
        
        await engine.signalClient._cleanUp(reason: reason)
        log("did cleanUp signalClient")
        
        await engine._cleanupRTC()
        log("did cleanup RTC engine")
        
        await _cleanupParticipants()
        log("did cleanUp participants")
        
        self._state.mutate { $0 = State(options: $0.options) }
    }
    
    // Resets state of Room
    @discardableResult
    func cleanUp(reason: DisconnectReason? = nil,
                 isFullReconnect: Bool = false) -> Promise<Void> {

        log("reason: \(String(describing: reason))")

        // start Engine cleanUp sequence

        engine._state.mutate {
            $0.primaryTransportConnectedCompleter.reset()
            $0.publisherTransportConnectedCompleter.reset()

            // if isFullReconnect, keep connection related states
            $0 = isFullReconnect ? Engine.State(
                connectOptions: $0.connectOptions,
                url: $0.url,
                token: $0.token,
                nextPreferredReconnectMode: $0.nextPreferredReconnectMode,
                reconnectMode: $0.reconnectMode,
                connectionState: $0.connectionState
            ) : Engine.State(
                connectOptions: $0.connectOptions,
                connectionState: .disconnected(reason: reason)
            )
        }

        engine.signalClient.cleanUp(reason: reason)

        return engine.cleanUpRTC().then(on: queue) {
            self.cleanUpParticipants()
        }.then(on: queue) {
            // reset state
            self._state.mutate { $0 = State(options: $0.options) }
        }.catch(on: queue) { error in
            // this should never happen
            self.log("Room cleanUp failed with error: \(error)", .error)
        }
    }
    
    func _cleanupParticipants(notify: Bool = true) async {
        
        log("notify: \(notify)")
        
        await withTaskGroup(of: Void.self, body: { [localParticipant, _state] group in
            
            if let localParticipant {
                group.addTask {
                    await localParticipant._cleanUp(notify: notify)
                }
            }
            
            // Stop all local --^ & remote tracks --v
            _state.remoteParticipants.values.compactMap { $0 }.forEach { participant in
                group.addTask {
                    await participant._cleanUp(notify: notify)
                }
            }
        })
        
        //reset state and be done
        _state.mutate {
            $0.localParticipant = nil
            $0.remoteParticipants = [:]
        }
    }
}

// MARK: - Private

private extension Room {

    @discardableResult
    func cleanUpParticipants(notify _notify: Bool = true) -> Promise<Void> {

        log("notify: \(_notify)")

        // Stop all local & remote tracks
        let allParticipants = ([[localParticipant],
                                _state.remoteParticipants.map { $0.value }] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        let cleanUpPromises = allParticipants.map { $0.cleanUp(notify: _notify) }

        return cleanUpPromises.all(on: queue).then(on: queue) {
            //
            self._state.mutate {
                $0.localParticipant = nil
                $0.remoteParticipants = [:]
            }
        }
    }

    @discardableResult
    func onParticipantDisconnect(sid: Sid) -> Promise<Void> {

        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: sid) }) else {
            return Promise(EngineError.state(message: "Participant not found for \(sid)"))
        }

        return participant.cleanUp(notify: true)
    }
}

// MARK: - Debugging

extension Room {

    @discardableResult
    public func sendSimulate(scenario: SimulateScenario) -> Promise<Void> {
        engine.signalClient.sendSimulate(scenario: scenario)
    }

    public func waitForPrimaryTransportConnect() -> Promise<Bool> {
        engine._state.mutate {
            $0.primaryTransportConnectedCompleter.wait(on: queue, .defaultTransportState, throw: { TransportError.timedOut(message: "primary transport didn't connect") })
        }
    }

    public func waitForPublisherTransportConnect() -> Promise<Bool> {
        engine._state.mutate {
            $0.publisherTransportConnectedCompleter.wait(on: queue, .defaultTransportState, throw: { TransportError.timedOut(message: "publisher transport didn't connect") })
        }
    }
}

// MARK: - Session Migration

internal extension Room {

    func resetTrackSettings() {

        log("resetting track settings...")

        // create an array of RemoteTrackPublication
        let remoteTrackPublications = _state.remoteParticipants.values.map {
            $0._state.tracks.values.compactMap { $0 as? RemoteTrackPublication }
        }.joined()

        // reset track settings for all RemoteTrackPublication
        for publication in remoteTrackPublications {
            publication.resetTrackSettings()
        }
    }
}

// MARK: - SignalClientDelegate

extension Room: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didReceiveLeave canReconnect: Bool, reason: Livekit_DisconnectReason) -> Bool {

        log("canReconnect: \(canReconnect), reason: \(reason)")

        if canReconnect {
            // force .full for next reconnect
            engine._state.mutate { $0.nextPreferredReconnectMode = .full }
        } else {
            // server indicates it's not recoverable
            cleanUp(reason: reason.toLKType())
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) -> Bool {

        log("qualities: \(subscribedQualities.map({ String(describing: $0) }).joined(separator: ", "))")

        guard let localParticipant = _state.localParticipant else { return true }
        localParticipant.onSubscribedQualitiesUpdate(trackSid: trackSid, subscribedQualities: subscribedQualities)
        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceive joinResponse: Livekit_JoinResponse) -> Bool {

        log("server version: \(joinResponse.serverVersion), region: \(joinResponse.serverRegion)", .info)

        _state.mutate {
            $0.sid = joinResponse.room.sid
            $0.name = joinResponse.room.name
            $0.metadata = joinResponse.room.metadata
            $0.serverVersion = joinResponse.serverVersion
            $0.serverRegion = joinResponse.serverRegion.isEmpty ? nil : joinResponse.serverRegion
            $0.isRecording = joinResponse.room.activeRecording

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
        _state.mutate {
            $0.metadata = room.metadata
            $0.isRecording = room.activeRecording
        }
        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate speakers: [Livekit_SpeakerInfo]) -> Bool {
        log("speakers: \(speakers)", .trace)

        let activeSpeakers = _state.mutate { state -> [Participant] in

            var lastSpeakers = state.activeSpeakers.reduce(into: [Sid: Participant]()) { $0[$1.sid] = $1 }
            for speaker in speakers {

                guard let participant = speaker.sid == state.localParticipant?.sid ? state.localParticipant : state.remoteParticipants[speaker.sid] else {
                    continue
                }

                participant._state.mutate {
                    $0.audioLevel = speaker.level
                    $0.isSpeaking = speaker.active
                }

                if speaker.active {
                    lastSpeakers[speaker.sid] = participant
                } else {
                    lastSpeakers.removeValue(forKey: speaker.sid)
                }
            }

            state.activeSpeakers = lastSpeakers.values.sorted(by: { $1.audioLevel > $0.audioLevel })

            return state.activeSpeakers
        }

        engine.executeIfConnected { [weak self] in
            guard let self = self else { return }

            self.delegates.notify(label: { "room.didUpdate speakers: \(speakers)" }) {
                $0.room?(self, didUpdate: activeSpeakers)
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate connectionQuality: [Livekit_ConnectionQualityInfo]) -> Bool {
        log("connectionQuality: \(connectionQuality)", .trace)

        for entry in connectionQuality {
            if let localParticipant = _state.localParticipant,
               entry.participantSid == localParticipant.sid {
                // update for LocalParticipant
                localParticipant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            } else if let participant = _state.remoteParticipants[entry.participantSid] {
                // udpate for RemoteParticipant
                participant._state.mutate { $0.connectionQuality = entry.quality.toLKType() }
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdateRemoteMute trackSid: String, muted: Bool) -> Bool {
        log("trackSid: \(trackSid) muted: \(muted)")

        guard let publication = _state.localParticipant?._state.tracks[trackSid] as? LocalTrackPublication else {
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

        log("did update subscriptionPermission: \(subscriptionPermission)")

        guard let participant = _state.remoteParticipants[subscriptionPermission.participantSid],
              let publication = participant.getTrackPublication(sid: subscriptionPermission.trackSid) else {
            return true
        }

        publication.set(subscriptionAllowed: subscriptionPermission.allowed)

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate trackStates: [Livekit_StreamStateInfo]) -> Bool {

        log("did update trackStates: \(trackStates.map { "(\($0.trackSid): \(String(describing: $0.state)))" }.joined(separator: ", "))")

        for update in trackStates {
            // Try to find RemoteParticipant
            guard let participant = _state.remoteParticipants[update.participantSid] else { continue }
            // Try to find RemoteTrackPublication
            guard let trackPublication = participant._state.tracks[update.trackSid] as? RemoteTrackPublication else { continue }
            // Update streamState (and notify)
            trackPublication._state.mutate { $0.streamState = update.state.toLKType() }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate participants: [Livekit_ParticipantInfo]) -> Bool {
        log("participants: \(participants)")

        var disconnectedParticipants = [Sid]()
        var newParticipants = [RemoteParticipant]()

        _state.mutate {

            for info in participants {

                if info.sid == $0.localParticipant?.sid {
                    $0.localParticipant?.updateFromInfo(info: info)
                    continue
                }

                if info.state == .disconnected {
                    // when it's disconnected, send updates
                    disconnectedParticipants.append(info.sid)
                } else {

                    let isNewParticipant = $0.remoteParticipants[info.sid] == nil
                    let participant = $0.getOrCreateRemoteParticipant(sid: info.sid, info: info, room: self)

                    if isNewParticipant {
                        newParticipants.append(participant)
                    } else {
                        participant.updateFromInfo(info: info)
                    }
                }
            }
        }

        for sid in disconnectedParticipants {
            onParticipantDisconnect(sid: sid)
        }

        for participant in newParticipants {

            engine.executeIfConnected { [weak self] in
                guard let self = self else { return }

                self.delegates.notify(label: { "room.participantDidJoin participant: \(participant)" }) {
                    $0.room?(self, participantDidJoin: participant)
                }
            }
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUnpublish localTrack: Livekit_TrackUnpublishedResponse) -> Bool {
        log()

        guard let localParticipant = localParticipant,
              let publication = localParticipant._state.tracks[localTrack.trackSid] as? LocalTrackPublication else {
            log("track publication not found", .warning)
            return true
        }

        localParticipant.unpublish(publication: publication).then(on: queue) { [weak self] _ in
            self?.log("unpublished track(\(localTrack.trackSid)")
        }.catch(on: queue) { [weak self] error in
            self?.log("failed to unpublish track(\(localTrack.trackSid), error: \(error)", .warning)
        }

        return true
    }
}

// MARK: - EngineDelegate

extension Room: EngineDelegate {

    func engine(_ engine: Engine, didUpdate dataChannel: RTCDataChannel, state: RTCDataChannelState) {
        //
    }

    func engine(_ engine: Engine, didMutate state: Engine.State, oldState: Engine.State) {

        if state.connectionState != oldState.connectionState {
            // connectionState did update

            // only if quick-reconnect
            if case .connected = state.connectionState, case .quick = state.reconnectMode {

                resetTrackSettings()
            }

            // re-send track permissions
            if case .connected = state.connectionState, let localParticipant = localParticipant {
                localParticipant.sendTrackSubscriptionPermissions().catch(on: queue) { error in
                    self.log("Failed to send track subscription permissions, error: \(error)", .error)
                }
            }

            delegates.notify(label: { "room.didUpdate connectionState: \(state.connectionState) oldValue: \(oldState.connectionState)" }) {
                // Objective-C support
                $0.room?(self, didUpdate: state.connectionState.toObjCType(), oldValue: oldState.connectionState.toObjCType())
                // Swift only
                if let delegateSwift = $0 as? RoomDelegate {
                    delegateSwift.room(self, didUpdate: state.connectionState, oldValue: oldState.connectionState)
                }
            }
        }

        if state.connectionState.isReconnecting && state.reconnectMode == .full && oldState.reconnectMode != .full {
            // started full reconnect
            cleanUpParticipants(notify: true)
        }

        // Notify change when engine's state mutates
        Task.detached { @MainActor in
            self.objectWillChange.send()
        }
    }

    func engine(_ engine: Engine, didGenerate trackStats: [TrackStats], target: Livekit_SignalTarget) {

        let allParticipants = ([[localParticipant],
                                _state.remoteParticipants.map { $0.value }] as [[Participant?]])
            .joined()
            .compactMap { $0 }

        let allTracks = allParticipants.map { $0._state.tracks.values.map { $0.track } }.joined()
            .compactMap { $0 }

        // this relies on the last stat entry being the latest
        for track in allTracks {
            if let stats = trackStats.last(where: { $0.trackId == track.mediaTrack.trackId }) {
                track.set(stats: stats)
            }
        }
    }

    func engine(_ engine: Engine, didUpdate speakers: [Livekit_SpeakerInfo]) {

        let activeSpeakers = _state.mutate { state -> [Participant] in

            var activeSpeakers: [Participant] = []
            var seenSids = [String: Bool]()
            for speaker in speakers {
                seenSids[speaker.sid] = true
                if let localParticipant = state.localParticipant,
                   speaker.sid == localParticipant.sid {
                    localParticipant._state.mutate {
                        $0.audioLevel = speaker.level
                        $0.isSpeaking = true
                    }
                    activeSpeakers.append(localParticipant)
                } else {
                    if let participant = state.remoteParticipants[speaker.sid] {
                        participant._state.mutate {
                            $0.audioLevel = speaker.level
                            $0.isSpeaking = true
                        }
                        activeSpeakers.append(participant)
                    }
                }
            }

            if let localParticipant = state.localParticipant, seenSids[localParticipant.sid] == nil {
                localParticipant._state.mutate {
                    $0.audioLevel = 0.0
                    $0.isSpeaking = false
                }
            }

            for participant in state.remoteParticipants.values {
                if seenSids[participant.sid] == nil {
                    participant._state.mutate {
                        $0.audioLevel = 0.0
                        $0.isSpeaking = false
                    }
                }
            }

            return activeSpeakers
        }

        engine.executeIfConnected { [weak self] in
            guard let self = self else { return }

            self.delegates.notify(label: { "room.didUpdate speakers: \(activeSpeakers)" }) {
                $0.room?(self, didUpdate: activeSpeakers)
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

        let participant = _state.mutate { $0.getOrCreateRemoteParticipant(sid: participantSid, room: self) }

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
        guard let publication = _state.remoteParticipants.values.map({ $0._state.tracks.values }).joined()
                .first(where: { $0.sid == track.trackId }) else { return }
        publication.set(track: nil)
    }

    func engine(_ engine: Engine, didReceive userPacket: Livekit_UserPacket) {
        // participant could be null if data broadcasted from server
        let participant = _state.remoteParticipants[userPacket.participantSid]

        engine.executeIfConnected { [weak self] in
            guard let self = self else { return }

            self.delegates.notify(label: { "room.didReceive data: \(userPacket.payload)" }) {
                // deprecated
                $0.room?(self, participant: participant, didReceive: userPacket.payload)
                // new method with topic param
                $0.room?(self, participant: participant, didReceiveData: userPacket.payload, topic: userPacket.topic)
            }

            if let participant = participant {
                participant.delegates.notify(label: { "participant.didReceive data: \(userPacket.payload)" }) { [weak participant] (delegate) -> Void in
                    guard let participant = participant else { return }
                    // deprecated
                    delegate.participant?(participant, didReceive: userPacket.payload)
                    // new method with topic param
                    delegate.participant?(participant, didReceiveData: userPacket.payload, topic: userPacket.topic)
                }
            }
        }
    }
}

// MARK: - AppStateDelegate

extension Room: AppStateDelegate {

    func appDidEnterBackground() {

        guard _state.options.suspendLocalVideoTracksInBackground else { return }

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.map { $0.suspend() }

        guard !promises.isEmpty else { return }

        promises.all(on: queue).then(on: queue) {
            self.log("suspended all video tracks")
        }
    }

    func appWillEnterForeground() {

        guard let localParticipant = localParticipant else { return }
        let promises = localParticipant.localVideoTracks.map { $0.resume() }

        guard !promises.isEmpty else { return }

        promises.all(on: queue).then(on: queue) {
            self.log("resumed all video tracks")
        }
    }

    func appWillTerminate() {
        // attempt to disconnect if already connected.
        // this is not guranteed since there is no reliable way to detect app termination.
        disconnect()
    }
}

// MARK: - Devices

extension Room {

    @objc
    public static var audioDeviceModule: RTCAudioDeviceModule {
        Engine.audioDeviceModule
    }

    /// Set this to true to bypass initialization of voice processing.
    /// Must be set before RTCPeerConnectionFactory gets initialized.
    @objc
    public static var bypassVoiceProcessing: Bool {
        get { Engine.bypassVoiceProcessing }
        set { Engine.bypassVoiceProcessing = newValue }
    }
}

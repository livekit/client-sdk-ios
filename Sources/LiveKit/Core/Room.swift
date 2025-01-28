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

import Foundation

#if canImport(Network)
import Network
#endif

@objc
public class Room: NSObject, ObservableObject, Loggable {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<RoomDelegate>(label: "RoomDelegate")

    // MARK: - Public

    /// Server assigned id of the Room.
    @objc
    public var sid: Sid? { _state.sid }

    /// Server assigned id of the Room. *async* version of ``Room/sid``.
    @objc
    public func sid() async throws -> Sid {
        try await _sidCompleter.wait()
    }

    @objc
    public var name: String? { _state.name }

    /// Room's metadata.
    @objc
    public var metadata: String? { _state.metadata }

    @objc
    public var serverVersion: String? { _state.serverInfo?.version.nilIfEmpty }

    /// Region code the client is currently connected to.
    @objc
    public var serverRegion: String? { _state.serverInfo?.region.nilIfEmpty }

    /// Region code the client is currently connected to.
    @objc
    public var serverNodeId: String? { _state.serverInfo?.nodeID.nilIfEmpty }

    @objc
    public var remoteParticipants: [Participant.Identity: RemoteParticipant] { _state.remoteParticipants }

    @objc
    public var activeSpeakers: [Participant] { _state.activeSpeakers }

    @objc
    public var creationTime: Date? { _state.creationTime }

    /// If the current room has a participant with `recorder:true` in its JWT grant.
    @objc
    public var isRecording: Bool { _state.isRecording }

    @objc
    public var maxParticipants: Int { _state.maxParticipants }

    @objc
    public var participantCount: Int { _state.numParticipants }

    @objc
    public var publishersCount: Int { _state.numPublishers }

    // expose engine's vars
    @objc
    public var url: String? { _state.url?.absoluteString }

    @objc
    public var token: String? { _state.token }

    /// Current ``ConnectionState`` of the ``Room``.
    @objc
    public var connectionState: ConnectionState { _state.connectionState }

    @objc
    public var disconnectError: LiveKitError? { _state.disconnectError }

    public var connectStopwatch: Stopwatch { _state.connectStopwatch }

    // MARK: - Internal

    public var e2eeManager: E2EEManager?

    @objc
    public lazy var localParticipant: LocalParticipant = .init(room: self)

    let primaryTransportConnectedCompleter = AsyncCompleter<Void>(label: "Primary transport connect", defaultTimeout: .defaultTransportState)
    let publisherTransportConnectedCompleter = AsyncCompleter<Void>(label: "Publisher transport connect", defaultTimeout: .defaultTransportState)

    let signalClient = SignalClient()

    // MARK: - DataChannels

    lazy var subscriberDataChannel = DataChannelPair(delegate: self)
    lazy var publisherDataChannel = DataChannelPair(delegate: self)

    var _blockProcessQueue = DispatchQueue(label: "LiveKitSDK.engine.pendingBlocks",
                                           qos: .default)

    var _queuedBlocks = [ConditionalExecutionEntry]()

    struct State: Equatable {
        // Options
        var connectOptions: ConnectOptions
        var roomOptions: RoomOptions

        var sid: Sid?
        var name: String?
        var metadata: String?

        var remoteParticipants = [Participant.Identity: RemoteParticipant]()
        var activeSpeakers = [Participant]()

        var creationTime: Date?
        var isRecording: Bool = false

        var maxParticipants: Int = 0
        var numParticipants: Int = 0
        var numPublishers: Int = 0

        var serverInfo: Livekit_ServerInfo?

        // Engine
        var url: URL?
        var token: String?
        // preferred reconnect mode which will be used only for next attempt
        var nextReconnectMode: ReconnectMode?
        var isReconnectingWithMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected
        var disconnectError: LiveKitError?
        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false

        var publisher: Transport?
        var subscriber: Transport?
        var isSubscriberPrimary: Bool = false

        // Agents
        var transcriptionReceivedTimes: [String: Date] = [:]

        @discardableResult
        mutating func updateRemoteParticipant(info: Livekit_ParticipantInfo, room: Room) -> RemoteParticipant {
            let identity = Participant.Identity(from: info.identity)
            // Check if RemoteParticipant with same identity exists...
            if let participant = remoteParticipants[identity] { return participant }
            // Create new RemoteParticipant...
            let participant = RemoteParticipant(info: info, room: room, connectionState: connectionState)
            remoteParticipants[identity] = participant
            return participant
        }

        // Find RemoteParticipant by Sid
        func remoteParticipant(forSid sid: Participant.Sid) -> RemoteParticipant? {
            remoteParticipants.values.first(where: { $0.sid == sid })
        }
    }

    let _state: StateSync<State>

    private let _sidCompleter = AsyncCompleter<Sid>(label: "sid", defaultTimeout: .resolveSid)

    // MARK: Objective-C Support

    @objc
    override public convenience init() {
        self.init(delegate: nil,
                  connectOptions: ConnectOptions(),
                  roomOptions: RoomOptions())
    }

    @objc
    public init(delegate: RoomDelegate? = nil,
                connectOptions: ConnectOptions? = nil,
                roomOptions: RoomOptions? = nil)
    {
        DeviceManager.prepare()

        _state = StateSync(State(connectOptions: connectOptions ?? ConnectOptions(),
                                 roomOptions: roomOptions ?? RoomOptions()))

        super.init()
        // log sdk & os versions
        log("sdk: \(LiveKitSDK.version), os: \(String(describing: Utils.os()))(\(Utils.osVersionString())), modelId: \(String(describing: Utils.modelIdentifier() ?? "unknown"))")

        signalClient._delegate.set(delegate: self)

        log()

        if let delegate {
            log("delegate: \(String(describing: delegate))")
            delegates.add(delegate: delegate)
        }

        // listen to app states
        AppStateListener.shared.delegates.add(delegate: self)

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self else { return }

            // sid updated
            if let sid = newState.sid, sid != oldState.sid {
                // Resolve sid
                self._sidCompleter.resume(returning: sid)
            }

            if case .connected = newState.connectionState {
                // metadata updated
                if let metadata = newState.metadata, metadata != oldState.metadata,
                   // don't notify if empty string (first time only)
                   oldState.metadata == nil ? !metadata.isEmpty : true
                {
                    self.delegates.notify(label: { "room.didUpdate metadata: \(metadata)" }) {
                        $0.room?(self, didUpdateMetadata: metadata)
                    }
                }

                // isRecording updated
                if newState.isRecording != oldState.isRecording {
                    self.delegates.notify(label: { "room.didUpdate isRecording: \(newState.isRecording)" }) {
                        $0.room?(self, didUpdateIsRecording: newState.isRecording)
                    }
                }
            }

            if newState.connectionState == .reconnecting, newState.isReconnectingWithMode == nil {
                self.log("reconnectMode should not be .none", .error)
            }

            if (newState.connectionState != oldState.connectionState) || (newState.isReconnectingWithMode != oldState.isReconnectingWithMode) {
                self.log("connectionState: \(oldState.connectionState) -> \(newState.connectionState), reconnectMode: \(String(describing: newState.isReconnectingWithMode))")
            }

            self.engine(self, didMutateState: newState, oldState: oldState)

            // execution control
            self._blockProcessQueue.async { [weak self] in
                guard let self, !self._queuedBlocks.isEmpty else { return }

                self.log("[execution control] processing pending entries (\(self._queuedBlocks.count))...")

                self._queuedBlocks.removeAll { entry in
                    // return and remove this entry if matches remove condition
                    guard !entry.removeCondition(newState, oldState) else { return true }
                    // return but don't remove this entry if doesn't match execute condition
                    guard entry.executeCondition(newState, oldState) else { return false }

                    self.log("[execution control] condition matching block...")
                    entry.block()
                    // remove this entry
                    return true
                }
            }

            // Notify Room when state mutates
            Task.detached { @MainActor in
                self.objectWillChange.send()
            }
        }
    }

    deinit {
        log(nil, .trace)
    }

    @objc
    public func connect(url: String,
                        token: String,
                        connectOptions: ConnectOptions? = nil,
                        roomOptions: RoomOptions? = nil) async throws
    {
        guard let url = URL(string: url), url.isValidForConnect else {
            log("URL parse failed", .error)
            throw LiveKitError(.failedToParseUrl)
        }

        log("Connecting to room...", .info)

        var state = _state.copy()

        // update options if specified
        if let roomOptions, roomOptions != state.roomOptions {
            state = _state.mutate {
                $0.roomOptions = roomOptions
                return $0
            }
        }

        // update options if specified
        if let connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }

        // enable E2EE
        if let e2eeOptions = state.roomOptions.e2eeOptions {
            e2eeManager = E2EEManager(e2eeOptions: e2eeOptions)
            e2eeManager!.setup(room: self)
        }

        await cleanUp()

        try Task.checkCancellation()

        _state.mutate { $0.connectionState = .connecting }

        do {
            try await fullConnectSequence(url, token)

            // Connect sequence successful
            log("Connect sequence completed")

            // Final check if cancelled, don't fire connected events
            try Task.checkCancellation()

            // update internal vars (only if connect succeeded)
            _state.mutate {
                $0.url = url
                $0.token = token
                $0.connectionState = .connected
            }

        } catch {
            await cleanUp(withError: error)
            // Re-throw error
            throw error
        }

        log("Connected to \(String(describing: self))", .info)
    }

    @objc
    public func disconnect() async {
        // Return if already disconnected state
        if case .disconnected = connectionState { return }

        do {
            try await signalClient.sendLeave()
        } catch {
            log("Failed to send leave with error: \(error)")
        }

        await cleanUp()
    }
}

// MARK: - Internal

extension Room {
    // Resets state of Room
    func cleanUp(withError disconnectError: Error? = nil,
                 isFullReconnect: Bool = false) async
    {
        log("withError: \(String(describing: disconnectError)), isFullReconnect: \(isFullReconnect)")

        // Reset completers
        _sidCompleter.reset()
        primaryTransportConnectedCompleter.reset()
        publisherTransportConnectedCompleter.reset()

        await signalClient.cleanUp(withError: disconnectError)
        await cleanUpRTC()
        await cleanUpParticipants(isFullReconnect: isFullReconnect)

        // Cleanup for E2EE
        if let e2eeManager {
            e2eeManager.cleanUp()
        }

        // Reset state
        _state.mutate {
            // if isFullReconnect, keep connection related states
            $0 = isFullReconnect ? State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                url: $0.url,
                token: $0.token,
                nextReconnectMode: $0.nextReconnectMode,
                isReconnectingWithMode: $0.isReconnectingWithMode,
                connectionState: $0.connectionState
            ) : State(
                connectOptions: $0.connectOptions,
                roomOptions: $0.roomOptions,
                connectionState: .disconnected,
                disconnectError: LiveKitError.from(error: disconnectError)
            )
        }
    }
}

// MARK: - Internal

extension Room {
    func cleanUpParticipants(isFullReconnect: Bool = false, notify _notify: Bool = true) async {
        log("notify: \(_notify)")

        // Stop all local & remote tracks
        var allParticipants: [Participant] = Array(_state.remoteParticipants.values)
        if !isFullReconnect {
            allParticipants.append(localParticipant)
        }

        // Clean up Participants concurrently
        await withTaskGroup(of: Void.self) { group in
            for participant in allParticipants {
                group.addTask {
                    await participant.cleanUp(notify: _notify)
                }
            }

            await group.waitForAll()
        }

        _state.mutate {
            $0.remoteParticipants = [:]
        }
    }

    func _onParticipantDidDisconnect(identity: Participant.Identity) async throws {
        guard let participant = _state.mutate({ $0.remoteParticipants.removeValue(forKey: identity) }) else {
            throw LiveKitError(.invalidState, message: "Participant not found for \(identity)")
        }

        await participant.cleanUp(notify: true)
    }
}

// MARK: - Session Migration

extension Room {
    func resetTrackSettings() {
        log("resetting track settings...")

        // create an array of RemoteTrackPublication
        let remoteTrackPublications = _state.remoteParticipants.values.map {
            $0._state.trackPublications.values.compactMap { $0 as? RemoteTrackPublication }
        }.joined()

        // reset track settings for all RemoteTrackPublication
        for publication in remoteTrackPublications {
            publication.resetTrackSettings()
        }
    }
}

// MARK: - AppStateDelegate

extension Room: AppStateDelegate {
    func appDidEnterBackground() {
        guard _state.roomOptions.suspendLocalVideoTracksInBackground else { return }

        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task.detached {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.suspend()
                } catch {
                    self.log("Failed to suspend video track with error: \(error)")
                }
            }
        }
    }

    func appWillEnterForeground() {
        let cameraVideoTracks = localParticipant.localVideoTracks.filter { $0.source == .camera }

        guard !cameraVideoTracks.isEmpty else { return }

        Task.detached {
            for cameraVideoTrack in cameraVideoTracks {
                do {
                    try await cameraVideoTrack.resume()
                } catch {
                    self.log("Failed to resumed video track with error: \(error)")
                }
            }
        }
    }

    func appWillTerminate() {
        // attempt to disconnect if already connected.
        // this is not guranteed since there is no reliable way to detect app termination.
        Task.detached {
            await self.disconnect()
        }
    }

    func appWillSleep() {
        Task.detached {
            await self.disconnect()
        }
    }

    func appDidWake() {}
}

// MARK: - Devices

public extension Room {
    /// Set this to true to bypass initialization of voice processing.
    @available(*, deprecated, renamed: "AudioManager.shared.isVoiceProcessingBypassed")
    @objc
    static var bypassVoiceProcessing: Bool {
        get { AudioManager.shared.isVoiceProcessingBypassed }
        set { AudioManager.shared.isVoiceProcessingBypassed = newValue }
    }
}

// MARK: - DataChannelDelegate

extension Room: DataChannelDelegate {
    func dataChannel(_: DataChannelPair, didReceiveDataPacket dataPacket: Livekit_DataPacket) {
        switch dataPacket.value {
        case let .speaker(update): engine(self, didUpdateSpeakers: update.speakers)
        case let .user(userPacket): engine(self, didReceiveUserPacket: userPacket)
        case let .transcription(packet): room(didReceiveTranscriptionPacket: packet)
        case let .rpcResponse(response): room(didReceiveRpcResponse: response)
        case let .rpcAck(ack): room(didReceiveRpcAck: ack)
        case let .rpcRequest(request): room(didReceiveRpcRequest: request, from: dataPacket.participantIdentity)
        default: return
        }
    }
}

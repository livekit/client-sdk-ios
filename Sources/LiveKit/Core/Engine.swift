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
import Combine

#if canImport(Network)
import Network
#endif

internal class Engine: MulticastDelegate<EngineDelegate> {

    internal let queue = DispatchQueue(label: "LiveKitSDK.engine", qos: .default)

    // MARK: - Public

    public typealias ConditionEvalFunc = (_ newState: State, _ oldState: State?) -> Bool

    public struct State: ReconnectableState, Equatable {
        var connectOptions: ConnectOptions
        var url: String?
        var token: String?
        // preferred reconnect mode which will be used only for next attempt
        var nextPreferredReconnectMode: ReconnectMode?
        var reconnectMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected()
        var connectStopwatch = Stopwatch(label: "connect")
        var hasPublished: Bool = false
        var primaryTransportConnectedCompleter = Completer<Bool>()
        var publisherTransportConnectedCompleter = Completer<Bool>()
    }

    public var _state: StateSync<State>

    public let signalClient = SignalClient()

    public private(set) var publisher: Transport?
    public private(set) var subscriber: Transport?

    // weak ref to Room
    public weak var room: Room?

    // MARK: - Private

    private struct ConditionalExecutionEntry {
        let executeCondition: ConditionEvalFunc
        let removeCondition: ConditionEvalFunc
        let block: () -> Void
    }

    private var subscriberPrimary: Bool = false
    private var primary: Transport? { subscriberPrimary ? subscriber : publisher }

    // MARK: - DataChannels

    private var _subscriberDC = _DataChannelPair(target: .subscriber)
    private var subscriberDC = DataChannelPair(target: .subscriber)
    private var publisherDC = DataChannelPair(target: .publisher)

    private var _blockProcessQueue = DispatchQueue(label: "LiveKitSDK.engine.pendingBlocks",
                                                   qos: .default)

    private var _queuedBlocks = [ConditionalExecutionEntry]()

    init(connectOptions: ConnectOptions) {

        self._state = StateSync(State(connectOptions: connectOptions))
        super.init()

        // log sdk & os versions
        log("sdk: \(LiveKit.version), os: \(String(describing: Utils.os()))(\(Utils.osVersionString())), modelId: \(String(describing: Utils.modelIdentifier() ?? "unknown"))")

        signalClient.add(delegate: self)
        ConnectivityListener.shared.add(delegate: self)

        // trigger events when state mutates
        self._state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            assert(!(newState.connectionState == .reconnecting && newState.reconnectMode == .none), "reconnectMode should not be .none")

            if (newState.connectionState != oldState.connectionState) || (newState.reconnectMode != oldState.reconnectMode) {
                self.log("connectionState: \(oldState.connectionState) -> \(newState.connectionState), reconnectMode: \(String(describing: newState.reconnectMode))")
            }

            self.notify { $0.engine(self, didMutate: newState, oldState: oldState) }

            // execution control
            self._blockProcessQueue.async { [weak self] in
                guard let self = self, !self._queuedBlocks.isEmpty else { return }

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
        }

        subscriberDC.onDataPacket = { [weak self] (dataPacket: Livekit_DataPacket) in

            guard let self = self else { return }

            switch dataPacket.value {
            case .speaker(let update): self.notify { $0.engine(self, didUpdate: update.speakers) }
            case .user(let userPacket): self.notify { $0.engine(self, didReceive: userPacket) }
            default: return
            }
        }
        
        //WIP:
        Task {
            for await dataPacket in _subscriberDC.dataPackets {
                
            }
        }
    }

    deinit {
        log()
    }
    
    //WIP:
    func _connect(url: String, token: String, connectOptions: ConnectOptions? = nil) async throws {
        // update options if specified
        if let connectOptions = connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }
        
        try await _cleanUp()
        self._state.mutate { $0.connectionState = .connecting }
        
        do {
            try await self._fullConnectSequence(url: url, token: token)
        } catch {
            try await _cleanUp(reason: .networkError(error))
            throw error
        }
        
        self.log("Connect sequence completed")

        // update internal vars (only if connect succeeded)
        self._state.mutate {
            $0.url = url
            $0.token = token
            $0.connectionState = .connected
        }
    }
    
    // Connect sequence, resets existing state
    func connect(_ url: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil) -> Promise<Void> {

        // update options if specified
        if let connectOptions = connectOptions, connectOptions != _state.connectOptions {
            _state.mutate { $0.connectOptions = connectOptions }
        }

        return cleanUp().then(on: queue) {
            self._state.mutate { $0.connectionState = .connecting }
        }.then(on: queue) {
            self.fullConnectSequence(url, token)
        }.then(on: queue) {
            // connect sequence successful
            self.log("Connect sequence completed")

            // update internal vars (only if connect succeeded)
            self._state.mutate {
                $0.url = url
                $0.token = token
                $0.connectionState = .connected
            }

        }.catch(on: queue) { error in
            self.cleanUp(reason: .networkError(error))
        }
    }
    
    func _cleanUp(reason: DisconnectReason? = nil, isFullReconnect: Bool = false) async throws {
        guard let room else { throw EngineError.state(message: "Room is nil") }
        await room._cleanUp(reason: reason, isFullReconnect: isFullReconnect)
    }

    // cleanUp (reset) both Room & Engine's state
    @discardableResult
    func cleanUp(reason: DisconnectReason? = nil,
                 isFullReconnect: Bool = false) -> Promise<Void> {

        // this should never happen since Engine is owned by Room
        guard let room = self.room else { return Promise(EngineError.state(message: "Room is nil")) }

        // call Room's cleanUp
        return room.cleanUp(reason: reason, isFullReconnect: isFullReconnect)
    }

    func _cleanupRTC() async {
        await withTaskGroup(of: Void.self, body: { [_subscriberDC] group in
            //TODO: - enable once publisher is ready
//            group.addTask {
//                await _subscriberDC.close()
//            }
//            group.addTask {
//                await _publisherDC.close()
//            }
            
            group.addTask {
                await withUnsafeContinuation { continuation in
                    let closeDataChannelPromises = [
                        self.publisherDC.close(),
                        self.subscriberDC.close()
                    ]
                    
                    closeDataChannelPromises.all(on: self.queue)
                        .then(on: self.queue) {
                            continuation.resume()
                        }
                }
            }
            
            [publisher, subscriber].forEach { transport in
                guard let transport else { return }
                group.addTask {
                    await transport._close()
                }
            }
        })
        
        self.publisher = nil
        self.subscriber = nil
        self._state.mutate { $0.hasPublished = false }
    }
    
    // Resets state of transports
    func cleanUpRTC() -> Promise<Void> {

        Promise<Void>(on: queue) { [weak self] () -> Promise<Void> in

            // close data channels

            guard let self = self else { return Promise(()) }

            let closeDataChannelPromises = [
                self.publisherDC.close(),
                self.subscriberDC.close()
            ]

            return closeDataChannelPromises.all(on: self.queue)

        }.then(on: queue) { [weak self] () -> Promise<Void> in

            // close transports

            guard let self = self else { return Promise(()) }

            let closeTransportPromises = [self.publisher,
                                          self.subscriber]
                .compactMap { $0 }
                .map { $0.close() }

            return closeTransportPromises.all(on: self.queue)

        }.then(on: queue) { _ in
            self.publisher = nil
            self.subscriber = nil
            self._state.mutate { $0.hasPublished = false }
        }
    }
    
    func _publisherShouldNegotiate() async throws {
        log()
        
        guard let publisher else {
            throw EngineError.state(message: "self or publisher is nil")
        }

        _state.mutate { $0.hasPublished = true }

        //v-- this is the offer ... do we need it?
        _ = try await publisher._createAndSendOffer()
        print("negotiated offer...")
    }

    @discardableResult
    func publisherShouldNegotiate() -> Promise<Void> {

        log()

        return Promise<Void>(on: queue) { [weak self] in

            guard let self = self,
                  let publisher = self.publisher else {
                throw EngineError.state(message: "self or publisher is nil")
            }

            self._state.mutate { $0.hasPublished = true }

            publisher.negotiate()
        }
    }

    func send(userPacket: Livekit_UserPacket,
              reliability: Reliability = .reliable) -> Promise<Void> {

        func ensurePublisherConnected () -> Promise<Void> {

            guard subscriberPrimary else {
                return Promise(())
            }

            guard let publisher = publisher else {
                return Promise(EngineError.state(message: "publisher is nil"))
            }

            if !publisher.isConnected, publisher.connectionState != .connecting {
                publisherShouldNegotiate()
            }

            let publisherConnectCompleter = _state.mutate {
                $0.publisherTransportConnectedCompleter.wait(on: queue,
                                                             .defaultTransportState,
                                                             throw: { TransportError.timedOut(message: "publisher didn't connect") })
            }

            return publisherConnectCompleter.then(on: queue) { _ -> Promise<Void> in
                self.log("send data: publisher connected...")
                // wait for publisherDC to open
                return self.publisherDC.openCompleter
            }.timeout(.defaultPublisherDataChannelOpen) {
                // this should not happen since .wait has its own timeouts
                InternalError.state(message: "ensurePublisherConnected() did not complete")
            }
        }

        return ensurePublisherConnected().then(on: queue) { () -> Void in

            // at this point publisher should be .connected and dc should be .open
            assert(self.publisher?.isConnected ?? false, "publisher is not .connected")
            assert(self.publisherDC.isOpen, "publisher data channel is not .open")

            // should return true if successful
            try self.publisherDC.send(userPacket: userPacket, reliability: reliability)
        }
    }
}

// MARK: - Execution control (Internal)

internal extension Engine {

    func executeIfConnected(_ block: @escaping @convention(block) () -> Void) {

        if case .connected = _state.connectionState {
            // execute immediately
            block()
        }
    }

    func execute(when condition: @escaping ConditionEvalFunc,
                 removeWhen removeCondition: @escaping ConditionEvalFunc,
                 _ block: @escaping () -> Void) {

        // already matches condition, execute immediately
        if _state.read({ condition($0, nil) }) {
            log("[execution control] executing immediately...")
            block()
        } else {
            _blockProcessQueue.async { [weak self] in
                guard let self = self else { return }

                // create an entry and enqueue block
                self.log("[execution control] enqueuing entry...")

                let entry = ConditionalExecutionEntry(executeCondition: condition,
                                                      removeCondition: removeCondition,
                                                      block: block)

                self._queuedBlocks.append(entry)
            }
        }
    }
}

// MARK: - Private

private extension Engine {

    func _fullConnectSequence(url: String, token: String) async throws {
        
        // this should never happen since Engine is owned by Room
        guard let room else { throw EngineError.state(message: "Room is nil") }
        
        try await self.signalClient._connect(
            urlString: url,
            token: token,
            connectOptions: _state.connectOptions,
            reconnectMode: _state.reconnectMode,
            adaptiveStream: room._state.options.adaptiveStream
        )
        
        assert(signalClient._state.connectionState == .connected)
        
        // wait for joinResponse
        let joinResponse = try await signalClient._joinResponse()
        
        self._state.mutate { $0.connectStopwatch.split(label: "signal") }

        try await self._configureTransports(joinResponse: joinResponse)
        
        await self.signalClient._resumeResponseQueue()
        
        try await self.primaryTransportConnected()
        
        _state.mutate { $0.connectStopwatch.split(label: "engine") }
        log("\(_state.connectStopwatch)")
    }
    
    // full connect sequence, doesn't update connection state
    func fullConnectSequence(_ url: String,
                             _ token: String) -> Promise<Void> {

        // this should never happen since Engine is owned by Room
        guard let room = self.room else { return Promise(EngineError.state(message: "Room is nil")) }

        return self.signalClient.connect(url,
                                         token,
                                         connectOptions: _state.connectOptions,
                                         reconnectMode: _state.reconnectMode,
                                         adaptiveStream: room._state.options.adaptiveStream)
            .then(on: queue) {
                // wait for joinResponse
                self.signalClient._state.mutate { $0.joinResponseCompleter.wait(on: self.queue,
                                                                                .defaultJoinResponse,
                                                                                throw: { SignalClientError.timedOut(message: "failed to receive join response") }) }
            }.then(on: queue) { _ in
                self._state.mutate { $0.connectStopwatch.split(label: "signal") }
            }.then(on: queue) { jr in
                self.configureTransports(joinResponse: jr)
            }.then(on: queue) {
                self.signalClient.resumeResponseQueue()
            }.then(on: queue) {
                self._state.mutate { $0.primaryTransportConnectedCompleter.wait(on: self.queue,
                                                                                .defaultTransportState,
                                                                                throw: { TransportError.timedOut(message: "primary transport didn't connect") }) }
            }.then(on: queue) { _ -> Void in
                self._state.mutate { $0.connectStopwatch.split(label: "engine") }
                self.log("\(self._state.connectStopwatch)")
            }
    }
    
    //WIP: continue here!
    func primaryTransportConnected() async throws {
        //TODO: timeout
        var primaryState: RTCPeerConnectionState?
        
        if #available(iOS 15.0, *) {
            guard let primaryStates = primary?.connectionStatePublisher.values else {
                throw TransportError.noPrimary(message: "transport is nil")
            }
            
            for await state in primaryStates {
                guard state == .connected else { continue }
                primaryState = state
                break
            }
        } else {
            // Fallback on earlier versions
            fatalError()
        }
        
        guard let _ = primaryState else {
            throw TransportError.noPrimary(message: "no state after waiting for primary connection")
        }
    }

    @discardableResult
    func startReconnect() -> Promise<Void> {

        guard case .connected = _state.connectionState else {
            log("[reconnect] must be called with connected state", .warning)
            return Promise(EngineError.state(message: "Must be called with connected state"))
        }

        guard let url = _state.url, let token = _state.token else {
            log("[reconnect] url or token is nil", . warning)
            return Promise(EngineError.state(message: "url or token is nil"))
        }

        guard subscriber != nil, publisher != nil else {
            log("[reconnect] publisher or subscriber is nil", .warning)
            return Promise(EngineError.state(message: "Publisher or Subscriber is nil"))
        }

        // quick connect sequence, does not update connection state
        func quickReconnectSequence() -> Promise<Void> {

            log("[reconnect] starting QUICK reconnect sequence...")

            // this should never happen since Engine is owned by Room
            guard let room = self.room else { return Promise(EngineError.state(message: "Room is nil")) }

            return self.signalClient.connect(url,
                                             token,
                                             connectOptions: _state.connectOptions,
                                             reconnectMode: _state.reconnectMode,
                                             adaptiveStream: room._state.options.adaptiveStream).then(on: queue) {

                                                self.log("[reconnect] waiting for socket to connect...")
                                                // Wait for primary transport to connect (if not already)
                                                self._state.mutate { $0.primaryTransportConnectedCompleter.wait(on: self.queue,
                                                                                                                .defaultTransportState,
                                                                                                                throw: { TransportError.timedOut(message: "primary transport didn't connect") }) }
                                             }.then(on: queue) { _ in
                                                // send SyncState before offer
                                                self.sendSyncState()
                                             }.then(on: queue) { () -> Promise<Void> in

                                                self.subscriber?.restartingIce = true

                                                // only if published, continue...
                                                guard let publisher = self.publisher, self._state.hasPublished else {
                                                    return Promise(())
                                                }

                                                self.log("[reconnect] waiting for publisher to connect...")

                                                return publisher.createAndSendOffer(iceRestart: true).then(on: self.queue) {
                                                    self._state.mutate { $0.publisherTransportConnectedCompleter.wait(on: self.queue,
                                                                                                                      .defaultTransportState,
                                                                                                                      throw: { TransportError.timedOut(message: "publisher transport didn't connect") }) }.then { _ in }
                                                }

                                             }.then(on: queue) { () -> Promise<Void> in

                                                self.log("[reconnect] send queued requests")
                                                // always check if there are queued requests
                                                return self.signalClient.sendQueuedRequests()
                                             }
        }

        // "full" re-connection sequence
        // as a last resort, try to do a clean re-connection and re-publish existing tracks
        func fullReconnectSequence() -> Promise<Void> {

            log("[reconnect] starting FULL reconnect sequence...")

            return cleanUp(isFullReconnect: true).then(on: queue) { () -> Promise<Void> in

                guard let url = self._state.url,
                      let token = self._state.token else {
                    throw EngineError.state(message: "url or token is nil")
                }

                return self.fullConnectSequence(url, token)
            }
        }

        return retry(on: queue,
                     attempts: _state.connectOptions.reconnectAttempts,
                     delay: _state.connectOptions.reconnectAttemptDelay,
                     condition: { [weak self] triesLeft, _ in
                        guard let self = self else { return false }

                        // not reconnecting state anymore
                        guard case .reconnecting = self._state.connectionState else { return false }

                        // full reconnect failed, give up
                        guard .full != self._state.reconnectMode else { return false }

                        self.log("[reconnect] retry in \(_state.connectOptions.reconnectAttemptDelay) seconds, \(triesLeft) tries left...")

                        // try full reconnect for the final attempt
                        if triesLeft == 1,
                           self._state.nextPreferredReconnectMode == nil {
                            self._state.mutate {  $0.nextPreferredReconnectMode = .full }
                        }

                        return true
                     }, _: { [weak self] in
                        // this should never happen
                        guard let self = self else { return Promise(EngineError.state(message: "self is nil")) }

                        let mode: ReconnectMode = self._state.mutate {

                            let mode: ReconnectMode = ($0.nextPreferredReconnectMode == .full || $0.reconnectMode == .full) ? .full : .quick
                            $0.connectionState = .reconnecting
                            $0.reconnectMode = mode
                            $0.nextPreferredReconnectMode = nil

                            return mode
                        }

                        return mode == .full ? fullReconnectSequence() : quickReconnectSequence()
                     })
            .then(on: queue) {
                // re-connect sequence successful
                self.log("[reconnect] sequence completed")
                self._state.mutate { $0.connectionState = .connected }
            }.catch(on: queue) { error in
                self.log("[reconnect] sequence failed with error: \(error)")
                // finally disconnect if all attempts fail
                self.cleanUp(reason: .networkError(error))
            }
    }

}

// MARK: - Session Migration

internal extension Engine {

    func sendSyncState() -> Promise<Void> {

        guard let room = room else {
            // this should never happen
            log("Room is nil", .error)
            return Promise(())
        }

        guard let subscriber = subscriber,
              let previousAnswer = subscriber.localDescription else {
            // No-op
            return Promise(())
        }

        let previousOffer = subscriber.remoteDescription

        // 1. autosubscribe on, so subscribed tracks = all tracks - unsub tracks,
        //    in this case, we send unsub tracks, so server add all tracks to this
        //    subscribe pc and unsub special tracks from it.
        // 2. autosubscribe off, we send subscribed tracks.

        let autoSubscribe = _state.connectOptions.autoSubscribe
        let trackSids = room._state.remoteParticipants.values.flatMap { participant in
            participant._state.tracks.values
                .filter { $0.subscribed != autoSubscribe }
                .map { $0.sid }
        }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids
            $0.participantTracks = []
            $0.subscribe = !autoSubscribe
        }

        return signalClient.sendSyncState(answer: previousAnswer.toPBType(),
                                          offer: previousOffer?.toPBType(),
                                          subscription: subscription,
                                          publishTracks: room._state.localParticipant?.publishedTracksInfo(),
                                          dataChannels: publisherDC.infos())
    }
}

// MARK: - SignalClientDelegate

extension Engine: SignalClientDelegate {

    func signalClient(_ signalClient: SignalClient, didMutate state: SignalClient.State, oldState: SignalClient.State) -> Bool {

        // connectionState did update
        if state.connectionState != oldState.connectionState,
           // did disconnect
           case .disconnected(let reason) = state.connectionState,
           // only attempt re-connect if disconnected(reason: network)
           case .networkError = reason,
           // engine is currently connected state
           case .connected = _state.connectionState {
            log("[reconnect] starting, reason: socket network error. connectionState: \(_state.connectionState)")
            startReconnect()
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceive iceCandidate: RTCIceCandidate, target: Livekit_SignalTarget) -> Bool {

        guard let transport = target == .subscriber ? subscriber : publisher else {
            log("failed to add ice candidate, transport is nil for target: \(target)", .error)
            return true
        }

        transport.addIceCandidate(iceCandidate).catch(on: queue) { error in
            self.log("failed to add ice candidate for transport: \(transport), error: \(error)", .error)
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceiveAnswer answer: RTCSessionDescription) -> Bool {

        guard let publisher = self.publisher else {
            log("publisher is nil", .error)
            return true
        }

        publisher.setRemoteDescription(answer).catch(on: queue) { error in
            self.log("failed to set remote description, error: \(error)", .error)
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didReceiveOffer offer: RTCSessionDescription) -> Bool {

        log("received offer, creating & sending answer...")

        guard let subscriber = self.subscriber else {
            log("failed to send answer, subscriber is nil", .error)
            return true
        }

        subscriber.setRemoteDescription(offer).then(on: queue) {
            subscriber.createAnswer()
        }.then(on: queue) { answer in
            subscriber.setLocalDescription(answer)
        }.then(on: queue) { answer in
            self.signalClient.sendAnswer(answer: answer)
        }.then(on: queue) {
            self.log("answer sent to signal")
        }.catch(on: queue) { error in
            self.log("failed to send answer, error: \(error)", .error)
        }

        return true
    }

    func signalClient(_ signalClient: SignalClient, didUpdate token: String) -> Bool {

        // update token
        _state.mutate { $0.token = token }

        return true
    }
}

// MARK: - TransportDelegate

extension Engine: TransportDelegate {

    func transport(_ transport: Transport, didGenerate stats: [TrackStats], target: Livekit_SignalTarget) {
        // relay to Room
        notify { $0.engine(self, didGenerate: stats, target: target) }
    }

    func transport(_ transport: Transport, didUpdate pcState: RTCPeerConnectionState) {
        log("target: \(transport.target), state: \(pcState)")
        
        // primary connected
        if transport.primary {
            _state.mutate { $0.primaryTransportConnectedCompleter.set(value: .connected == pcState ? true : nil) }
        }

        // publisher connected
        if case .publisher = transport.target {
            _state.mutate { $0.publisherTransportConnectedCompleter.set(value: .connected == pcState ? true : nil) }
        }

        if _state.connectionState.isConnected {
            // Attempt re-connect if primary or publisher transport failed
            if (transport.primary || (_state.hasPublished && transport.target == .publisher)) && [.disconnected, .failed].contains(pcState) {
                log("[reconnect] starting, reason: transport disconnected or failed")
                startReconnect()
            }
        }
    }
    
    private func _configureTransports(joinResponse: Livekit_JoinResponse) async throws {
        log("configuring transports...")

        // this should never happen since Engine is owned by Room
        guard let room else { throw EngineError.state(message: "Room is nil") }

        guard subscriber == nil, publisher == nil else {
            log("transports already configured")
            return
        }

        // protocol v3
        subscriberPrimary = joinResponse.subscriberPrimary
        log("subscriberPrimary: \(joinResponse.subscriberPrimary)")

        // Make a copy, instead of modifying the user-supplied RTCConfiguration object.
        let rtcConfiguration = RTCConfiguration(copy: _state.connectOptions.rtcConfiguration)

        if rtcConfiguration.iceServers.isEmpty {
            // Set iceServers provided by the server
            rtcConfiguration.iceServers = joinResponse.iceServers.map { $0.toRTCType() }
        }

        if joinResponse.clientConfiguration.forceRelay == .enabled {
            rtcConfiguration.iceTransportPolicy = .relay
        }

        let subscriber = try Transport(config: rtcConfiguration,
                                       target: .subscriber,
                                       primary: self.subscriberPrimary,
                                       delegate: self,
                                       reportStats: room._state.options.reportStats)

        let publisher = try Transport(config: rtcConfiguration,
                                      target: .publisher,
                                      primary: !self.subscriberPrimary,
                                      delegate: self,
                                      reportStats: room._state.options.reportStats)

        // data over pub channel for backwards compatibility

        let publisherReliableDC = publisher.dataChannel(for: RTCDataChannel.labels.reliable,
                                                        configuration: Engine.createDataChannelConfiguration())

        let publisherLossyDC = publisher.dataChannel(for: RTCDataChannel.labels.lossy,
                                                     configuration: Engine.createDataChannelConfiguration(maxRetransmits: 0))

        self.publisherDC.set(reliable: publisherReliableDC, lossy: publisherLossyDC)

        self.log("dataChannel.\(String(describing: publisherReliableDC?.label)) : \(String(describing: publisherReliableDC?.channelId))")
        self.log("dataChannel.\(String(describing: publisherLossyDC?.label)) : \(String(describing: publisherLossyDC?.channelId))")
        
        if !self.subscriberPrimary {
            // lazy negotiation for protocol v3+
            try await self._publisherShouldNegotiate()
        }
                            
        self.subscriber = subscriber
        self.publisher = publisher
    }

    private func configureTransports(joinResponse: Livekit_JoinResponse) -> Promise<Void> {

        Promise<Void>(on: queue) { () -> Void in

            self.log("configuring transports...")

            // this should never happen since Engine is owned by Room
            guard let room = self.room else { throw EngineError.state(message: "Room is nil") }

            guard self.subscriber == nil, self.publisher == nil else {
                self.log("transports already configured")
                return
            }

            // protocol v3
            self.subscriberPrimary = joinResponse.subscriberPrimary
            self.log("subscriberPrimary: \(joinResponse.subscriberPrimary)")

            // Make a copy, instead of modifying the user-supplied RTCConfiguration object.
            let rtcConfiguration = RTCConfiguration(copy: self._state.connectOptions.rtcConfiguration)

            if rtcConfiguration.iceServers.isEmpty {
                // Set iceServers provided by the server
                rtcConfiguration.iceServers = joinResponse.iceServers.map { $0.toRTCType() }
            }

            if joinResponse.clientConfiguration.forceRelay == .enabled {
                rtcConfiguration.iceTransportPolicy = .relay
            }

            let subscriber = try Transport(config: rtcConfiguration,
                                           target: .subscriber,
                                           primary: self.subscriberPrimary,
                                           delegate: self,
                                           reportStats: room._state.options.reportStats)

            let publisher = try Transport(config: rtcConfiguration,
                                          target: .publisher,
                                          primary: !self.subscriberPrimary,
                                          delegate: self,
                                          reportStats: room._state.options.reportStats)

            publisher.onOffer = { offer in
                self.log("publisher onOffer \(offer.sdp)")
                return self.signalClient.sendOffer(offer: offer)
            }

            // data over pub channel for backwards compatibility

            let publisherReliableDC = publisher.dataChannel(for: RTCDataChannel.labels.reliable,
                                                            configuration: Engine.createDataChannelConfiguration())

            let publisherLossyDC = publisher.dataChannel(for: RTCDataChannel.labels.lossy,
                                                         configuration: Engine.createDataChannelConfiguration(maxRetransmits: 0))

            self.publisherDC.set(reliable: publisherReliableDC)
            self.publisherDC.set(lossy: publisherLossyDC)

            self.log("dataChannel.\(String(describing: publisherReliableDC?.label)) : \(String(describing: publisherReliableDC?.channelId))")
            self.log("dataChannel.\(String(describing: publisherLossyDC?.label)) : \(String(describing: publisherLossyDC?.channelId))")

            if !self.subscriberPrimary {
                // lazy negotiation for protocol v3+
                self.publisherShouldNegotiate()
            }

            self.subscriber = subscriber
            self.publisher = publisher
        }
    }

    func transport(_ transport: Transport, didGenerate iceCandidate: RTCIceCandidate) {
        log("didGenerate iceCandidate")
        signalClient.sendCandidate(candidate: iceCandidate,
                                   target: transport.target).catch(on: queue) { error in
                                    self.log("Failed to send candidate, error: \(error)", .error)
                                   }
    }

    func transport(_ transport: Transport, didAdd track: RTCMediaStreamTrack, streams: [RTCMediaStream]) {
        log("did add track")
        if transport.target == .subscriber {

            // execute block when connected
            execute(when: { state, _ in state.connectionState == .connected },
                    // always remove this block when disconnected
                    removeWhen: { state, _ in state.connectionState == .disconnected() }) { [weak self] in
                guard let self = self else { return }
                self.notify { $0.engine(self, didAdd: track, streams: streams) }
            }
        }
    }

    func transport(_ transport: Transport, didRemove track: RTCMediaStreamTrack) {
        if transport.target == .subscriber {
            notify { $0.engine(self, didRemove: track) }
        }
    }

    func transport(_ transport: Transport, didOpen dataChannel: RTCDataChannel) {

        log("Server opened data channel \(dataChannel.label)(\(dataChannel.readyState))")

        if subscriberPrimary, transport.target == .subscriber {

            switch dataChannel.label {
            case RTCDataChannel.labels.reliable: subscriberDC.set(reliable: dataChannel)
            case RTCDataChannel.labels.lossy: subscriberDC.set(lossy: dataChannel)
            default: log("Unknown data channel label \(dataChannel.label)", .warning)
            }
        }
    }

    func transportShouldNegotiate(_ transport: Transport) {}
}

// MARK: - ConnectivityListenerDelegate

extension Engine: ConnectivityListenerDelegate {

    func connectivityListener(_: ConnectivityListener, didSwitch path: NWPath) {
        log("didSwitch path: \(path)")

        // network has been switched, e.g. wifi <-> cellular
        if case .connected = _state.connectionState {
            log("[reconnect] starting, reason: network path changed")
            startReconnect()
        }
    }
}

// MARK: Engine - Factory methods

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

    // global properties are already lazy

    static private let encoderFactory: RTCVideoEncoderFactory = {
        let encoderFactory = VideoEncoderFactory()
        #if LK_USING_CUSTOM_WEBRTC_BUILD
        return VideoEncoderFactorySimulcast(primary: encoderFactory,
                                            fallback: encoderFactory)

        #else
        return encoderFactory
        #endif
    }()

    static private let decoderFactory = VideoDecoderFactory()

    static let peerConnectionFactory: RTCPeerConnectionFactory = {

        logger.log("Initializing SSL...", type: Engine.self)

        RTCInitializeSSL()

        logger.log("Initializing Field trials...", type: Engine.self)

        let fieldTrials = [kRTCFieldTrialUseNWPathMonitor: kRTCFieldTrialEnabledValue]
        RTCInitFieldTrialDictionary(fieldTrials)

        logger.log("Initializing PeerConnectionFactory...", type: Engine.self)

        #if LK_USING_CUSTOM_WEBRTC_BUILD
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
        #if LK_USING_CUSTOM_WEBRTC_BUILD
        DispatchQueue.webRTC.sync { peerConnectionFactory.videoSource() }
        #else
        DispatchQueue.webRTC.sync { peerConnectionFactory.videoSource(forScreenCast: forScreenShare) }
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

        return result
    }
}

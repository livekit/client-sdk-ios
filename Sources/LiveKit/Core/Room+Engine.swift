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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

// Room+Engine
extension Room {
    // MARK: - Public

    typealias ConditionEvalFunc = (_ newState: State, _ oldState: State?) -> Bool

    // MARK: - Private

    struct ConditionalExecutionEntry {
        let executeCondition: ConditionEvalFunc
        let removeCondition: ConditionEvalFunc
        let block: () -> Void
    }

    // Resets state of transports
    func cleanUpRTC() async {
        // Close data channels
        publisherDataChannel.reset()
        subscriberDataChannel.reset()

        let (subscriber, publisher) = _state.read { ($0.subscriber, $0.publisher) }

        // Close transports
        await publisher?.close()
        await subscriber?.close()

        // Reset publish state
        _state.mutate {
            $0.subscriber = nil
            $0.publisher = nil
            $0.hasPublished = false
        }
    }

    func publisherShouldNegotiate() async throws {
        log()

        let publisher = try requirePublisher()
        await publisher.negotiate()
        _state.mutate { $0.hasPublished = true }
    }

    func send(userPacket: Livekit_UserPacket, kind: Livekit_DataPacket.Kind) async throws {
        try await send(dataPacket: .with {
            $0.user = userPacket
            $0.kind = kind
        })
    }

    func send(dataPacket packet: Livekit_DataPacket) async throws {
        func ensurePublisherConnected() async throws {
            guard _state.isSubscriberPrimary else { return }

            let publisher = try requirePublisher()

            let connectionState = await publisher.connectionState
            if connectionState != .connected, connectionState != .connecting {
                try await publisherShouldNegotiate()
            }

            try await publisherTransportConnectedCompleter.wait(timeout: _state.connectOptions.publisherTransportConnectTimeout)
            try await publisherDataChannel.openCompleter.wait()
        }

        try await ensurePublisherConnected()

        // At this point publisher should be .connected and dc should be .open
        if await !(_state.publisher?.isConnected ?? false) {
            log("publisher is not .connected", .error)
        }

        let dataChannelIsOpen = publisherDataChannel.isOpen
        if !dataChannelIsOpen {
            log("publisher data channel is not .open", .error)
        }

        // Should return true if successful
        try publisherDataChannel.send(dataPacket: packet)
    }
}

// MARK: - Internal

extension Room {
    func configureTransports(connectResponse: SignalClient.ConnectResponse) async throws {
        func makeConfiguration() -> LKRTCConfiguration {
            let connectOptions = _state.connectOptions

            // Make a copy, instead of modifying the user-supplied RTCConfiguration object.
            let rtcConfiguration = LKRTCConfiguration.liveKitDefault()

            // Set iceServers provided by the server
            rtcConfiguration.iceServers = connectResponse.rtcIceServers

            if !connectOptions.iceServers.isEmpty {
                // Override with user provided iceServers
                rtcConfiguration.iceServers = connectOptions.iceServers.map { $0.toRTCType() }
            }

            if connectResponse.clientConfiguration.forceRelay == .enabled {
                rtcConfiguration.iceTransportPolicy = .relay
            } else {
                rtcConfiguration.iceTransportPolicy = connectOptions.iceTransportPolicy.toRTCType()
            }

            return rtcConfiguration
        }

        let rtcConfiguration = makeConfiguration()

        if case let .join(joinResponse) = connectResponse {
            log("Configuring transports with JOIN response...")

            guard _state.subscriber == nil, _state.publisher == nil else {
                log("Transports are already configured")
                return
            }

            // protocol v3
            let isSubscriberPrimary = joinResponse.subscriberPrimary
            log("subscriberPrimary: \(joinResponse.subscriberPrimary)")

            let subscriber = try Transport(config: rtcConfiguration,
                                           target: .subscriber,
                                           primary: isSubscriberPrimary,
                                           delegate: self)

            let publisher = try Transport(config: rtcConfiguration,
                                          target: .publisher,
                                          primary: !isSubscriberPrimary,
                                          delegate: self)

            await publisher.set { [weak self] offer in
                guard let self else { return }
                self.log("Publisher onOffer \(offer.sdp)")
                try await self.signalClient.send(offer: offer)
            }

            // data over pub channel for backwards compatibility

            let reliableDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.labels.reliable,
                                                                  configuration: RTC.createDataChannelConfiguration())

            let lossyDataChannel = await publisher.dataChannel(for: LKRTCDataChannel.labels.lossy,
                                                               configuration: RTC.createDataChannelConfiguration(maxRetransmits: 0))

            publisherDataChannel.set(reliable: reliableDataChannel)
            publisherDataChannel.set(lossy: lossyDataChannel)

            log("dataChannel.\(String(describing: reliableDataChannel?.label)) : \(String(describing: reliableDataChannel?.channelId))")
            log("dataChannel.\(String(describing: lossyDataChannel?.label)) : \(String(describing: lossyDataChannel?.channelId))")

            _state.mutate {
                $0.subscriber = subscriber
                $0.publisher = publisher
                $0.isSubscriberPrimary = isSubscriberPrimary
            }

            if !isSubscriberPrimary {
                // lazy negotiation for protocol v3+
                try await publisherShouldNegotiate()
            }

        } else if case .reconnect = connectResponse {
            log("[Connect] Configuring transports with RECONNECT response...")
            let (subscriber, publisher) = _state.read { ($0.subscriber, $0.publisher) }
            try await subscriber?.set(configuration: rtcConfiguration)
            try await publisher?.set(configuration: rtcConfiguration)
        }
    }
}

// MARK: - Execution control (Internal)

extension Room {
    func execute(when condition: @escaping ConditionEvalFunc,
                 removeWhen removeCondition: @escaping ConditionEvalFunc,
                 _ block: @escaping () -> Void)
    {
        // already matches condition, execute immediately
        if _state.read({ condition($0, nil) }) {
            log("[execution control] executing immediately...")
            block()
        } else {
            _blockProcessQueue.async { [weak self] in
                guard let self else { return }

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

// MARK: - Connection / Reconnection logic

public enum StartReconnectReason: Sendable {
    case websocket
    case transport
    case networkSwitch
    case debug
}

// Room+ConnectSequences
extension Room {
    // full connect sequence, doesn't update connection state
    func fullConnectSequence(_ url: URL, _ token: String) async throws {
        let connectResponse = try await signalClient.connect(url,
                                                             token,
                                                             connectOptions: _state.connectOptions,
                                                             reconnectMode: _state.isReconnectingWithMode,
                                                             adaptiveStream: _state.roomOptions.adaptiveStream)
        // Check cancellation after WebSocket connected
        try Task.checkCancellation()

        _state.mutate { $0.connectStopwatch.split(label: "signal") }
        try await configureTransports(connectResponse: connectResponse)
        // Check cancellation after configuring transports
        try Task.checkCancellation()

        // Resume after configuring transports...
        await signalClient.resumeQueues()

        // Wait for transport...
        try await primaryTransportConnectedCompleter.wait(timeout: _state.connectOptions.primaryTransportConnectTimeout)
        try Task.checkCancellation()

        _state.mutate { $0.connectStopwatch.split(label: "engine") }
        log("\(_state.connectStopwatch)")
    }

    func startReconnect(reason: StartReconnectReason, nextReconnectMode: ReconnectMode? = nil) async throws {
        log("[Connect] Starting, reason: \(reason)")

        guard case .connected = _state.connectionState else {
            log("[Connect] Must be called with connected state", .error)
            throw LiveKitError(.invalidState)
        }

        guard let url = _state.providedUrl, let token = _state.token else {
            log("[Connect] Url or token is nil", .error)
            throw LiveKitError(.invalidState)
        }

        guard _state.subscriber != nil, _state.publisher != nil else {
            log("[Connect] Publisher or subscriber is nil", .error)
            throw LiveKitError(.invalidState)
        }

        guard _state.isReconnectingWithMode == nil else {
            log("[Connect] Reconnect already in progress...", .warning)
            throw LiveKitError(.invalidState)
        }

        _state.mutate {
            // Mark as Re-connecting internally
            $0.isReconnectingWithMode = .quick
            $0.nextReconnectMode = nextReconnectMode
        }

        // quick connect sequence, does not update connection state
        @Sendable func quickReconnectSequence() async throws {
            log("[Connect] Starting .quick reconnect sequence...")

            let connectResponse = try await signalClient.connect(url,
                                                                 token,
                                                                 connectOptions: _state.connectOptions,
                                                                 reconnectMode: _state.isReconnectingWithMode,
                                                                 participantSid: localParticipant.sid,
                                                                 adaptiveStream: _state.roomOptions.adaptiveStream)
            try Task.checkCancellation()

            // Update configuration
            try await configureTransports(connectResponse: connectResponse)
            try Task.checkCancellation()

            // Resume after configuring transports...
            await signalClient.resumeQueues()

            log("[Connect] Waiting for subscriber to connect...")
            // Wait for primary transport to connect (if not already)
            try await primaryTransportConnectedCompleter.wait(timeout: _state.connectOptions.primaryTransportConnectTimeout)
            try Task.checkCancellation()

            // send SyncState before offer
            try await sendSyncState()

            await _state.subscriber?.setIsRestartingIce()

            if let publisher = _state.publisher, _state.hasPublished {
                // Only if published, wait for publisher to connect...
                log("[Connect] Waiting for publisher to connect...")
                try await publisher.createAndSendOffer(iceRestart: true)
                try await publisherTransportConnectedCompleter.wait(timeout: _state.connectOptions.publisherTransportConnectTimeout)
            }
        }

        // "full" re-connection sequence
        // as a last resort, try to do a clean re-connection and re-publish existing tracks
        @Sendable func fullReconnectSequence() async throws {
            log("[Connect] starting .full reconnect sequence...")

            _state.mutate {
                // Mark as Re-connecting
                $0.connectionState = .reconnecting
            }

            let (providedUrl, connectedUrl, token) = _state.read { ($0.providedUrl, $0.connectedUrl, $0.token) }

            guard let providedUrl, let connectedUrl, let token else {
                log("[Connect] Url or token is nil")
                throw LiveKitError(.invalidState)
            }

            var nextUrl = connectedUrl
            var nextRegion: RegionInfo?

            while true {
                do {
                    // Prepare for next connect attempt.
                    await cleanUp(isFullReconnect: true)

                    try await fullConnectSequence(nextUrl, token)
                    _state.mutate { $0.connectedUrl = nextUrl }
                    // Exit loop on successful connection
                    break
                } catch {
                    // Re-throw if is cancel.
                    if error is CancellationError {
                        throw error
                    }

                    if let region = nextRegion {
                        nextRegion = nil
                        log("Connect failed with region: \(region)")
                        regionManager(addFailedRegion: region)
                    }

                    try Task.checkCancellation()

                    if providedUrl.isCloud {
                        let region = try await regionManagerResolveBest()
                        nextUrl = region.url
                        nextRegion = region
                    }
                }
            }
        }

        do {
            try await Task.retrying(totalAttempts: _state.connectOptions.reconnectAttempts,
                                    retryDelay: _state.connectOptions.reconnectAttemptDelay)
            { currentAttempt, totalAttempts in

                // Not reconnecting state anymore
                guard let currentMode = self._state.isReconnectingWithMode else {
                    self.log("[Connect] Not in reconnect state anymore, exiting retry cycle.")
                    return
                }

                // Full reconnect failed, give up
                guard currentMode != .full else { return }

                self.log("[Connect] Retry in \(self._state.connectOptions.reconnectAttemptDelay) seconds, \(currentAttempt)/\(totalAttempts) tries left.")

                // Try full reconnect for the final attempt
                if totalAttempts == currentAttempt, self._state.nextReconnectMode == nil {
                    self._state.mutate { $0.nextReconnectMode = .full }
                }

                let mode: ReconnectMode = self._state.mutate {
                    let mode: ReconnectMode = ($0.nextReconnectMode == .full || $0.isReconnectingWithMode == .full) ? .full : .quick
                    $0.isReconnectingWithMode = mode
                    $0.nextReconnectMode = nil
                    return mode
                }

                do {
                    if case .quick = mode {
                        try await quickReconnectSequence()
                    } else if case .full = mode {
                        try await fullReconnectSequence()
                    }
                } catch {
                    self.log("[Connect] Reconnect mode: \(mode) failed with error: \(error)", .error)
                    // Re-throw
                    throw error
                }
            }.value

            // Re-connect sequence successful
            log("[Connect] Sequence completed")
            _state.mutate {
                $0.connectionState = .connected
                $0.isReconnectingWithMode = nil
                $0.nextReconnectMode = nil
            }
        } catch {
            log("[Connect] Sequence failed with error: \(error)")

            if !Task.isCancelled {
                // Finally disconnect if all attempts fail
                await cleanUp(withError: error)
            }
        }
    }
}

// MARK: - Session Migration

extension Room {
    func sendSyncState() async throws {
        guard let subscriber = _state.subscriber else {
            log("Subscriber is nil", .error)
            return
        }

        let previousAnswer = await subscriber.localDescription
        let previousOffer = await subscriber.remoteDescription

        // 1. autosubscribe on, so subscribed tracks = all tracks - unsub tracks,
        //    in this case, we send unsub tracks, so server add all tracks to this
        //    subscribe pc and unsub special tracks from it.
        // 2. autosubscribe off, we send subscribed tracks.

        let autoSubscribe = _state.connectOptions.autoSubscribe
        let trackSids = _state.remoteParticipants.values.flatMap { participant in
            participant._state.trackPublications.values
                .filter { $0.isSubscribed != autoSubscribe }
                .map(\.sid)
        }

        log("trackSids: \(trackSids)")

        let subscription = Livekit_UpdateSubscription.with {
            $0.trackSids = trackSids.map(\.stringValue)
            $0.participantTracks = []
            $0.subscribe = !autoSubscribe
        }

        try await signalClient.sendSyncState(answer: previousAnswer?.toPBType(),
                                             offer: previousOffer?.toPBType(),
                                             subscription: subscription,
                                             publishTracks: localParticipant.publishedTracksInfo(),
                                             dataChannels: publisherDataChannel.infos())
    }
}

// MARK: - Private helpers

extension Room {
    func requirePublisher() throws -> Transport {
        guard let publisher = _state.publisher else {
            log("Publisher is nil", .error)
            throw LiveKitError(.invalidState, message: "Publisher is nil")
        }

        return publisher
    }
}

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
import Promises
import WebRTC
import Collections

internal class SignalClient: MulticastDelegate<SignalClientDelegate> {

    // queue to store requests while reconnecting
    private var requestQueue = [Livekit_SignalRequest]()
    private var responseQueue = [Livekit_SignalResponse]()

    private let requestDispatchQueue = DispatchQueue(label: "LiveKitSDK.signalClient.requestQueue", qos: .default)
    private let responseDispatchQueue = DispatchQueue(label: "LiveKitSDK.signalClient.responseQueue", qos: .default)

    private(set) var connectionState: ConnectionState = .disconnected(reason: .sdk) {
        didSet {
            guard oldValue != connectionState else { return }
            log("\(oldValue) -> \(self.connectionState)")
            notify { $0.signalClient(self, didUpdate: self.connectionState, oldValue: oldValue) }
        }
    }

    enum QueueState {
        case resumed
        case suspended
    }

    private(set) var responseQueueState: QueueState = .resumed

    private var webSocket: WebSocket?
    private var latestJoinResponse: Livekit_JoinResponse?

    deinit {
        log()
    }

    func connect(_ url: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 connectMode: ConnectMode = .normal) -> Promise<Void> {

        cleanUp(reason: .sdk)

        return Utils.buildUrl(url,
                              token,
                              connectOptions: connectOptions,
                              connectMode: connectMode)
            .catch(on: .sdk) { error in
                self.log("Failed to parse rtc url", .error)
            }
            .then(on: .sdk) { url -> Promise<WebSocket> in
                self.log("Connecting with url: \(url)")
                self.connectionState = .connecting(connectMode)
                return WebSocket.connect(url: url,
                                         onMessage: self.onWebSocketMessage,
                                         onDisconnect: { reason in
                                            self.webSocket = nil
                                            self.cleanUp(reason: reason)
                                         })
            }.then(on: .sdk) { (webSocket: WebSocket) -> Void in
                self.webSocket = webSocket
                self.connectionState = .connected(connectMode)
            }.recover(on: .sdk) { error -> Promise<Void> in
                // Skip validation if reconnect mode
                if case .reconnect = connectMode { throw error }
                // Catch first, then throw again after getting validation response
                // Re-build url with validate mode
                return Utils.buildUrl(url,
                                      token,
                                      connectOptions: connectOptions,
                                      connectMode: connectMode,
                                      validate: true
                ).then(on: .sdk) { url -> Promise<Data> in
                    self.log("Validating with url: \(url)")
                    return HTTP().get(url: url)
                }.then(on: .sdk) { data in
                    guard let string = String(data: data, encoding: .utf8) else {
                        throw SignalClientError.connect(message: "Failed to decode string")
                    }
                    self.log("validate response: \(string)")
                    // re-throw with validation response
                    throw SignalClientError.connect(message: string)
                }
            }.catch(on: .sdk) { _ in
                self.cleanUp(reason: .network())
            }
    }

    func cleanUp(reason: DisconnectReason) {
        log("reason: \(reason)")

        connectionState = .disconnected(reason: reason)

        if let socket = webSocket {
            socket.cleanUp(reason: reason)
            socket.onMessage = nil
            socket.onDisconnect = nil
            self.webSocket = nil
        }

        latestJoinResponse = nil

        requestDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.requestQueue.removeAll()
        }

        responseDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.responseQueue.removeAll()
            self.responseQueueState = .resumed
        }
    }
}

// MARK: - Private

private extension SignalClient {

    // send request or enqueue while reconnecting
    func sendRequest(_ request: Livekit_SignalRequest, enqueueIfReconnecting: Bool = true) -> Promise<Void> {

        Promise<Void>(on: requestDispatchQueue) { () -> Void in

            guard !(self.connectionState.isReconnecting && request.canEnqueue() && enqueueIfReconnecting) else {
                self.log("Queuing request while reconnecting, request: \(request)")
                self.requestQueue.append(request)
                // success
                return
            }

            guard case .connected = self.connectionState else {
                self.log("Not connected", .error)
                throw SignalClientError.state(message: "Not connected")
            }

            // this shouldn't happen
            guard let webSocket = self.webSocket else {
                self.log("WebSocket is nil", .error)
                throw SignalClientError.state(message: "WebSocket is nil")
            }

            guard let data = try? request.serializedData() else {
                self.log("Could not serialize data", .error)
                throw InternalError.convert(message: "Could not serialize data")
            }

            // resolve promise in this queue
            try awaitPromise(webSocket.send(data: data))
        }
    }

    func onWebSocketMessage(message: URLSessionWebSocketTask.Message) {

        var response: Livekit_SignalResponse?

        if case .data(let data) = message {
            response = try? Livekit_SignalResponse(contiguousBytes: data)
        } else if case .string(let string) = message {
            response = try? Livekit_SignalResponse(jsonString: string)
        }

        guard let response = response else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        responseDispatchQueue.async {
            if case .suspended = self.responseQueueState {
                self.log("Enqueueing response: \(response)")
                self.responseQueue.append(response)
            } else {
                self.onSignalResponse(response)
            }
        }
    }

    func onSignalResponse(_ response: Livekit_SignalResponse) {

        guard case .connected = connectionState else {
            log("Not connected", .warning)
            return
        }

        guard let message = response.message else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        switch message {
        case .join(let joinResponse) :
            responseQueueState = .suspended
            latestJoinResponse = joinResponse
            notify { $0.signalClient(self, didReceive: joinResponse) }

        case .answer(let sd):
            notify { $0.signalClient(self, didReceiveAnswer: sd.toRTCType()) }

        case .offer(let sd):
            notify { $0.signalClient(self, didReceiveOffer: sd.toRTCType()) }

        case .trickle(let trickle):
            guard let rtcCandidate = try? Engine.createIceCandidate(fromJsonString: trickle.candidateInit) else {
                return
            }

            notify { $0.signalClient(self, didReceive: rtcCandidate, target: trickle.target) }

        case .update(let update):
            notify { $0.signalClient(self, didUpdate: update.participants) }

        case .roomUpdate(let update):
            notify { $0.signalClient(self, didUpdate: update.room) }

        case .trackPublished(let trackPublished):
            notify { $0.signalClient(self, didPublish: trackPublished) }

        case .speakersChanged(let speakers):
            notify { $0.signalClient(self, didUpdate: speakers.speakers) }

        case .connectionQuality(let quality):
            notify { $0.signalClient(self, didUpdate: quality.updates) }

        case .mute(let mute):
            notify { $0.signalClient(self, didUpdateRemoteMute: mute.sid, muted: mute.muted) }

        case .leave(let leave):
            notify { $0.signalClient(self, didReceiveLeave: leave.canReconnect) }

        case .streamStateUpdate(let states):
            notify { $0.signalClient(self, didUpdate: states.streamStates) }

        case .subscribedQualityUpdate(let update):
            // ignore 0.15.1
            if latestJoinResponse?.serverVersion == "0.15.1" {
                return
            }
            notify { $0.signalClient(self, didUpdate: update.trackSid, subscribedQualities: update.subscribedQualities)}
        case .subscriptionPermissionUpdate(let permissionUpdate):
            notify { $0.signalClient(self, didUpdate: permissionUpdate) }
        case .refreshToken(let token):
            notify { $0.signalClient(self, didUpdate: token) }
        }
    }
}

// MARK: - Wait extension

internal extension SignalClient {

    func waitForJoinResponse() -> WaitPromises<Livekit_JoinResponse> {

        let listen = Promise<Void>.pending()
        let wait = Promise<Livekit_JoinResponse>(on: .sdk) { resolve, _ in
            // create temporary delegate
            var delegate: SignalClientDelegateClosures?
            delegate = SignalClientDelegateClosures(didReceiveJoinResponse: { _, joinResponse in
                // wait until connected
                resolve(joinResponse)
                delegate = nil
                return true
            })
            // not required to clean up since weak reference
            self.add(delegate: delegate!)

            self.log("Waiting for join response...")
            listen.fulfill(())
        }
        // convert to a timed-promise
        .timeout(.defaultConnect)

        return (listen, wait)
    }
}

// MARK: - Internal

internal extension SignalClient {

    func resumeResponseQueue() -> Promise<Void> {

        log()

        return Promise<Void>(on: responseDispatchQueue) { () -> Void in

            defer { self.responseQueueState = .resumed }

            // quickly return if no queued requests
            guard !self.responseQueue.isEmpty else {
                self.log("No queued response")
                return
            }

            // send requests in sequential order
            let promises = self.responseQueue.reduce(into: Promise(())) { result, response in result.then(on: .sdk) { self.onSignalResponse(response) } }
            // clear the queue
            self.responseQueue.removeAll()

            // resolve promise in this queue
            try awaitPromise(promises)
        }
    }
}

// MARK: - Send methods

internal extension SignalClient {

    func sendQueuedRequests() -> Promise<Void> {

        // create a promise that never throws so the send sequence can continue
        func safeSend(_ request: Livekit_SignalRequest) -> Promise<Void> {
            sendRequest(request, enqueueIfReconnecting: false).recover(on: .sdk) { error in
                self.log("Failed to send queued request, request: \(request) \(error)", .warning)
            }
        }

        return Promise<Void>(on: requestDispatchQueue) { () -> Void in

            // quickly return if no queued requests
            guard !self.requestQueue.isEmpty else {
                self.log("No queued requests")
                return
            }

            // send requests in sequential order
            let promises = self.requestQueue.reduce(into: Promise(())) { result, request in result.then(on: .sdk) { safeSend(request) } }
            // clear the queue
            self.requestQueue.removeAll()

            // resolve promise in this queue
            try awaitPromise(promises)
        }
    }

    func sendOffer(offer: RTCSessionDescription) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.offer = offer.toPBType()
        }

        return sendRequest(r)
    }

    func sendAnswer(answer: RTCSessionDescription) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.answer = answer.toPBType()
        }

        return sendRequest(r)
    }

    func sendCandidate(candidate: RTCIceCandidate, target: Livekit_SignalTarget) -> Promise<Void> {
        log("target: \(target)")

        return Promise { () -> Livekit_SignalRequest in

            try Livekit_SignalRequest.with {
                $0.trickle = try Livekit_TrickleRequest.with {
                    $0.target = target
                    $0.candidateInit = try candidate.toLKType().toJsonString()
                }
            }

        }.then(on: .sdk) {
            self.sendRequest($0)
        }
    }

    func sendMuteTrack(trackSid: String, muted: Bool) -> Promise<Void> {
        log("trackSid: \(trackSid), muted: \(muted)")

        let r = Livekit_SignalRequest.with {
            $0.mute = Livekit_MuteTrackRequest.with {
                $0.sid = trackSid
                $0.muted = muted
            }
        }

        return sendRequest(r)
    }

    func sendAddTrack(cid: String,
                      name: String,
                      type: Livekit_TrackType,
                      source: Livekit_TrackSource = .unknown,
                      _ populator: (inout Livekit_AddTrackRequest) -> Void) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.addTrack = Livekit_AddTrackRequest.with {
                populator(&$0)
                $0.cid = cid
                $0.name = name
                $0.type = type
                $0.source = source
            }
        }

        return sendRequest(r)
    }

    func sendUpdateTrackSettings(sid: Sid, settings: TrackSettings) -> Promise<Void> {
        log("sid: \(sid), settings: \(settings)")
        // we have to send either width/height or quality.
        // when both are sent, width/height are used.
        if settings.enabled, settings.dimensions == .zero && settings.videoQuality == .low {
            log("either width/height or quality is not set while enabling", .warning)
        }

        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [sid]
                $0.disabled = !settings.enabled
                $0.width = UInt32(settings.dimensions.width)
                $0.height = UInt32(settings.dimensions.height)
                $0.quality = settings.videoQuality.toPBType()
            }
        }

        return sendRequest(r)
    }

    func sendUpdateVideoLayers(trackSid: Sid,
                               layers: [Livekit_VideoLayer]) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.updateLayers = Livekit_UpdateVideoLayers.with {
                $0.trackSid = trackSid
                $0.layers = layers
            }
        }

        return sendRequest(r)
    }

    func sendUpdateSubscription(participantSid: Sid,
                                trackSid: String,
                                subscribed: Bool) -> Promise<Void> {
        log()

        let p = Livekit_ParticipantTracks.with {
            $0.participantSid = participantSid
            $0.trackSids = [trackSid]
        }

        let r = Livekit_SignalRequest.with {
            $0.subscription = Livekit_UpdateSubscription.with {
                $0.trackSids = [trackSid] // Deprecated
                $0.participantTracks = [p]
                $0.subscribe = subscribed
            }
        }

        return sendRequest(r)
    }

    func sendUpdateSubscriptionPermission(allParticipants: Bool,
                                          trackPermissions: [ParticipantTrackPermission]) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.subscriptionPermission = Livekit_SubscriptionPermission.with {
                $0.allParticipants = allParticipants
                $0.trackPermissions = trackPermissions.map({ $0.toPBType() })
            }
        }

        return sendRequest(r)
    }

    func sendSyncState(answer: Livekit_SessionDescription,
                       subscription: Livekit_UpdateSubscription,
                       publishTracks: [Livekit_TrackPublishedResponse]? = nil,
                       dataChannels: [Livekit_DataChannelInfo]? = nil) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.syncState = Livekit_SyncState.with {
                $0.answer = answer
                $0.subscription = subscription
                $0.publishTracks = publishTracks ?? []
                $0.dataChannels = dataChannels ?? []
            }
        }

        return sendRequest(r)
    }

    func sendLeave() -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest()
        }

        return sendRequest(r)
    }

    func sendSimulate(scenario: SimulateScenario) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.simulate = Livekit_SimulateScenario.with {
                if case .nodeFailure = scenario { $0.nodeFailure = true }
                if case .migration = scenario { $0.migration = true }
                if case .serverLeave = scenario { $0.serverLeave = true }
                if case .speakerUpdate(let secs) = scenario { $0.speakerUpdate = Int32(secs) }
            }
        }

        return sendRequest(r)
    }
}

internal extension Livekit_SignalRequest {

    func canEnqueue() -> Bool {
        switch self.message {
        case .syncState: return false
        case .trickle: return false
        case .offer: return false
        case .answer: return false
        case .simulate: return false
        default: return true
        }
    }
}

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

internal class SignalClient: MulticastDelegate<SignalClientDelegate> {

    private let queue = DispatchQueue(label: "LiveKitSDK.signalClient", qos: .default)

    // MARK: - Public

    public var connectionState: ConnectionState { _state.connectionState }

    // MARK: - Internal

    internal struct State: ReconnectableState, Equatable {
        var reconnectMode: ReconnectMode?
        var connectionState: ConnectionState = .disconnected()
        var joinResponseCompleter = Completer<Livekit_JoinResponse>()
        var completersForAddTrack = [String: Completer<Livekit_TrackInfo>]()
    }

    internal var _state = StateSync(State())
    
    enum Errors: Error {
        case alreadyConnected
        case invalidJoinResponse
    }

    // MARK: - Private

    private enum QueueState {
        case resumed
        case suspended
    }

    // queue to store requests while reconnecting
    private var requestQueue = [Livekit_SignalRequest]()
    private var responseQueue = [Livekit_SignalResponse]()

    private let requestDispatchQueue = DispatchQueue(label: "LiveKitSDK.signalClient.requestQueue", qos: .default)
    private let responseDispatchQueue = DispatchQueue(label: "LiveKitSDK.signalClient.responseQueue", qos: .default)

    private var responseQueueState: QueueState = .resumed

    private var webSocket: WebSocket?
    private var latestJoinResponse: Livekit_JoinResponse?
    
    private var responseSubscriptions: Set<AnyCancellable> = []
    private let receivedResponses: CurrentValueSubject<Livekit_SignalResponse?, Never>
    var receivedResponsePublisher: AnyPublisher<Livekit_SignalResponse.OneOf_Message, Never> {
        receivedResponses
            .compactMap { [weak self] signalResponse in
                guard let self else { return nil }
                guard let message = signalResponse?.message else {
                    self.log("Failed to decode SignalResponse", .warning)
                    return nil
                }
                return message
            }
            .eraseToAnyPublisher()
    }
    
    private let joinResponses: CurrentValueSubject<Livekit_JoinResponse?, Never>

    private var pingIntervalTimer: DispatchQueueTimer?
    private var pingTimeoutTimer: DispatchQueueTimer?

    init() {
        receivedResponses = CurrentValueSubject(nil)
        joinResponses = CurrentValueSubject(nil)
        
        super.init()

        log()
        
        joinResponsesSubscription()

        // trigger events when state mutates
        self._state.onDidMutate = { [weak self] newState, oldState in

            guard let self = self else { return }

            // connectionState did update
            if newState.connectionState != oldState.connectionState {
                self.log("\(oldState.connectionState) -> \(newState.connectionState)")
            }

            self.notify { $0.signalClient(self, didMutate: newState, oldState: oldState) }
        }
    }

    deinit {
        log()
        responseSubscriptions.removeAll()
    }
    
    private func joinResponsesSubscription() {
        receivedResponsePublisher
            .compactMap {
                guard case .join(let joinResponse) = $0 else { return nil }
                return joinResponse
            }
            .assign(to: \.value, on: joinResponses)
            .store(in: &responseSubscriptions)
    }
    
    func _joinResponse() async throws -> Livekit_JoinResponse {
        if #available(iOS 15.0, *) {
            var result: Livekit_JoinResponse?
            for await joinResponse in joinResponses.values {
                guard let joinResponse else { continue }
                result = joinResponse
                break // << stop at the first valid join response
            }
            
            guard let result else { throw Errors.invalidJoinResponse }
            return result
            
        } else {
            fatalError()
        }
    }

    func _connect(urlString: String, token: String, connectOptions: ConnectOptions? = nil, reconnectMode: ReconnectMode? = nil, adaptiveStream: Bool) async throws {
        
        guard self.webSocket == nil else { throw Errors.alreadyConnected }
        
        await _cleanUp()
        
        log("reconnectMode: \(String(describing: reconnectMode))")
        
        guard let url = Utils.buildUrl(urlString,
                                       token,
                                       connectOptions: connectOptions,
                                       reconnectMode: reconnectMode,
                                       adaptiveStream: adaptiveStream) else { throw InternalError.parse(message: "Failed to parse url") }
        log("Connecting with url: \(urlString)")
        
        _state.mutate {
            $0.reconnectMode = reconnectMode
            $0.connectionState = .connecting
        }
        
        let websocket = try await socketConnect(url: url, urlString: urlString, reconnectMode: reconnectMode) {
            Utils.buildUrl(urlString,
                           token,
                           connectOptions: connectOptions,
                           adaptiveStream: adaptiveStream,
                           validate: true)
        }
        
        self._state.mutate { $0.connectionState = .connected }
        self.queue.async {
            self.webSocket = websocket
        }
    }
    
    private func socketConnect(url: URL,
                               urlString: String,
                               reconnectMode: ReconnectMode? = nil,
                               validatedURL: @escaping () -> URL?) async throws -> WebSocket {
        
        try await withUnsafeThrowingContinuation { continuation in
            
            WebSocket.connect(
                url: url,
                onMessage: self.onWebSocketMessage,
                onDisconnect: { reason in
                    self.cleanUp(reason: reason)
                    self.queue.sync {
                        self.webSocket = nil
                    }
                }
            )
            .then(on: queue) { (webSocket: WebSocket) -> Void in
                dispatchPrecondition(condition: .onQueue(self.queue))
                continuation.resume(returning: webSocket)
            }
            .recover(on: queue) { error -> Promise<Void> in
                // Skip validation if reconnect mode
                guard reconnectMode == nil else { throw error }
                // Catch first, then throw again after getting validation response
                // Re-build url with validate mode
                guard let validateUrl = validatedURL() else {
                    return Promise(InternalError.parse(message: "Failed to parse validation url"))
                }
                
                self.log("Validating with url: \(validateUrl)")
                
                return HTTP().get(on: self.queue, url: validateUrl).then(on: self.queue) { data in
                    guard let string = String(data: data, encoding: .utf8) else {
                        throw SignalClientError.connect(message: "Failed to decode string")
                    }
                    self.log("validate response: \(string)")
                    // re-throw with validation response
                    throw SignalClientError.connect(message: string)
                }
            }
            .catch(on: queue) { error in
                self.cleanUp(reason: .networkError(error))
                continuation.resume(throwing: error)
            }
        }
    }
    
    func connect(_ urlString: String,
                 _ token: String,
                 connectOptions: ConnectOptions? = nil,
                 reconnectMode: ReconnectMode? = nil,
                 adaptiveStream: Bool) -> Promise<Void> {

        cleanUp()

        log("reconnectMode: \(String(describing: reconnectMode))")

        guard let url = Utils.buildUrl(urlString,
                                       token,
                                       connectOptions: connectOptions,
                                       reconnectMode: reconnectMode,
                                       adaptiveStream: adaptiveStream) else {

            return Promise(InternalError.parse(message: "Failed to parse url"))
        }

        log("Connecting with url: \(urlString)")

        self._state.mutate {
            $0.reconnectMode = reconnectMode
            $0.connectionState = .connecting
        }

        return WebSocket.connect(url: url,
                                 onMessage: self.onWebSocketMessage,
                                 onDisconnect: { reason in
                                    self.webSocket = nil
                                    self.cleanUp(reason: reason)
                                 })
            .then(on: queue) { (webSocket: WebSocket) -> Void in
                self.webSocket = webSocket
                self._state.mutate { $0.connectionState = .connected }
            }.recover(on: queue) { error -> Promise<Void> in
                // Skip validation if reconnect mode
                if reconnectMode != nil { throw error }
                // Catch first, then throw again after getting validation response
                // Re-build url with validate mode
                guard let validateUrl = Utils.buildUrl(urlString,
                                                       token,
                                                       connectOptions: connectOptions,
                                                       adaptiveStream: adaptiveStream,
                                                       validate: true) else {

                    return Promise(InternalError.parse(message: "Failed to parse validation url"))
                }

                self.log("Validating with url: \(validateUrl)")

                return HTTP().get(on: self.queue, url: validateUrl).then(on: self.queue) { data in
                    guard let string = String(data: data, encoding: .utf8) else {
                        throw SignalClientError.connect(message: "Failed to decode string")
                    }
                    self.log("validate response: \(string)")
                    // re-throw with validation response
                    throw SignalClientError.connect(message: string)
                }
            }.catch(on: queue) { error in
                self.cleanUp(reason: .networkError(error))
            }
    }
    
    func _cleanUp(reason: DisconnectReason? = nil) async {
        log("reason: \(String(describing: reason))")
        
        _state.mutate { $0.connectionState = .disconnected(reason: reason) }

        pingIntervalTimer = nil
        pingTimeoutTimer = nil

        if let socket = webSocket {
            socket.cleanUp(reason: reason, notify: false)
            socket.onMessage = nil
            socket.onDisconnect = nil
            self.webSocket = nil
        }

        latestJoinResponse = nil

        _state.mutate {
            for var completer in $0.completersForAddTrack.values {
                completer.reset()
            }

            $0.joinResponseCompleter.reset()

            // reset state
            $0 = State()
        }

        await withUnsafeContinuation { continuation in
            requestDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                self.requestQueue = []
                continuation.resume()
            }
        }

        await withUnsafeContinuation { continuation in
            responseDispatchQueue.async { [weak self] in
                guard let self = self else { return }
                self.responseQueue = []
                self.responseQueueState = .resumed
                continuation.resume()
            }
        }
    }

    func cleanUp(reason: DisconnectReason? = nil) {

        log("reason: \(String(describing: reason))")

        _state.mutate { $0.connectionState = .disconnected(reason: reason) }

        pingIntervalTimer = nil
        pingTimeoutTimer = nil

        if let socket = webSocket {
            socket.cleanUp(reason: reason, notify: false)
            socket.onMessage = nil
            socket.onDisconnect = nil
            self.webSocket = nil
        }

        latestJoinResponse = nil

        _state.mutate {
            for var completer in $0.completersForAddTrack.values {
                completer.reset()
            }

            $0.joinResponseCompleter.reset()

            // reset state
            $0 = State()
        }

        requestDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.requestQueue = []
        }

        responseDispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.responseQueue = []
            self.responseQueueState = .resumed
        }
    }

    func completeCompleter(forAddTrackRequest trackCid: String, trackInfo: Livekit_TrackInfo) {

        _state.mutate {
            if var completer = $0.completersForAddTrack[trackCid] {
                log("[publish] found the completer resolving...")
                completer.set(value: trackInfo)
            }
        }
    }

    func prepareCompleter(forAddTrackRequest trackCid: String) -> Promise<Livekit_TrackInfo> {

        _state.mutate { state -> Promise<Livekit_TrackInfo> in

            if state.completersForAddTrack.keys.contains(trackCid) {
                // reset if already exists
                state.completersForAddTrack[trackCid]!.reset()
            } else {
                state.completersForAddTrack[trackCid] = Completer<Livekit_TrackInfo>()
            }

            return state.completersForAddTrack[trackCid]!.wait(on: queue,
                                                               .defaultPublish,
                                                               throw: { EngineError.timedOut(message: "server didn't respond to addTrack request") })
        }
    }
}

// MARK: - Private

private extension SignalClient {

    func _sendRequest(_ request: Livekit_SignalRequest, enqueueIfReconnecting: Bool = true) async throws {
        guard !(self._state.connectionState.isReconnecting && request.canEnqueue() && enqueueIfReconnecting) else {
            self.log("queuing request while reconnecting, request: \(request)")
            requestDispatchQueue.async {
                self.requestQueue.append(request)
            }
            return
        }
        
        guard case .connected = self.connectionState else {
            self.log("not connected", .error)
            throw SignalClientError.state(message: "Not connected")
        }
        
        // this shouldn't happen
        guard let webSocket = self.webSocket else {
            self.log("webSocket is nil", .error)
            throw SignalClientError.state(message: "WebSocket is nil")
        }
        
        guard let data = try? request.serializedData() else {
            self.log("could not serialize data", .error)
            throw InternalError.convert(message: "Could not serialize data")
        }
        
        try await webSocket.send(data: data)
    }
    
    // send request or enqueue while reconnecting
    func sendRequest(_ request: Livekit_SignalRequest, enqueueIfReconnecting: Bool = true) -> Promise<Void> {

        Promise<Void>(on: requestDispatchQueue) { [weak self] () -> Promise<Void> in

            guard let self = self else { return Promise(()) }

            guard !(self._state.connectionState.isReconnecting && request.canEnqueue() && enqueueIfReconnecting) else {
                self.log("queuing request while reconnecting, request: \(request)")
                self.requestQueue.append(request)
                // success
                return Promise(())
            }

            guard case .connected = self.connectionState else {
                self.log("not connected", .error)
                throw SignalClientError.state(message: "Not connected")
            }

            // this shouldn't happen
            guard let webSocket = self.webSocket else {
                self.log("webSocket is nil", .error)
                throw SignalClientError.state(message: "WebSocket is nil")
            }

            guard let data = try? request.serializedData() else {
                self.log("could not serialize data", .error)
                throw InternalError.convert(message: "Could not serialize data")
            }

            return webSocket.send(data: data)
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
            
            self.receivedResponses.send(response)
        }
    }

    func onSignalResponse(_ response: Livekit_SignalResponse) {

        guard case .connected = connectionState else {
            log("Not connected, received response though: \(response)", .warning)
            return
        }

        guard let message = response.message else {
            log("Failed to decode SignalResponse", .warning)
            return
        }

        switch message {
        case .join(let joinResponse):
            responseQueueState = .suspended
            latestJoinResponse = joinResponse
            restartPingTimer()
            notify { $0.signalClient(self, didReceive: joinResponse) }
            _state.mutate { $0.joinResponseCompleter.set(value: joinResponse) }

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
            // not required to be handled because we use completer pattern for this case
            notify(requiresHandle: false) { $0.signalClient(self, didPublish: trackPublished) }

            log("[publish] resolving completer for cid: \(trackPublished.cid)")
            // complete
            completeCompleter(forAddTrackRequest: trackPublished.cid, trackInfo: trackPublished.track)

        case .trackUnpublished(let trackUnpublished):
            notify { $0.signalClient(self, didUnpublish: trackUnpublished) }

        case .speakersChanged(let speakers):
            notify { $0.signalClient(self, didUpdate: speakers.speakers) }

        case .connectionQuality(let quality):
            notify { $0.signalClient(self, didUpdate: quality.updates) }

        case .mute(let mute):
            notify { $0.signalClient(self, didUpdateRemoteMute: mute.sid, muted: mute.muted) }

        case .leave(let leave):
            notify { $0.signalClient(self, didReceiveLeave: leave.canReconnect, reason: leave.reason) }

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
        case .pong(let r):
            onReceivedPong(r)
        case .reconnect:
            log("received reconnect message")
        case .pongResp:
            log("received pongResp message")
        }
    }
}

// MARK: - Internal

internal extension SignalClient {

    func _resumeResponseQueue() async {
        
        await withUnsafeContinuation({ (continuation: UnsafeContinuation<Void, Never>) in
            
            responseDispatchQueue.async {
                defer { self.responseQueueState = .resumed }
                
                // quickly return if no queued requests
                guard !self.responseQueue.isEmpty else {
                    self.log("No queued response")
                    continuation.resume()
                    return
                }
                
                // send requests in sequential order
                let promises = self.responseQueue.reduce(into: Promise(())) { result, response in
                    result = result.then(on: self.queue) { self.onSignalResponse(response) }
                }
                
                // clear the queue
                self.responseQueue = []
                
                promises.then(on: self.queue) {
                    continuation.resume()
                }
            }
        })
    }
    
    func resumeResponseQueue() -> Promise<Void> {

        log()

        return Promise<Void>(on: responseDispatchQueue) { () -> Promise<Void> in

            defer { self.responseQueueState = .resumed }

            // quickly return if no queued requests
            guard !self.responseQueue.isEmpty else {
                self.log("No queued response")
                return Promise(())
            }

            // send requests in sequential order
            let promises = self.responseQueue.reduce(into: Promise(())) { result, response in
                result = result.then(on: self.queue) { self.onSignalResponse(response) }
            }

            // clear the queue
            self.responseQueue = []

            return promises
        }
    }
}

// MARK: - Send methods

internal extension SignalClient {

    func sendQueuedRequests() -> Promise<Void> {

        // create a promise that never throws so the send sequence can continue
        func safeSend(_ request: Livekit_SignalRequest) -> Promise<Void> {
            sendRequest(request, enqueueIfReconnecting: false).recover(on: queue) { error in
                self.log("Failed to send queued request, request: \(request) \(error)", .warning)
            }
        }

        return Promise<Void>(on: requestDispatchQueue) { () -> Promise<Void> in

            // quickly return if no queued requests
            guard !self.requestQueue.isEmpty else {
                self.log("No queued requests")
                return Promise(())
            }

            // send requests in sequential order
            let promises = self.requestQueue.reduce(into: Promise(())) { result, request in
                result = result.then(on: self.queue) { safeSend(request) }
            }

            // clear the queue
            self.requestQueue = []

            return promises
        }
    }
    
    func _sendOffer(offer: RTCSessionDescription) async throws {
        log()

        let request = Livekit_SignalRequest.with {
            $0.offer = offer.toPBType()
        }

        try await _sendRequest(request)
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

        }.then(on: queue) {
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

    typealias AddTrackRequestPopulator<R> = (inout Livekit_AddTrackRequest) throws -> R
    typealias AddTrackResult<R> = (result: R, trackInfo: Livekit_TrackInfo)

    func sendAddTrack<R>(cid: String,
                         name: String,
                         type: Livekit_TrackType,
                         source: Livekit_TrackSource = .unknown,
                         _ populator: AddTrackRequestPopulator<R>) -> Promise<AddTrackResult<R>> {
        log()

        do {
            var addTrackRequest = Livekit_AddTrackRequest.with {
                $0.cid = cid
                $0.name = name
                $0.type = type
                $0.source = source
            }

            let populateResult = try populator(&addTrackRequest)

            let request = Livekit_SignalRequest.with {
                $0.addTrack = addTrackRequest
            }

            let completer = prepareCompleter(forAddTrackRequest: cid)

            return sendRequest(request).then(on: queue) {
                completer
            }.then(on: queue) { trackInfo in
                AddTrackResult(result: populateResult, trackInfo: trackInfo)
            }

        } catch let error {
            // the populator block throwed
            return Promise(error)
        }
    }

    func sendUpdateTrackSettings(sid: Sid, settings: TrackSettings) -> Promise<Void> {

        log("sending track settings... sid: \(sid), settings: \(settings)")

        let r = Livekit_SignalRequest.with {
            $0.trackSetting = Livekit_UpdateTrackSettings.with {
                $0.trackSids = [sid]
                $0.disabled = !settings.enabled
                $0.width = UInt32(settings.dimensions.width)
                $0.height = UInt32(settings.dimensions.height)
                $0.quality = settings.videoQuality.toPBType()
                $0.fps = UInt32(settings.preferredFPS)
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
                       offer: Livekit_SessionDescription?,
                       subscription: Livekit_UpdateSubscription,
                       publishTracks: [Livekit_TrackPublishedResponse]? = nil,
                       dataChannels: [Livekit_DataChannelInfo]? = nil) -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.syncState = Livekit_SyncState.with {
                $0.answer = answer
                if let offer = offer {
                    $0.offer = offer
                }
                $0.subscription = subscription
                $0.publishTracks = publishTracks ?? []
                $0.dataChannels = dataChannels ?? []
            }
        }

        return sendRequest(r)
    }
    
    func sendLeave() async throws {
        log()

        let request = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest.with {
                $0.canReconnect = false
                $0.reason = .clientInitiated
            }
        }

        try await _sendRequest(request)
    }

    @discardableResult
    func sendLeave() -> Promise<Void> {
        log()

        let r = Livekit_SignalRequest.with {
            $0.leave = Livekit_LeaveRequest.with {
                $0.canReconnect = false
                $0.reason = .clientInitiated
            }
        }

        return sendRequest(r)
    }

    @discardableResult
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

    @discardableResult
    private func sendPing() -> Promise<Void> {
        log("ping/pong: sending...", .trace)

        let r = Livekit_SignalRequest.with {
            $0.ping = Int64(Date().timeIntervalSince1970)
        }

        return sendRequest(r)
    }
}

// MARK: - Server ping/pong logic

private extension SignalClient {

    func onPingIntervalTimer() {

        guard let jr = latestJoinResponse else { return }

        sendPing().then(on: queue) { [weak self] in

            guard let self = self else { return }

            if self.pingTimeoutTimer == nil {
                // start timeout timer

                self.pingTimeoutTimer = {
                    let timer = DispatchQueueTimer(timeInterval: TimeInterval(jr.pingTimeout), queue: self.queue)
                    timer.handler = { [weak self] in
                        guard let self = self else { return }
                        self.log("ping/pong timed out", .error)
                        self.cleanUp(reason: .networkError(SignalClientError.serverPingTimedOut()))
                    }
                    timer.resume()
                    return timer
                }()
            }
        }
    }

    func onReceivedPong(_ r: Int64) {

        log("ping/pong received pong from server", .trace)
        // clear timeout timer
        pingTimeoutTimer = nil
    }

    func restartPingTimer() {
        // always suspend first
        pingIntervalTimer = nil
        pingTimeoutTimer = nil
        // check received joinResponse already
        guard let jr = latestJoinResponse,
              // check server supports ping/pong
              jr.pingTimeout > 0,
              jr.pingInterval > 0 else { return }

        log("ping/pong starting with interval: \(jr.pingInterval), timeout: \(jr.pingTimeout)")

        pingIntervalTimer = {
            let timer = DispatchQueueTimer(timeInterval: TimeInterval(jr.pingInterval), queue: queue)
            timer.handler = { [weak self] in self?.onPingIntervalTimer() }
            timer.resume()
            return timer
        }()
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
        case .leave: return false
        default: return true
        }
    }
}

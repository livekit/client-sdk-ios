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

#if canImport(ReplayKit)
import ReplayKit
#endif

@objc
public class LocalParticipant: Participant {

    @objc
    public var localAudioTracks: [LocalTrackPublication] { audioTracks.compactMap { $0 as? LocalTrackPublication } }

    @objc
    public var localVideoTracks: [LocalTrackPublication] { videoTracks.compactMap { $0 as? LocalTrackPublication } }

    private var allParticipantsAllowed: Bool = true
    private var trackPermissions: [ParticipantTrackPermission] = []

    internal convenience init(from info: Livekit_ParticipantInfo,
                              room: Room) {

        self.init(sid: info.sid,
                  identity: info.identity,
                  name: info.name,
                  room: room)

        updateFromInfo(info: info)
    }

    internal func getTrackPublication(sid: Sid) -> LocalTrackPublication? {
        _state.tracks[sid] as? LocalTrackPublication
    }

    internal func publish(track: LocalTrack,
                          publishOptions: PublishOptions? = nil) -> Promise<LocalTrackPublication> {

        log("[publish] \(track) options: \(String(describing: publishOptions ?? nil))...", .info)

        guard let publisher = room.engine.publisher else {
            return Promise(EngineError.state(message: "publisher is null"))
        }

        guard _state.tracks.values.first(where: { $0.track === track }) == nil else {
            return Promise(TrackError.publish(message: "This track has already been published."))
        }

        guard track is LocalVideoTrack || track is LocalAudioTrack else {
            return Promise(TrackError.publish(message: "Unknown LocalTrack type"))
        }

        // try to start the track
        return track.start().then(on: queue) { _ -> Promise<Dimensions?> in
            // ensure dimensions are resolved for VideoTracks
            guard let track = track as? LocalVideoTrack else { return Promise(nil) }

            self.log("[publish] waiting for dimensions to resolve...")

            // wait for dimensions
            return track.capturer._state.mutate { $0.dimensionsCompleter.wait(on: self.queue,
                                                                              .defaultCaptureStart,
                                                                              throw: { TrackError.timedOut(message: "unable to resolve dimensions") }) }.then(on: self.queue) { $0 }

        }.then(on: queue) { dimensions -> Promise<(result: RTCRtpTransceiverInit, trackInfo: Livekit_TrackInfo)> in
            // request a new track to the server
            self.room.engine.signalClient.sendAddTrack(cid: track.mediaTrack.trackId,
                                                       name: track.name,
                                                       type: track.kind.toPBType(),
                                                       source: track.source.toPBType()) { populator in

                let transInit = DispatchQueue.webRTC.sync { RTCRtpTransceiverInit() }
                transInit.direction = .sendOnly

                if let track = track as? LocalVideoTrack {

                    guard let dimensions = dimensions else {
                        throw TrackError.publish(message: "VideoCapturer dimensions are unknown")
                    }

                    self.log("[publish] computing encode settings with dimensions: \(dimensions)...")

                    let publishOptions = (publishOptions as? VideoPublishOptions) ?? self.room._state.options.defaultVideoPublishOptions

                    var simEncodings: [RTCRtpEncodingParameters]?

                    // if backup codec is enabled
                    if publishOptions.shouldUseBackupCodec {

                        simEncodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                                   publishOptions: publishOptions,
                                                                   isScreenShare: track.source == .screenShareVideo,
                                                                   isBackup: true)

                        populator.simulcastCodecs = [
                            Livekit_SimulcastCodec.with {
                                $0.codec = publishOptions.preferredCodec.rawStringValue ?? ""
                                $0.cid = track.mediaTrack.trackId
                                $0.enableSimulcastLayers = true
                            },
                            Livekit_SimulcastCodec.with {
                                $0.codec = publishOptions.preferredBackupCodec.rawStringValue ?? ""
                                $0.cid = ""
                                $0.enableSimulcastLayers = true
                            }
                        ]
                    }

                    let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                                publishOptions: publishOptions,
                                                                isScreenShare: track.source == .screenShareVideo)

                    self.log("[publish] using encodings: \(encodings) simEncodings: \(String(describing: simEncodings)), simulcastCodecs: \(populator.simulcastCodecs)")

                    transInit.sendEncodings = encodings

                    populator.width = UInt32(dimensions.width)
                    populator.height = UInt32(dimensions.height)
                    populator.layers = dimensions.videoLayers(for: simEncodings ?? encodings)

                    self.log("[publish] requesting add track to server with \(populator)...")

                } else if track is LocalAudioTrack {
                    // additional params for Audio
                    let publishOptions = (publishOptions as? AudioPublishOptions) ?? self.room._state.options.defaultAudioPublishOptions

                    populator.disableDtx = !publishOptions.dtx

                    let encoding = publishOptions.encoding ?? AudioEncoding.presetSpeech

                    self.log("[publish] maxBitrate: \(encoding.maxBitrate)")

                    transInit.sendEncodings = [
                        Engine.createRtpEncodingParameters(encoding: encoding)
                    ]
                }

                return transInit
            }

        }.then(on: queue) { (transInit, trackInfo) -> Promise<(transceiver: RTCRtpTransceiver, trackInfo: Livekit_TrackInfo)> in

            self.log("[publish] server responded trackInfo: \(trackInfo)")

            // add transceiver to pc
            return publisher.addTransceiver(with: track.mediaTrack,
                                            transceiverInit: transInit).then(on: self.queue) { transceiver in
                                                // pass down trackInfo and created transceiver
                                                (transceiver, trackInfo)
                                            }
        }.then(on: queue) { params -> Promise<(RTCRtpTransceiver, trackInfo: Livekit_TrackInfo)> in
            self.log("[publish] added transceiver: \(params.trackInfo)...")
            return track.onPublish().then(on: self.queue) { _ in params }
        }.then(on: queue) { (transceiver, trackInfo) -> LocalTrackPublication in

            if let track = track as? LocalVideoTrack {
                let publishOptions = (publishOptions as? VideoPublishOptions) ?? self.room._state.options.defaultVideoPublishOptions
                transceiver.setPreferredVideoCodec(publishOptions.preferredCodec)
                track.codec = publishOptions.preferredCodec
                self.log("[publish] codecPreferences: \(publishOptions.preferredCodec) -> \(transceiver.codecPreferences)...")
            }

            // store publishOptions used for this track
            track._publishOptions = publishOptions

            track.set(transport: publisher,
                      rtpSender: transceiver.sender)

            // prefer to maintainResolution for screen share
            if case .screenShareVideo = track.source {
                self.log("[publish] set degradationPreference to .maintainResolution")
                let params = transceiver.sender.parameters
                params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
                // changing params directly doesn't work so we need to update params
                // and set it back to sender.parameters
                transceiver.sender.parameters = params
            }

            self.room.engine.publisherShouldNegotiate()

            let publication = LocalTrackPublication(info: trackInfo, track: track, participant: self)
            self.addTrack(publication: publication)

            // notify didPublish
            self.delegates.notify(label: { "localParticipant.didPublish \(publication)" }) {
                $0.localParticipant?(self, didPublish: publication)
            }
            self.room.delegates.notify(label: { "localParticipant.didPublish \(publication)" }) {
                $0.room?(self.room, localParticipant: self, didPublish: publication)
            }

            self.log("[publish] success \(publication)", .info)
            return publication

        }.catch(on: queue) { error in

            self.log("[publish] failed \(track), error: \(error)", .error)

            // stop the track
            track.stop().catch(on: self.queue) { error in
                self.log("[publish] failed to stop track, error: \(error)", .error)
            }
        }
    }

    /// publish a new audio track to the Room
    public func publishAudioTrack(track: LocalAudioTrack,
                                  publishOptions: AudioPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        publish(track: track, publishOptions: publishOptions)
    }

    /// publish a new video track to the Room
    public func publishVideoTrack(track: LocalVideoTrack,
                                  publishOptions: VideoPublishOptions? = nil) -> Promise<LocalTrackPublication> {

        publish(track: track, publishOptions: publishOptions)
    }

    public override func unpublishAll(notify _notify: Bool = true) -> Promise<Void> {
        // build a list of promises
        let promises = _state.tracks.values.compactMap { $0 as? LocalTrackPublication }
            .map { unpublish(publication: $0, notify: _notify) }
        // combine promises to wait all to complete
        return promises.all(on: queue)
    }

    /// unpublish an existing published track
    /// this will also stop the track
    public func unpublish(publication: LocalTrackPublication, notify _notify: Bool = true) -> Promise<Void> {

        func notifyDidUnpublish() -> Promise<Void> {

            Promise<Void>(on: queue) {
                guard _notify else { return }
                // notify unpublish
                self.delegates.notify(label: { "localParticipant.didUnpublish \(publication)" }) {
                    $0.localParticipant?(self, didUnpublish: publication)
                }
                self.room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                    $0.room?(self.room, localParticipant: self, didUnpublish: publication)
                }
            }
        }

        let engine = self.room.engine

        // remove the publication
        _state.mutate { $0.tracks.removeValue(forKey: publication.sid) }

        // if track is nil, only notify unpublish and return
        guard let track = publication.track as? LocalTrack else {
            return notifyDidUnpublish()
        }

        // build a conditional promise to stop track if required by option
        func stopTrackIfRequired() -> Promise<Bool> {
            if room._state.options.stopLocalTrackOnUnpublish {
                return track.stop()
            }
            // Do nothing
            return Promise(false)
        }

        // wait for track to stop (if required)
        // engine.publisher must be accessed from engine.queue
        return stopTrackIfRequired().then(on: engine.queue) { _ -> Promise<Void> in

            guard let publisher = engine.publisher, let sender = track.rtpSender else {
                return Promise(())
            }

            // remove track
            return publisher.removeTrack(sender).then(on: self.queue) { () -> Promise<Void> in
                // check if track is a LocalVideoTrack
                guard let track = publication.track as? LocalVideoTrack else {
                    // simply return if not a LocalVideoTrack
                    return Promise(())
                }

                let simulcastSenders = track.simulcastCodecs.values.map { $0.sender }.compactMap { $0 }
                let removeTrackPromises = simulcastSenders.map { publisher.removeTrack($0) }
                // remove all simulcast senders
                return removeTrackPromises.all(on: self.queue)
            }.then(on: self.queue) {
                engine.publisherShouldNegotiate()
            }
        }.then(on: queue) {
            track.onUnpublish()
        }.then(on: queue) { _ -> Promise<Void> in
            notifyDidUnpublish()
        }
    }

    /// Publish data to the other participants in the room
    ///
    /// Data is forwarded to each participant in the room. Each payload must not exceed 15k.
    /// - Parameters:
    ///   - data: Data to send
    ///   - reliability: Toggle between sending relialble vs lossy delivery.
    ///     For data that you need delivery guarantee (such as chat messages), use Reliable.
    ///     For data that should arrive as quickly as possible, but you are ok with dropped packets, use Lossy.
    ///   - destination: SIDs of the participants who will receive the message. If empty, deliver to everyone
    ///
    /// > Notice: Deprecated, use ``publish(data:reliability:destinations:topic:options:)-2581z`` instead.
    @available(*, deprecated, renamed: "publish(data:reliability:destinations:topic:options:)")
    @discardableResult
    public func publishData(data: Data,
                            reliability: Reliability = .reliable,
                            destination: [String] = []) -> Promise<Void> {

        let userPacket = Livekit_UserPacket.with {
            $0.destinationSids = destination
            $0.payload = data
            $0.participantSid = self.sid
        }

        return room.engine.send(userPacket: userPacket,
                                reliability: reliability)
    }

    ///
    /// Promise version of ``publish(data:reliability:destinations:topic:options:)-75jme``.
    ///
    @discardableResult
    public func publish(data: Data,
                        reliability: Reliability = .reliable,
                        destinations: [RemoteParticipant]? = nil,
                        topic: String? = nil,
                        options: DataPublishOptions? = nil) -> Promise<Void> {

        let options = options ?? self.room._state.options.defaultDataPublishOptions
        let destinations = destinations?.map { $0.sid }

        let userPacket = Livekit_UserPacket.with {
            $0.destinationSids = destinations ?? options.destinations
            $0.payload = data
            $0.participantSid = self.sid
            $0.topic = topic ?? options.topic ?? ""
        }

        return room.engine.send(userPacket: userPacket,
                                reliability: reliability)
    }

    /**
     * Control who can subscribe to LocalParticipant's published tracks.
     *
     * By default, all participants can subscribe. This allows fine-grained control over
     * who is able to subscribe at a participant and track level.
     *
     * Note: if access is given at a track-level (i.e. both ``allParticipantsAllowed`` and
     * ``ParticipantTrackPermission/allTracksAllowed`` are false), any newer published tracks
     * will not grant permissions to any participants and will require a subsequent
     * permissions update to allow subscription.
     *
     * - Parameter allParticipantsAllowed Allows all participants to subscribe all tracks.
     *  Takes precedence over ``participantTrackPermissions`` if set to true.
     *  By default this is set to true.
     * - Parameter participantTrackPermissions Full list of individual permissions per
     *  participant/track. Any omitted participants will not receive any permissions.
     */
    @discardableResult
    public func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool,
                                                trackPermissions: [ParticipantTrackPermission] = []) -> Promise<Void> {

        self.allParticipantsAllowed = allParticipantsAllowed
        self.trackPermissions = trackPermissions

        return sendTrackSubscriptionPermissions()
    }

    /// Sets and updates the metadata of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(metadata: String) -> Promise<Void> {
        // mutate state to set metadata and copy name from state
        let name = _state.mutate {
            $0.metadata = metadata
            return $0.name
        }
        return room.engine.signalClient.sendUpdateLocalMetadata(metadata, name: name)
    }

    /// Sets and updates the name of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(name: String) -> Promise<Void> {
        // mutate state to set name and copy metadata from state
        let metadata = _state.mutate {
            $0.name = name
            return $0.metadata
        }
        return room.engine.signalClient.sendUpdateLocalMetadata(metadata ?? "", name: name)
    }

    internal func sendTrackSubscriptionPermissions() -> Promise<Void> {

        guard room.engine._state.connectionState == .connected else {
            return Promise(())
        }

        return room.engine.signalClient.sendUpdateSubscriptionPermission(allParticipants: allParticipantsAllowed,
                                                                         trackPermissions: trackPermissions)
    }

    internal func onSubscribedQualitiesUpdate(trackSid: String, subscribedQualities: [Livekit_SubscribedQuality], subscribedCodecs: [Livekit_SubscribedCodec]) {

        if !room._state.options.dynacast {
            return
        }

        guard let pub = getTrackPublication(sid: trackSid),
              let track = pub.track as? LocalVideoTrack,
              let sender = track.rtpSender
        else { return }

        if !subscribedCodecs.isEmpty {
            setPublishingCodecs(subscribedCodecs, for: track)
        } else {
            // backward compatibility
            sender.setPublishingLayers(subscribedQualities: subscribedQualities)
        }
    }

    internal func setPublishingCodecs(_ codecs: [Livekit_SubscribedCodec], for track: LocalVideoTrack) {

        log("codecs: \(codecs.map { String(describing: $0) }), track: \(track)")

        assert(track.codec != nil, "track.codec is nil")

        // only enable simulcast codec for preference codec setted
        if track.codec == nil, let firstCodec = codecs.first, let sender = track.rtpSender {
            sender.setPublishingLayers(subscribedQualities: firstCodec.qualities)
            return
        }

        for subscribedCodec in codecs {

            guard let codec = VideoCodec(rawStringValue: subscribedCodec.codec) else {
                log("failed to decode VideoCodec type", .warning)
                continue
            }

            if track.codec == codec {

                track.rtpSender?.setPublishingLayers(subscribedQualities: subscribedCodec.qualities)

            } else {

                if let existingCodec = track.simulcastCodecs[codec] {
                    // existing
                    if let sender = existingCodec.sender {
                        sender.setPublishingLayers(subscribedQualities: subscribedCodec.qualities)
                    }
                } else {
                    // new
                    publish(additionalCodec: codec, for: track).then { _ in
                        self.log("did publish additional codec")
                    }.catch { error in
                        self.log("failed to publish additional codec, error: \(error)", .error)
                        assert(false, "failed to publish additional codec")
                    }
                }
            }
        }

    }

    internal override func set(permissions newValue: ParticipantPermissions) -> Bool {

        let didUpdate = super.set(permissions: newValue)

        if didUpdate {
            delegates.notify(label: { "participant.didUpdate permissions: \(newValue)" }) {
                $0.participant?(self, didUpdate: newValue)
            }
            room.delegates.notify(label: { "room.didUpdate permissions: \(newValue)" }) {
                $0.room?(self.room, participant: self, didUpdate: newValue)
            }
        }

        return didUpdate
    }
}

// MARK: - Session Migration

extension LocalParticipant {

    internal func publishedTracksInfo() -> [Livekit_TrackPublishedResponse] {
        _state.tracks.values.filter { $0.track != nil }
            .map { publication in
                Livekit_TrackPublishedResponse.with {
                    $0.cid = publication.track!.mediaTrack.trackId
                    if let info = publication.latestInfo {
                        $0.track = info
                    }
                }
            }
    }

    internal func republishTracks() -> Promise<Void> {

        let mediaTracks = _state.tracks.values.map { $0.track }.compactMap { $0 }

        return unpublishAll().then(on: queue) { () -> Promise<Void> in

            let promises = mediaTracks.map { track -> Promise<LocalTrackPublication>? in
                guard let track = track as? LocalTrack else { return nil }
                // don't re-publish muted tracks
                guard !track.muted else { return nil }
                return self.publish(track: track, publishOptions: track.publishOptions)
            }.compactMap { $0 }

            // TODO: use .all extension
            return all(on: self.queue, promises).then(on: self.queue) { _ in }
        }
    }
}

// MARK: - Simplified API

extension LocalParticipant {

    @discardableResult
    public func setCamera(enabled: Bool, captureOptions: CameraCaptureOptions? = nil, publishOptions: VideoPublishOptions? = nil) -> Promise<LocalTrackPublication?> {
        set(source: .camera, enabled: enabled, captureOptions: captureOptions, publishOptions: publishOptions)
    }

    @discardableResult
    public func setMicrophone(enabled: Bool, captureOptions: AudioCaptureOptions? = nil, publishOptions: AudioPublishOptions? = nil) -> Promise<LocalTrackPublication?> {
        set(source: .microphone, enabled: enabled, captureOptions: captureOptions, publishOptions: publishOptions)
    }

    /// Enable or disable screen sharing. This has different behavior depending on the platform.
    ///
    /// For iOS, this will use ``InAppScreenCapturer`` to capture in-app screen only due to Apple's limitation.
    /// If you would like to capture the screen when the app is in the background, you will need to create a "Broadcast Upload Extension".
    ///
    /// For macOS, this will use ``MacOSScreenCapturer`` to capture the main screen. ``MacOSScreenCapturer`` has the ability
    /// to capture other screens and windows. See ``MacOSScreenCapturer`` for details.
    ///
    /// For advanced usage, you can create a relevant ``LocalVideoTrack`` and call ``LocalParticipant/publishVideoTrack(track:publishOptions:)``.
    @discardableResult
    public func setScreenShare(enabled: Bool) -> Promise<LocalTrackPublication?> {
        set(source: .screenShareVideo, enabled: enabled)
    }

    public func set(source: Track.Source, enabled: Bool, captureOptions: CaptureOptions? = nil, publishOptions: PublishOptions? = nil) -> Promise<LocalTrackPublication?> {
        // attempt to get existing publication
        if let publication = getTrackPublication(source: source) as? LocalTrackPublication {
            if enabled {
                return publication.unmute().then(on: queue) { publication }
            } else {
                return publication.mute().then(on: queue) { publication }
            }
        } else if enabled {
            // try to create a new track
            if source == .camera {
                let localTrack = LocalVideoTrack.createCameraTrack(options: (captureOptions as? CameraCaptureOptions) ?? room._state.options.defaultCameraCaptureOptions)
                return publishVideoTrack(track: localTrack, publishOptions: publishOptions as? VideoPublishOptions).then(on: queue) { $0 }
            } else if source == .microphone {
                let localTrack = LocalAudioTrack.createTrack(options: (captureOptions as? AudioCaptureOptions) ?? room._state.options.defaultAudioCaptureOptions)
                return publishAudioTrack(track: localTrack, publishOptions: publishOptions as? AudioPublishOptions).then(on: queue) { $0 }
            } else if source == .screenShareVideo {
                #if os(iOS)
                var localTrack: LocalVideoTrack?
                let options = (captureOptions as? ScreenShareCaptureOptions) ?? room._state.options.defaultScreenShareCaptureOptions
                if options.useBroadcastExtension {
                    let screenShareExtensionId = Bundle.main.infoDictionary?[BroadcastScreenCapturer.kRTCScreenSharingExtension] as? String
                    RPSystemBroadcastPickerView.show(for: screenShareExtensionId,
                                                     showsMicrophoneButton: false)
                    localTrack = LocalVideoTrack.createBroadcastScreenCapturerTrack(options: options)
                } else {
                    localTrack = LocalVideoTrack.createInAppScreenShareTrack(options: options)
                }

                if let localTrack = localTrack {
                    return publishVideoTrack(track: localTrack, publishOptions: publishOptions as? VideoPublishOptions).then(on: queue) { $0 }
                }
                #elseif os(macOS)
                return MacOSScreenCapturer.mainDisplaySource().then(on: queue) { mainDisplay in
                    let track = LocalVideoTrack.createMacOSScreenShareTrack(source: mainDisplay,
                                                                            options: (captureOptions as? ScreenShareCaptureOptions) ?? self.room._state.options.defaultScreenShareCaptureOptions)
                    return self.publishVideoTrack(track: track, publishOptions: publishOptions as? VideoPublishOptions)
                }.then(on: queue) { $0 }
                #endif
            }
        }

        return Promise(nil)
    }
}

// MARK: - Simulcast codecs

extension LocalParticipant {

    internal func publish(additionalCodec codec: VideoCodec,
                          for track: LocalVideoTrack,
                          options: VideoPublishOptions? = nil) -> Promise<Void> {
        log()

        guard let publisher = room.engine.publisher else {
            return Promise(EngineError.state(message: "publisher is null"))
        }

        let options = options ?? (track._publishOptions as? VideoPublishOptions) ??  self.room._state.options.defaultVideoPublishOptions

        guard let dimensions = track.capturer.dimensions else {
            // shouldn't happen
            return Promise(EngineError.state(message: "Capturer's dimensions are nil"))
        }

        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: options,
                                                    isBackup: true)

        guard let simulcastTrack = try? track.addSimulcastTrack(for: codec, encodings: encodings) else {
            return Promise(EngineError.state(message: "addSimulcastTrack failed"))
        }

        let transInit = DispatchQueue.webRTC.sync { RTCRtpTransceiverInit() }
        transInit.direction = .sendOnly
        transInit.sendEncodings = encodings

        return Promise(on: queue) {
            simulcastTrack.track.start()
        }.then(on: queue) { (_: Bool) in
            // ...
            self.room.engine.signalClient.sendAddTrack(cid: simulcastTrack.track.mediaTrack.trackId,
                                                       sid: track.sid,
                                                       muted: track.muted,
                                                       type: track.kind.toPBType(),
                                                       source: track.source.toPBType()) {

                let simulcastCodec = Livekit_SimulcastCodec.with {
                    $0.codec = codec.rawStringValue ?? ""
                    $0.cid = simulcastTrack.track.mediaTrack.trackId
                    $0.enableSimulcastLayers = options.simulcast
                }
                $0.simulcastCodecs = [simulcastCodec]
                $0.width = UInt32(dimensions.width)
                $0.height = UInt32(dimensions.height)
                $0.layers = dimensions.videoLayers(for: encodings)

                // pass down
                return simulcastTrack
            }

        }.then(on: queue) { (simulcastTrack: LocalVideoTrack.SimulcastTrackInfo, trackInfo) -> Promise<(transceiver: RTCRtpTransceiver, trackInfo: Livekit_TrackInfo)> in

            self.log("[publish] server responded trackInfo: \(trackInfo)")

            // add transceiver to pc
            return publisher.addTransceiver(with: simulcastTrack.track.mediaTrack,
                                            transceiverInit: transInit).then(on: self.queue) { transceiver in
                                                // pass down trackInfo and created transceiver
                                                (transceiver, trackInfo)
                                            }

        }.then(on: queue) { (transceiver, _) in
            //
            transceiver.setPreferredVideoCodec(codec, exceptCodec: .av1)
            track.set(simulcastSender: transceiver.sender, for: codec, publisher: publisher)

            return self.room.engine.publisherShouldNegotiate()
        }.catch(on: queue) { error in

            self.log("[publish] failed \(simulcastTrack.track), error: \(error)", .error)

            // stop the track
            simulcastTrack.track.stop().catch(on: self.queue) { error in
                self.log("[publish] failed to stop track, error: \(error)", .error)
            }
        }
    }
}

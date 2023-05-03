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

                    let encodings = Utils.computeEncodings(dimensions: dimensions,
                                                           publishOptions: publishOptions,
                                                           isScreenShare: track.source == .screenShareVideo)

                    self.log("[publish] using encodings: \(encodings)")
                    transInit.sendEncodings = encodings

                    let videoLayers = dimensions.videoLayers(for: encodings)

                    self.log("[publish] using layers: \(videoLayers.map { String(describing: $0) }.joined(separator: ", "))")

                    populator.width = UInt32(dimensions.width)
                    populator.height = UInt32(dimensions.height)
                    populator.layers = videoLayers

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

            // store publishOptions used for this track
            track._publishOptions = publishOptions
            track.transceiver = transceiver

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
    
    public override func _unpublishAll(notify: Bool = true) async {
        await withUnsafeContinuation { continuation in
            _state.tracks.values.compactMap { $0 as? LocalTrackPublication }
                .map { unpublish(publication: $0, notify: notify) }
                .all(on: queue).then(on: queue) {
                    continuation.resume()
                }
        }
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

            guard let publisher = engine.publisher, let sender = track.sender else {
                return Promise(())
            }

            return publisher.removeTrack(sender).then(on: self.queue) {
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

    internal func sendTrackSubscriptionPermissions() -> Promise<Void> {

        guard room.engine._state.connectionState == .connected else {
            return Promise(())
        }

        return room.engine.signalClient.sendUpdateSubscriptionPermission(allParticipants: allParticipantsAllowed,
                                                                         trackPermissions: trackPermissions)
    }

    internal func onSubscribedQualitiesUpdate(trackSid: String, subscribedQualities: [Livekit_SubscribedQuality]) {

        if !room._state.options.dynacast {
            return
        }

        guard let pub = getTrackPublication(sid: trackSid),
              let track = pub.track as? LocalVideoTrack,
              let sender = track.transceiver?.sender
        else { return }

        let parameters = sender.parameters
        let encodings = parameters.encodings

        var hasChanged = false
        for quality in subscribedQualities {

            var rid: String
            switch quality.quality {
            case Livekit_VideoQuality.high: rid = "f"
            case Livekit_VideoQuality.medium: rid = "h"
            case Livekit_VideoQuality.low: rid = "q"
            default: continue
            }

            guard let encoding = encodings.first(where: { $0.rid == rid }) else {
                continue
            }

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                log("setting layer \(quality.quality) to \(quality.enabled)", .info)
            }
        }

        // Non simulcast streams don't have rids, handle here.
        if encodings.count == 1 && subscribedQualities.count >= 1 {
            let encoding = encodings[0]
            let quality = subscribedQualities[0]

            if encoding.isActive != quality.enabled {
                hasChanged = true
                encoding.isActive = quality.enabled
                log("setting layer \(quality.quality) to \(quality.enabled)", .info)
            }
        }

        if hasChanged {
            sender.parameters = parameters
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

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

import Combine
import Foundation

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

@objc
public class LocalParticipant: Participant {
    @objc
    public var localAudioTracks: [LocalTrackPublication] { audioTracks.compactMap { $0 as? LocalTrackPublication } }

    @objc
    public var localVideoTracks: [LocalTrackPublication] { videoTracks.compactMap { $0 as? LocalTrackPublication } }

    private var allParticipantsAllowed: Bool = true

    private var trackPermissions: [ParticipantTrackPermission] = []

    let rpcState = RpcStateManager()

    /// publish a new audio track to the Room
    @objc
    @discardableResult
    public func publish(audioTrack: LocalAudioTrack, options: AudioPublishOptions? = nil) async throws -> LocalTrackPublication {
        let result = try await _publishSerialRunner.run {
            try await self._publish(track: audioTrack, options: options)
        }
        guard let result else { throw LiveKitError(.invalidState) }
        return result
    }

    /// publish a new video track to the Room
    @objc
    @discardableResult
    public func publish(videoTrack: LocalVideoTrack, options: VideoPublishOptions? = nil) async throws -> LocalTrackPublication {
        let result = try await _publishSerialRunner.run {
            try await self._publish(track: videoTrack, options: options)
        }
        guard let result else { throw LiveKitError(.invalidState) }
        return result
    }

    @objc
    override public func unpublishAll(notify _notify: Bool = true) async {
        // Build a list of Publications
        let publications = _state.trackPublications.values.compactMap { $0 as? LocalTrackPublication }
        for publication in publications {
            do {
                try await unpublish(publication: publication, notify: _notify)
            } catch {
                log("Failed to unpublish track \(publication.sid) with error \(error)", .error)
            }
        }
    }

    /// unpublish an existing published track
    /// this will also stop the track
    @objc
    public func unpublish(publication: LocalTrackPublication, notify _notify: Bool = true) async throws {
        let room = try requireRoom()

        func _notifyDidUnpublish() async {
            guard _notify else { return }
            delegates.notify(label: { "localParticipant.didUnpublish \(publication)" }) {
                $0.participant?(self, didUnpublishTrack: publication)
            }
            room.delegates.notify(label: { "room.didUnpublish \(publication)" }) {
                $0.room?(room, participant: self, didUnpublishTrack: publication)
            }
        }

        // Remove the publication
        _state.mutate { $0.trackPublications.removeValue(forKey: publication.sid) }

        // If track is nil, only notify unpublish and return
        guard let track = publication.track as? LocalTrack else {
            return await _notifyDidUnpublish()
        }

        if let publisher = room._state.publisher, let sender = track._state.rtpSender {
            // Remove all simulcast senders...
            let simulcastSenders = track._state.read { Array($0.rtpSenderForCodec.values) }
            for simulcastSender in simulcastSenders {
                try await publisher.remove(track: simulcastSender)
            }
            // Remove main sender...
            try await publisher.remove(track: sender)
            // Mark re-negotiation required...
            try await room.publisherShouldNegotiate()
        }

        // Wait for track to stop (if required)
        if room._state.roomOptions.stopLocalTrackOnUnpublish {
            try await track.stop()
        }

        try await track.onUnpublish()

        await _notifyDidUnpublish()
    }

    /// Publish data to the other participants in the room
    ///
    /// Data is forwarded to each participant in the room. Each payload must not exceed 15k.
    /// - Parameters:
    ///   - data: Data to send
    ///   - options: Provide options with a ``DataPublishOptions`` class.
    @objc
    public func publish(data: Data, options: DataPublishOptions? = nil) async throws {
        let room = try requireRoom()
        let options = options ?? room._state.roomOptions.defaultDataPublishOptions

        guard let identityString = _state.identity?.stringValue else {
            throw LiveKitError(.invalidState, message: "identity is nil")
        }

        let userPacket = Livekit_UserPacket.with {
            $0.participantIdentity = identityString
            $0.payload = data
            $0.destinationIdentities = options.destinationIdentities.map(\.stringValue)
            $0.topic = options.topic ?? ""
        }

        try await room.send(userPacket: userPacket, kind: options.reliable ? .reliable : .lossy)
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
    @objc
    public func setTrackSubscriptionPermissions(allParticipantsAllowed: Bool,
                                                trackPermissions: [ParticipantTrackPermission] = []) async throws
    {
        self.allParticipantsAllowed = allParticipantsAllowed
        self.trackPermissions = trackPermissions

        try await sendTrackSubscriptionPermissions()
    }

    /// Sets and updates the metadata of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(metadata: String) async throws {
        let room = try requireRoom()
        try await room.signalClient.sendUpdateParticipant(metadata: metadata)
        _state.mutate { $0.metadata = metadata }
    }

    /// Sets and updates the name of the local participant.
    ///
    /// Note: this requires `CanUpdateOwnMetadata` permission encoded in the token.
    public func set(name: String) async throws {
        let room = try requireRoom()
        try await room.signalClient.sendUpdateParticipant(name: name)
        _state.mutate { $0.name = name }
    }

    public func set(attributes: [String: String]) async throws {
        let room = try requireRoom()
        try await room.signalClient.sendUpdateParticipant(attributes: attributes)
        _state.mutate { $0.attributes = attributes }
    }

    func sendTrackSubscriptionPermissions() async throws {
        let room = try requireRoom()
        guard room._state.connectionState == .connected else { return }

        try await room.signalClient.sendUpdateSubscriptionPermission(allParticipants: allParticipantsAllowed,
                                                                     trackPermissions: trackPermissions)
    }

    func _set(subscribedQualities qualities: [Livekit_SubscribedQuality], forTrackSid trackSid: Track.Sid) {
        guard let publication = trackPublications[trackSid],
              let track = publication.track as? LocalVideoTrack,
              let sender = track._state.rtpSender
        else { return }

        sender._set(subscribedQualities: qualities)
    }

    override func set(permissions newValue: ParticipantPermissions) -> Bool {
        guard let room = _room else { return false }
        let didUpdate = super.set(permissions: newValue)

        if didUpdate {
            delegates.notify(label: { "participant.didUpdatePermissions: \(newValue)" }) {
                $0.participant?(self, didUpdatePermissions: newValue)
            }
            room.delegates.notify(label: { "room.didUpdatePermissions: \(newValue)" }) {
                $0.room?(room, participant: self, didUpdatePermissions: newValue)
            }
        }

        return didUpdate
    }

    // MARK: - Broadcast Activation

    #if os(iOS)

    /// An optional hook called just after a broadcast starts.
    ///
    /// Returns a Boolean value indicating weather or not the broadcast should be
    /// published as a screen share track. This could be useful to present a confirmation dialog,
    /// returning `true` or `false` based on the user's response .
    ///
    public var broadcastStarted: (() async -> Bool)?

    private var isBroadcasting = false {
        didSet { broadcastStateChanged() }
    }

    private var cancellable = Set<AnyCancellable>()

    override init(room: Room, sid: Participant.Sid? = nil, identity: Participant.Identity? = nil) {
        super.init(room: room, sid: sid, identity: identity)

        BroadcastExtensionState
            .isBroadcasting
            .sink { [weak self] in
                guard let self else { return }
                self.isBroadcasting = $0
            }
            .store(in: &cancellable)
    }

    private func broadcastStateChanged() {
        guard isBroadcasting else {
            logger.debug("Broadcast stopped")
            return
        }
        logger.debug("Broadcast started")

        Task { [weak self] in
            guard let self else { return }
            let shouldPublish = await self.broadcastStarted?() ?? true
            guard shouldPublish else {
                logger.debug("Will not publish screen share track")
                return
            }
            do {
                try await self.setScreenShare(enabled: true)
            } catch {
                logger.error("Failed to enable screen share: \(error)")
            }
        }
    }
    #endif
}

// MARK: - Session Migration

extension LocalParticipant {
    func publishedTracksInfo() -> [Livekit_TrackPublishedResponse] {
        _state.trackPublications.values.filter { $0.track != nil }
            .map { publication in
                Livekit_TrackPublishedResponse.with {
                    $0.cid = publication.track!.mediaTrack.trackId
                    if let info = publication._state.latestInfo {
                        $0.track = info
                    }
                }
            }
    }

    func republishAllTracks() async throws {
        let mediaTracks = _state.trackPublications.values.map { $0.track as? LocalTrack }.compactMap { $0 }

        await unpublishAll()

        for mediaTrack in mediaTracks {
            // Don't re-publish muted tracks
            if mediaTrack.isMuted { continue }
            try await _publish(track: mediaTrack, options: mediaTrack.publishOptions)
        }
    }
}

// MARK: - Simplified API

public extension LocalParticipant {
    @objc
    @discardableResult
    func setCamera(enabled: Bool,
                   captureOptions: CameraCaptureOptions? = nil,
                   publishOptions: VideoPublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        try await set(source: .camera,
                      enabled: enabled,
                      captureOptions: captureOptions,
                      publishOptions: publishOptions)
    }

    @objc
    @discardableResult
    func setMicrophone(enabled: Bool,
                       captureOptions: AudioCaptureOptions? = nil,
                       publishOptions: AudioPublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        try await set(source: .microphone,
                      enabled: enabled,
                      captureOptions: captureOptions,
                      publishOptions: publishOptions)
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
    @objc
    @discardableResult
    func setScreenShare(enabled: Bool) async throws -> LocalTrackPublication? {
        try await set(source: .screenShareVideo, enabled: enabled)
    }

    @objc
    @discardableResult
    func set(source: Track.Source,
             enabled: Bool,
             captureOptions: CaptureOptions? = nil,
             publishOptions: TrackPublishOptions? = nil) async throws -> LocalTrackPublication?
    {
        try await _publishSerialRunner.run {
            let room = try self.requireRoom()

            // Try to get existing publication
            if let publication = self.getTrackPublication(source: source) as? LocalTrackPublication {
                if enabled {
                    try await publication.unmute()
                    return publication
                } else {
                    if source == .camera || source == .microphone {
                        try await publication.mute()
                    } else {
                        try await self.unpublish(publication: publication)
                    }
                    return publication
                }
            } else if enabled {
                // Try to create a new track
                if source == .camera {
                    let localTrack = LocalVideoTrack.createCameraTrack(options: (captureOptions as? CameraCaptureOptions) ?? room._state.roomOptions.defaultCameraCaptureOptions,
                                                                       reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
                    return try await self._publish(track: localTrack, options: publishOptions)
                } else if source == .microphone {
                    let localTrack = LocalAudioTrack.createTrack(options: (captureOptions as? AudioCaptureOptions) ?? room._state.roomOptions.defaultAudioCaptureOptions,
                                                                 reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
                    return try await self._publish(track: localTrack, options: publishOptions)
                } else if source == .screenShareVideo {
                    #if os(iOS)
                    let localTrack: LocalVideoTrack
                    let options = (captureOptions as? ScreenShareCaptureOptions) ?? room._state.roomOptions.defaultScreenShareCaptureOptions
                    if options.useBroadcastExtension {
                        guard self.isBroadcasting else {
                            await BroadcastExtensionState.requestActivation()
                            return nil
                        }
                        // Wait until broadcasting to publish track
                        localTrack = LocalVideoTrack.createBroadcastScreenCapturerTrack(options: options)
                    } else {
                        localTrack = LocalVideoTrack.createInAppScreenShareTrack(options: options)
                    }
                    return try await self._publish(track: localTrack, options: publishOptions)
                    #elseif os(macOS)
                    if #available(macOS 12.3, *) {
                        let mainDisplay = try await MacOSScreenCapturer.mainDisplaySource()
                        let track = LocalVideoTrack.createMacOSScreenShareTrack(source: mainDisplay,
                                                                                options: (captureOptions as? ScreenShareCaptureOptions) ?? room._state.roomOptions.defaultScreenShareCaptureOptions,
                                                                                reportStatistics: room._state.roomOptions.reportRemoteTrackStatistics)
                        return try await self._publish(track: track, options: publishOptions)
                    }
                    #endif
                }
            }

            return nil
        }
    }
}

// MARK: - Simulcast codecs

extension LocalParticipant {
    // Publish additional (backup) codec when requested by server
    func publish(additionalVideoCodec subscribedCodec: Livekit_SubscribedCodec,
                 for localTrackPublication: LocalTrackPublication) async throws
    {
        let room = try requireRoom()

        let videoCodec = try subscribedCodec.toVideoCodec()

        log("[Publish/Backup] Additional video codec: \(videoCodec)...")

        guard let track = localTrackPublication.track as? LocalVideoTrack else {
            throw LiveKitError(.invalidState, message: "Track is nil")
        }

        if !videoCodec.isBackup {
            throw LiveKitError(.invalidState, message: "Attempted to publish a non-backup video codec as backup")
        }

        let publisher = try room.requirePublisher()

        let publishOptions = (track.publishOptions as? VideoPublishOptions) ?? room._state.roomOptions.defaultVideoPublishOptions

        // Should be already resolved...
        let dimensions = try await track.capturer.dimensionsCompleter.wait()

        let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                    publishOptions: publishOptions,
                                                    overrideVideoCodec: videoCodec)

        log("[Publish/Backup] Using encodings: \(encodings.map { $0.toDebugString() }.joined(separator: ", "))")

        // Add transceiver first...

        let transInit = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpTransceiverInit() }
        transInit.direction = .sendOnly
        transInit.sendEncodings = encodings

        // Add transceiver to publisher pc...
        let transceiver = try await publisher.addTransceiver(with: track.mediaTrack, transceiverInit: transInit)
        log("[Publish] Added transceiver...")

        // Set codec...
        transceiver.set(preferredVideoCodec: videoCodec)

        let sender = transceiver.sender

        // Request a new track to the server
        let addTrackResult = try await room.signalClient.sendAddTrack(cid: sender.senderId,
                                                                      name: track.name,
                                                                      type: track.kind.toPBType(),
                                                                      source: track.source.toPBType())
        {
            $0.sid = localTrackPublication.sid.stringValue
            $0.simulcastCodecs = [
                Livekit_SimulcastCodec.with { sc in
                    sc.cid = sender.senderId
                    sc.codec = videoCodec.id
                },
            ]

            $0.layers = dimensions.videoLayers(for: encodings)
        }

        log("[Publish] server responded trackInfo: \(addTrackResult.trackInfo)")

        sender._set(subscribedQualities: subscribedCodec.qualities)

        // Attach multi-codec sender...
        track._state.mutate { $0.rtpSenderForCodec[videoCodec] = sender }

        try await room.publisherShouldNegotiate()
    }
}

// MARK: - Helper

extension [Livekit_SubscribedQuality] {
    /// Find the highest quality in the array
    var highest: Livekit_VideoQuality {
        reduce(Livekit_VideoQuality.off) { maxQuality, subscribedQuality in
            subscribedQuality.enabled && subscribedQuality.quality > maxQuality ? subscribedQuality.quality : maxQuality
        }
    }
}

// MARK: - Private

private extension LocalParticipant {
    @discardableResult
    private func _publish(track: LocalTrack, options: TrackPublishOptions? = nil) async throws -> LocalTrackPublication {
        log("[publish] \(track) options: \(String(describing: options ?? nil))...", .info)

        let room = try requireRoom()
        let publisher = try room.requirePublisher()

        guard _state.trackPublications.values.first(where: { $0.track === track }) == nil else {
            throw LiveKitError(.invalidState, message: "This track has already been published.")
        }

        guard track is LocalVideoTrack || track is LocalAudioTrack else {
            throw LiveKitError(.invalidState, message: "Unknown LocalTrack type")
        }

        // Try to start the Track
        try await track.start()
        // Starting the Track could be time consuming especially for camera etc.
        // Check cancellation after track starts.
        try Task.checkCancellation()

        do {
            var dimensions: Dimensions? // Only for Video

            if let track = track as? LocalVideoTrack {
                // Wait for Dimensions...
                log("[Publish] Waiting for dimensions to resolve...")
                dimensions = try await track.capturer.dimensionsCompleter.wait()
            }

            var publishName: String? = nil

            let populatorFunc: SignalClient.AddTrackRequestPopulator<LKRTCRtpTransceiverInit> = { populator in

                let transInit = DispatchQueue.liveKitWebRTC.sync { LKRTCRtpTransceiverInit() }
                transInit.direction = .sendOnly

                if let track = track as? LocalVideoTrack {
                    guard let dimensions else {
                        throw LiveKitError(.capturerDimensionsNotResolved, message: "VideoCapturer dimensions are not resolved")
                    }

                    self.log("[publish] computing encode settings with dimensions: \(dimensions)...")

                    let publishOptions = (options as? VideoPublishOptions) ?? room._state.roomOptions.defaultVideoPublishOptions
                    publishName = publishOptions.name

                    let encodings = Utils.computeVideoEncodings(dimensions: dimensions,
                                                                publishOptions: publishOptions,
                                                                isScreenShare: track.source == .screenShareVideo)

                    self.log("[publish] Using encodings: \(encodings.map { $0.toDebugString() }.joined(separator: ", "))")
                    transInit.sendEncodings = encodings

                    let videoLayers = dimensions.videoLayers(for: encodings)

                    self.log("[publish] using layers: \(videoLayers.map { String(describing: $0) }.joined(separator: ", "))")

                    var simulcastCodecs: [Livekit_SimulcastCodec] = [
                        // Always add first codec...
                        Livekit_SimulcastCodec.with {
                            $0.cid = track.mediaTrack.trackId
                            if let preferredCodec = publishOptions.preferredCodec {
                                $0.codec = preferredCodec.id
                            }
                        },
                    ]

                    if let backupCodec = publishOptions.preferredBackupCodec {
                        // Add backup codec to simulcast codecs...
                        let lkSimulcastCodec = Livekit_SimulcastCodec.with {
                            $0.cid = ""
                            $0.codec = backupCodec.id
                        }
                        simulcastCodecs.append(lkSimulcastCodec)
                    }

                    populator.width = UInt32(dimensions.width)
                    populator.height = UInt32(dimensions.height)
                    populator.layers = videoLayers
                    populator.simulcastCodecs = simulcastCodecs

                    self.log("[publish] requesting add track to server with \(populator)...")

                } else if track is LocalAudioTrack {
                    // additional params for Audio
                    let publishOptions = (options as? AudioPublishOptions) ?? room._state.roomOptions.defaultAudioPublishOptions
                    publishName = publishOptions.name

                    populator.disableDtx = !publishOptions.dtx

                    let encoding = publishOptions.encoding ?? AudioEncoding.presetMusic

                    self.log("[publish] maxBitrate: \(encoding.maxBitrate)")

                    transInit.sendEncodings = [
                        RTC.createRtpEncodingParameters(encoding: encoding),
                    ]
                }

                if let streamName = options?.streamName {
                    // Set stream name if specified in options
                    populator.stream = streamName
                }

                return transInit
            }

            // Request a new track to the server
            let addTrackResult = try await room.signalClient.sendAddTrack(cid: track.mediaTrack.trackId,
                                                                          name: publishName ?? track.name,
                                                                          type: track.kind.toPBType(),
                                                                          source: track.source.toPBType(),
                                                                          encryption: room.e2eeManager?.e2eeOptions.encryptionType.toPBType() ?? .none,
                                                                          populatorFunc)

            log("[Publish] server responded trackInfo: \(addTrackResult.trackInfo)")

            // Add transceiver to pc
            let transceiver = try await publisher.addTransceiver(with: track.mediaTrack, transceiverInit: addTrackResult.result)
            log("[Publish] Added transceiver: \(addTrackResult.trackInfo)...")

            do {
                try await track.onPublish()

                // Store publishOptions used for this track...
                track._state.mutate { $0.lastPublishOptions = options }

                // Attach sender to track...
                await track.set(transport: publisher, rtpSender: transceiver.sender)

                if track is LocalVideoTrack {
                    if let firstCodecMime = addTrackResult.trackInfo.codecs.first?.mimeType,
                       let firstVideoCodec = try? VideoCodec.from(mimeType: firstCodecMime)
                    {
                        log("[Publish] First video codec: \(firstVideoCodec)")
                        track._state.mutate { $0.videoCodec = firstVideoCodec }
                    }

                    let publishOptions = (options as? VideoPublishOptions) ?? room._state.roomOptions.defaultVideoPublishOptions

                    let setDegradationPreference: NSNumber? = {
                        if let rtcDegradationPreference = publishOptions.degradationPreference.toRTCType() {
                            return NSNumber(value: rtcDegradationPreference.rawValue)
                        } else if track.source == .screenShareVideo || publishOptions.simulcast {
                            return NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
                        }
                        return nil
                    }()

                    if let setDegradationPreference {
                        log("[publish] set degradationPreference to \(setDegradationPreference)")
                        let params = transceiver.sender.parameters
                        params.degradationPreference = setDegradationPreference
                        // Changing params directly doesn't work so we need to update params and set it back to sender.parameters
                        transceiver.sender.parameters = params
                    }

                    if let preferredCodec = publishOptions.preferredCodec {
                        transceiver.set(preferredVideoCodec: preferredCodec)
                    }
                }

                try await room.publisherShouldNegotiate()
                try Task.checkCancellation()

            } catch {
                // Rollback
                await track.set(transport: nil, rtpSender: nil)
                try await publisher.remove(track: transceiver.sender)
                // Rethrow
                throw error
            }

            let publication = LocalTrackPublication(info: addTrackResult.trackInfo, participant: self)
            await publication.set(track: track)

            add(publication: publication)

            // Notify didPublish
            delegates.notify(label: { "localParticipant.didPublish \(publication)" }) {
                $0.participant?(self, didPublishTrack: publication)
            }
            room.delegates.notify(label: { "localParticipant.didPublish \(publication)" }) {
                $0.room?(room, participant: self, didPublishTrack: publication)
            }

            log("[publish] success \(publication)", .info)

            return publication
        } catch {
            log("[publish] failed \(track), error: \(error)", .error)
            // Stop track when publish fails
            try await track.stop()
            // Rethrow
            throw error
        }
    }
}

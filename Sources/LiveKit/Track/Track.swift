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

import WebRTC
import Promises

public class Track: MulticastDelegate<TrackDelegate> {

    public static let cameraName = "camera"
    public static let microphoneName = "microphone"
    public static let screenShareVideoName = "screen_share"
    public static let screenShareAudioName = "screen_share_audio"

    public enum Kind {
        case audio
        case video
        case none
    }

    public enum TrackState {
        case stopped
        case started
    }

    public enum Source {
        case unknown
        case camera
        case microphone
        case screenShareVideo
        case screenShareAudio
    }

    public let kind: Track.Kind
    public let source: Track.Source
    public internal(set) var name: String
    public internal(set) var sid: Sid?
    public let mediaTrack: RTCMediaStreamTrack
    public private(set) var muted: Bool = false
    public internal(set) var transceiver: RTCRtpTransceiver?
    public internal(set) var stats: TrackStats?
    public var sender: RTCRtpSender? {
        return transceiver?.sender
    }

    /// Dimensions of the video (only if video track)
    public var dimensions: Dimensions? {
        state.dimensions
    }

    /// The last video frame received for this track
    public private(set) var videoFrame: RTCVideoFrame?

    public private(set) var trackState: TrackState = .stopped {
        didSet {
            guard oldValue != trackState else { return }
            didUpdateState()
        }
    }

    internal let videoViews = NSHashTable<VideoView>.weakObjects()

    internal struct State {
        var dimensions: Dimensions?
        var videoFrame: RTCVideoFrame?
    }

    internal var state = StateSync(State())

    init(name: String, kind: Kind, source: Source, track: RTCMediaStreamTrack) {
        self.name = name
        self.kind = kind
        self.source = source
        mediaTrack = track
    }

    deinit {
        log()
    }

    // returns true if updated state
    public func start() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard self.trackState != .started else {
                // already started
                return false
            }

            self.trackState = .started
            return true
        }
    }

    // returns true if updated state
    public func stop() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard self.trackState != .stopped else {
                // already stopped
                return false
            }

            self.trackState = .stopped
            return true
        }
    }

    internal func enable() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard !self.mediaTrack.isEnabled else {
                // already enabled
                return false
            }

            self.mediaTrack.isEnabled = true
            return true
        }
    }

    internal func disable() -> Promise<Bool> {

        Promise(on: .sdk) { () -> Bool in

            guard self.mediaTrack.isEnabled else {
                // already disabled
                return false
            }

            self.mediaTrack.isEnabled = false
            return true
        }
    }

    internal func didUpdateState() {
        //
    }

    internal func set(muted: Bool,
                      shouldNotify: Bool = true,
                      shouldSendSignal: Bool = false) {

        guard muted != self.muted else { return }
        self.muted = muted

        if muted {
            // clear video frame cache if muted
            set(videoFrame: nil)
        }

        if shouldNotify {
            notify { $0.track(self, didUpdate: muted, shouldSendSignal: shouldSendSignal) }
        }
    }
}

// MARK: - Internal

internal extension Track {

    func set(stats newValue: TrackStats) {
        guard self.stats != newValue else { return }
        self.stats = newValue
        notify { $0.track(self, didUpdate: newValue) }
    }
}

// MARK: - Internal

internal extension Track {

    // returns true when value is updated
    func set(dimensions newValue: Dimensions?) -> Bool {
        guard self.state.dimensions != newValue else { return false }

        state.mutate { $0.dimensions = newValue }

        guard let videoTrack = self as? VideoTrack else { return true }
        notify { $0.track(videoTrack, didUpdate: newValue) }

        return true
    }

    // returns true when value is updated
    func set(videoFrame newValue: RTCVideoFrame?) {
        guard self.state.videoFrame != newValue else { return }

        state.mutate { $0.videoFrame = newValue }
    }
}

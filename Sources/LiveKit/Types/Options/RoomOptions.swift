import Foundation

public struct RoomOptions {
    // default options for capturing
    public let defaultCameraCaptureOptions: CameraCaptureOptions
    public let defaultScreenShareCaptureOptions: ScreenShareCaptureOptions

    public let defaultAudioCaptureOptions: AudioCaptureOptions
    // default options for publishing
    public let defaultVideoPublishOptions: VideoPublishOptions
    public let defaultAudioPublishOptions: AudioPublishOptions

    /// AdaptiveStream lets LiveKit automatically manage quality of subscribed
    /// video tracks to optimize for bandwidth and CPU.
    /// When attached video elements are visible, it'll choose an appropriate
    /// resolution based on the size of largest video element it's attached to.
    ///
    /// When none of the video elements are visible, it'll temporarily pause
    /// the data flow until they are visible again.
    ///
    public let adaptiveStream: Bool

    /// Dynamically pauses video layers that are not being consumed by any subscribers,
    /// significantly reducing publishing CPU and bandwidth usage.
    ///
    public let dynacast: Bool

    public let stopLocalTrackOnUnpublish: Bool

    /// Automatically suspend(mute) video tracks when the app enters background and
    /// resume(unmute) when the app enters foreground again.
    public let suspendLocalVideoTracksInBackground: Bool

    /// **Experimental**
    /// Report ``TrackStats`` every second to ``TrackDelegate`` for each local and remote tracks.
    /// This may consume slightly more CPU resources.
    public let reportStats: Bool

    public init(defaultCameraCaptureOptions: CameraCaptureOptions = CameraCaptureOptions(),
                defaultScreenShareCaptureOptions: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                defaultAudioCaptureOptions: AudioCaptureOptions = AudioCaptureOptions(),
                defaultVideoPublishOptions: VideoPublishOptions = VideoPublishOptions(),
                defaultAudioPublishOptions: AudioPublishOptions = AudioPublishOptions(),
                adaptiveStream: Bool = false,
                dynacast: Bool = false,
                stopLocalTrackOnUnpublish: Bool = true,
                suspendLocalVideoTracksInBackground: Bool = true,
                reportStats: Bool = false) {

        self.defaultCameraCaptureOptions = defaultCameraCaptureOptions
        self.defaultScreenShareCaptureOptions = defaultScreenShareCaptureOptions
        self.defaultAudioCaptureOptions = defaultAudioCaptureOptions
        self.defaultVideoPublishOptions = defaultVideoPublishOptions
        self.defaultAudioPublishOptions = defaultAudioPublishOptions
        self.adaptiveStream = adaptiveStream
        self.dynacast = dynacast
        self.stopLocalTrackOnUnpublish = stopLocalTrackOnUnpublish
        self.suspendLocalVideoTracksInBackground = suspendLocalVideoTracksInBackground
        self.reportStats = reportStats
    }
}

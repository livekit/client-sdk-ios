import Foundation

public struct RoomOptions {
    // default options for capturing
    public var defaultVideoCaptureOptions: VideoCaptureOptions
    public var defaultAudioCaptureOptions: AudioCaptureOptions
    // default options for publishing
    public var defaultVideoPublishOptions: VideoPublishOptions
    public var defaultAudioPublishOptions: AudioPublishOptions

    /// AdaptiveStream lets LiveKit automatically manage quality of subscribed
    /// video tracks to optimize for bandwidth and CPU.
    /// When attached video elements are visible, it'll choose an appropriate
    /// resolution based on the size of largest video element it's attached to.
    ///
    /// When none of the video elements are visible, it'll temporarily pause
    /// the data flow until they are visible again.
    ///
    public var adaptiveStream: Bool
    
    
    /// Dynamically pauses video layers that are not being consumed by any subscribers,
    /// significantly reducing publishing CPU and bandwidth usage.
    ///
    public var dynacast: Bool

    public var stopLocalTrackOnUnpublish: Bool

    public init(defaultVideoCaptureOptions: VideoCaptureOptions = VideoCaptureOptions(),
                defaultAudioCaptureOptions: AudioCaptureOptions = AudioCaptureOptions(),
                defaultVideoPublishOptions: VideoPublishOptions = VideoPublishOptions(),
                defaultAudioPublishOptions: AudioPublishOptions = AudioPublishOptions(),
                adaptiveStream: Bool = false,
                dynacast: Bool = false,
                stopLocalTrackOnUnpublish: Bool = true) {

        self.defaultVideoCaptureOptions = defaultVideoCaptureOptions
        self.defaultAudioCaptureOptions = defaultAudioCaptureOptions
        self.defaultVideoPublishOptions = defaultVideoPublishOptions
        self.defaultAudioPublishOptions = defaultAudioPublishOptions
        self.adaptiveStream = adaptiveStream
        self.dynacast = dynacast
        self.stopLocalTrackOnUnpublish = stopLocalTrackOnUnpublish
    }
}

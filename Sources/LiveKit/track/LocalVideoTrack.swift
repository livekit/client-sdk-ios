import WebRTC
import Promises

extension CMVideoDimensions {

    func toLKType() -> Dimensions {
        Dimensions(width: Int(width), height: Int(height))
    }
}

public class LocalVideoTrack: VideoTrack {

    public var capturer: RTCVideoCapturer
    public var source: RTCVideoSource
    public let dimensions: Dimensions

    public typealias CreateCapturerResult = (capturer: ReplayKitCapturer, source: RTCVideoSource)

    init(rtcTrack: RTCVideoTrack,
         capturer: RTCVideoCapturer,
         source: RTCVideoSource,
         name: String,
         dimensions: Dimensions) {

        self.capturer = capturer
        self.source = source
        self.dimensions = dimensions
        super.init(rtcTrack: rtcTrack, name: name)
    }

    private static func createCapturer(options: LocalVideoTrackOptions = LocalVideoTrackOptions(),
                                       interceptor: VideoCaptureInterceptor? = nil) throws -> (
                                        rtcTrack: RTCVideoTrack,
                                        capturer: RTCCameraVideoCapturer,
                                        source: RTCVideoSource,
                                        selectedDimensions: Dimensions) {

        let source: RTCVideoCapturerDelegate
        let output: RTCVideoSource
        if let interceptor = interceptor {
            source = interceptor
            output = interceptor.output
        } else {
            let videoSource = Engine.factory.videoSource()
            source = videoSource
            output = videoSource
        }

        let capturer = RTCCameraVideoCapturer(delegate: source)
        let possibleDevice = RTCCameraVideoCapturer.captureDevices().first {
            // TODO: FaceTime Camera for macOS uses .unspecified
            $0.position == options.position || $0.position == .unspecified
        }

        guard let device = possibleDevice else {
            throw TrackError.mediaError("No \(options.position) video capture devices available.")
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let (targetWidth, targetHeight) = (options.captureParameter.dimensions.width,
                                           options.captureParameter.dimensions.height)

        var currentDiff = Int.max
        var selectedFormat: AVCaptureDevice.Format = formats[0]
        var selectedDimension: CMVideoDimensions?
        for format in formats {
            if options.captureFormat == format {
                selectedFormat = format
                break
            }
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(targetWidth - Int(dimension.width)) + abs(targetHeight - Int(dimension.height))
            if diff < currentDiff {
                selectedFormat = format
                currentDiff = diff
                selectedDimension = dimension
            }
        }

        guard let selectedDimension = selectedDimension else {
            throw TrackError.mediaError("could not get dimensions")
        }

        let fps = options.captureParameter.encoding.maxFps

        // discover FPS limits
        var minFps = 60
        var maxFps = 0
        for fpsRange in selectedFormat.videoSupportedFrameRateRanges {
            minFps = min(minFps, Int(fpsRange.minFrameRate))
            maxFps = max(maxFps, Int(fpsRange.maxFrameRate))
        }
        if fps < minFps || fps > maxFps {
            throw TrackError.mediaError("requested framerate is unsupported (\(minFps)-\(maxFps))")
        }

        logger.info("starting capture with \(device), format: \(selectedFormat), fps: \(fps)")
        capturer.startCapture(with: device, format: selectedFormat, fps: Int(fps))

        let rtcTrack = Engine.factory.videoTrack(with: output, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true

        return (rtcTrack, capturer, output, selectedDimension.toLKType())
    }

    public func restartTrack(options: LocalVideoTrackOptions = LocalVideoTrackOptions()) throws {

        let result = try LocalVideoTrack.createCapturer(options: options)

        // Stop previous capturer
        if let capturer = capturer as? RTCCameraVideoCapturer {
            capturer.stopCapture()
        }

        capturer = result.capturer

        source = result.source

        // TODO: Stop previous mediaTrack
        mediaTrack.isEnabled = false
        mediaTrack = result.rtcTrack

        // Set the new track
        sender?.track = result.rtcTrack
    }

    public static func createReplayKitCapturer() -> CreateCapturerResult {
        let source = Engine.factory.videoSource()
        return (capturer: ReplayKitCapturer(source: source),
                source: source)
    }

    public static func createTrack(name: String,
                                   createCapturerResult: CreateCapturerResult) -> LocalVideoTrack {

        let rtcTrack = Engine.factory.videoTrack(with: createCapturerResult.source, trackId: UUID().uuidString)
        rtcTrack.isEnabled = true

        #if !os(macOS)
        let dimensions = Dimensions(
            width: Int(UIScreen.main.bounds.size.width * UIScreen.main.scale),
            height: Int(UIScreen.main.bounds.size.height * UIScreen.main.scale)
        )
        #else
        let videoSize = Dimensions(width: 0, height: 0)
        #endif

        return LocalVideoTrack(
            rtcTrack: rtcTrack,
            capturer: createCapturerResult.capturer,
            source: createCapturerResult.source,
            name: name,
            dimensions: videoSize
        )
    }

    @discardableResult
    public override func stop() -> Promise<Void> {
        Promise<Void> { resolve, _ in
            // if the capturer is a RTCCameraVideoCapturer,
            // wait for it to fully stop.
            if let capturer = self.capturer as? RTCCameraVideoCapturer {
                capturer.stopCapture { resolve(()) }
            } else {
                resolve(())
            }
        }.then {
            super.stop()
        }
    }
    // MARK: High level methods

    public static func createReplayKitTrack(name: String) -> LocalVideoTrack {
        return createTrack(name: name, createCapturerResult: createReplayKitCapturer())
    }

    public static func createCameraTrack(name: String,
                                         options: LocalVideoTrackOptions = LocalVideoTrackOptions(),
                                         interceptor: VideoCaptureInterceptor? = nil) throws -> LocalVideoTrack {

        let result = try createCapturer(options: options, interceptor: interceptor)
        return LocalVideoTrack(
            rtcTrack: result.rtcTrack,
            capturer: result.capturer,
            source: result.source,
            name: name,
            dimensions: result.selectedDimensions
        )
    }
}

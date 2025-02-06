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

import AVFoundation
import Foundation

#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

#if os(macOS)

@available(macOS 12.3, *)
public class MacOSScreenCapturer: VideoCapturer {
    private let capturer = RTC.createVideoCapturer()

    // TODO: Make it possible to change dynamically
    public let captureSource: MacOSScreenCaptureSource?

    /// The ``ScreenShareCaptureOptions`` used for this capturer.
    public let options: ScreenShareCaptureOptions

    struct State {
        // SCStream
        var scStream: SCStream?
        // Cached frame for resending to maintain minimum of 1 fps
        var lastFrame: LKRTCVideoFrame?
        var resendTimer: Task<Void, Error>?
    }

    private var _screenCapturerState = StateSync(State())

    init(delegate: LKRTCVideoCapturerDelegate, captureSource: MacOSScreenCaptureSource, options: ScreenShareCaptureOptions) {
        self.captureSource = captureSource
        self.options = options
        super.init(delegate: delegate)
    }

    override public func startCapture() async throws -> Bool {
        let didStart = try await super.startCapture()

        // Already started
        guard didStart else { return false }

        guard let captureSource else {
            log("captureSource is nil", .error)
            throw LiveKitError(.invalidState, message: "captureSource is nil")
        }

        let filter: SCContentFilter
        if let windowSource = captureSource as? MacOSWindow,
           let nativeWindowSource = windowSource.nativeType as? SCWindow
        {
            filter = SCContentFilter(desktopIndependentWindow: nativeWindowSource)
        } else if let displaySource = captureSource as? MacOSDisplay,
                  let content = displaySource.scContent as? SCShareableContent,
                  let nativeDisplay = displaySource.nativeType as? SCDisplay
        {
            let excludedApps = !options.includeCurrentApplication ? content.applications.filter { app in
                Bundle.main.bundleIdentifier == app.bundleIdentifier
            } : []

            filter = SCContentFilter(display: nativeDisplay, excludingApplications: excludedApps, exceptingWindows: [])
        } else {
            log("Unable to resolve SCContentFilter", .error)
            throw LiveKitError(.invalidState, message: "Unable to resolve SCContentFilter")
        }

        let configuration = SCStreamConfiguration()

        let mainDisplay = CGMainDisplayID()
        // try to capture in max resolution
        configuration.width = CGDisplayPixelsWide(mainDisplay) * 2
        configuration.height = CGDisplayPixelsHigh(mainDisplay) * 2

        configuration.scalesToFit = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = options.showCursor

        if #available(macOS 13.0, *) {
            configuration.capturesAudio = options.appAudio
        }

        // Why does SCStream hold strong reference to delegate?
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        if #available(macOS 13.0, *) {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
        }
        try await stream.startCapture()

        _screenCapturerState.mutate { $0.scStream = stream }

        return true
    }

    override public func stopCapture() async throws -> Bool {
        let didStop = try await super.stopCapture()

        // Already stopped
        guard didStop else { return false }

        guard let stream = _screenCapturerState.read({ $0.scStream }) else {
            throw LiveKitError(.invalidState, message: "SCStream is nil")
        }

        // Stop resending paused frames
        _screenCapturerState.mutate {
            $0.resendTimer?.cancel()
            $0.resendTimer = nil
        }

        try await stream.stopCapture()
        try stream.removeStreamOutput(self, type: .screen)

        _screenCapturerState.mutate {
            $0.scStream = nil
        }

        return true
    }

    // Common capture func
    private func capture(_ sampleBuffer: CMSampleBuffer, contentRect: CGRect, scaleFactor: CGFloat = 1.0) {
        // Get the pixel buffer that contains the image data.
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let timeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(timeStamp) * Double(NSEC_PER_SEC))

        let sourceDimensions = Dimensions(width: Int32((contentRect.width * scaleFactor).rounded(.down)),
                                          height: Int32((contentRect.height * scaleFactor).rounded(.down)))

        let targetDimensions = sourceDimensions
            .aspectFit(size: options.dimensions.max)
            .toEncodeSafeDimensions()

        let rtcPixelBuffer = LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer,
                                                adaptedWidth: targetDimensions.width,
                                                adaptedHeight: targetDimensions.height,
                                                cropWidth: sourceDimensions.width,
                                                cropHeight: sourceDimensions.height,
                                                cropX: Int32(contentRect.origin.x * scaleFactor),
                                                cropY: Int32(contentRect.origin.y * scaleFactor))

        let rtcFrame = LKRTCVideoFrame(buffer: rtcPixelBuffer,
                                       rotation: ._0,
                                       timeStampNs: timeStampNs)

        // Cache last frame
        _screenCapturerState.mutate {
            $0.lastFrame = rtcFrame
        }

        capture(frame: rtcFrame, capturer: capturer, options: options)
    }
}

// MARK: - Frame resend logic

@available(macOS 12.3, *)
extension MacOSScreenCapturer {
    private func _capturePreviousFrame() async throws {
        // Must be .started
        guard case .started = captureState else {
            log("CaptureState is not .started, resend timer should not trigger.", .warning)
            return
        }

        log("No movement detected, resending frame...", .trace)

        guard let frame = _screenCapturerState.read({ $0.lastFrame }) else { return }

        // create a new frame with new time stamp
        let newFrame = LKRTCVideoFrame(buffer: frame.buffer,
                                       rotation: frame.rotation,
                                       timeStampNs: Self.createTimeStampNs())

        // Feed frame to WebRTC
        capture(frame: newFrame, capturer: capturer, options: options)
    }
}

// MARK: - SCStreamOutput

@available(macOS 12.3, *)
extension MacOSScreenCapturer: SCStreamOutput {
    public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of outputType: SCStreamOutputType)
    {
        guard case .started = captureState else {
            log("Skipping capture since captureState is not .started")
            return
        }

        // Return early if the sample buffer is invalid.
        guard sampleBuffer.isValid else { return }

        if case .audio = outputType {
            if let pcm = sampleBuffer.toAVAudioPCMBuffer() {
                let node = AudioManager.shared.mixer.appAudioNode
                if let engine = node.engine, engine.isRunning {
                    node.scheduleBuffer(pcm)
                    if !node.isPlaying {
                        node.play()
                    }
                }
            }
        } else if case .screen = outputType {
            // Retrieve the array of metadata attachments from the sample buffer.
            guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                                 createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                let attachments = attachmentsArray.first else { return }

            // Validate the status of the frame. If it isn't `.complete`, return nil.
            guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRawValue),
                  status == .complete else { return }

            // Retrieve the content rectangle, scale, and scale factor.
            guard let contentRectDict = attachments[.contentRect],
                  let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary),
                  // let contentScale = attachments[.contentScale] as? CGFloat,
                  let scaleFactor = attachments[.scaleFactor] as? CGFloat else { return }

            // Schedule resend timer
            let newTimer = Task.detached(priority: .utility) { [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: UInt64(1 * 1_000_000_000))
                    if Task.isCancelled { break }
                    guard let self else { break }
                    try await self._capturePreviousFrame()
                }
            }

            _screenCapturerState.mutate {
                $0.resendTimer?.cancel()
                $0.resendTimer = newTimer
            }

            capture(sampleBuffer, contentRect: contentRect, scaleFactor: scaleFactor)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

@available(macOS 12.3, *)
public extension LocalVideoTrack {
    @objc
    static func createMacOSScreenShareTrack(name: String = Track.screenShareVideoName,
                                            source: MacOSScreenCaptureSource,
                                            options: ScreenShareCaptureOptions = ScreenShareCaptureOptions(),
                                            reportStatistics: Bool = false) -> LocalVideoTrack
    {
        let videoSource = RTC.createVideoSource(forScreenShare: true)
        let capturer = MacOSScreenCapturer(delegate: videoSource, captureSource: source, options: options)
        return LocalVideoTrack(name: name,
                               source: .screenShareVideo,
                               capturer: capturer,
                               videoSource: videoSource,
                               reportStatistics: reportStatistics)
    }
}

@objc
public enum MacOSScreenShareSourceType: Int, Sendable {
    case any
    case display
    case window
}

@objc
public protocol MacOSScreenCaptureSource: AnyObject {}

@objc
public class MacOSRunningApplication: NSObject {
    public let processID: pid_t
    public let bundleIdentifier: String
    public let applicationName: String

    public let nativeType: Any?

    @available(macOS 12.3, *)
    init?(from scRunningApplication: SCRunningApplication?) {
        guard let scRunningApplication else { return nil }
        bundleIdentifier = scRunningApplication.bundleIdentifier
        applicationName = scRunningApplication.applicationName
        processID = scRunningApplication.processID
        nativeType = scRunningApplication
    }

    init?(from processID: pid_t?) {
        guard let processID,
              let app = NSRunningApplication(processIdentifier: processID) else { return nil }

        self.processID = processID
        bundleIdentifier = app.bundleIdentifier ?? ""
        applicationName = app.localizedName ?? ""
        nativeType = nil
    }
}

@objc
public class MacOSWindow: NSObject, MacOSScreenCaptureSource {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let title: String?
    public let windowLayer: Int
    public let owningApplication: MacOSRunningApplication?
    public let isOnScreen: Bool
    public let nativeType: Any?

    @available(macOS 12.3, *)
    init(from scWindow: SCWindow) {
        windowID = scWindow.windowID
        frame = scWindow.frame
        title = scWindow.title
        windowLayer = scWindow.windowLayer
        owningApplication = MacOSRunningApplication(from: scWindow.owningApplication)
        isOnScreen = scWindow.isOnScreen
        nativeType = scWindow
    }

    init(from windowID: CGWindowID) {
        self.windowID = windowID

        let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID)! as Array

        guard let info = list.first as? NSDictionary else {
            fatalError("Window information not available")
        }

        frame = {
            guard let dict = info.object(forKey: kCGWindowBounds) as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dict)
            else {
                //
                return CGRect()
            }

            return frame
        }()

        title = info.object(forKey: kCGWindowName) as? String
        windowLayer = (info.object(forKey: kCGWindowLayer) as? NSNumber)?.intValue ?? 0
        owningApplication = MacOSRunningApplication(from: (info.object(forKey: kCGWindowOwnerPID) as? NSNumber)?.int32Value as? pid_t)
        isOnScreen = (info.object(forKey: kCGWindowIsOnscreen) as? NSNumber)?.boolValue ?? false
        nativeType = nil
    }
}

@objc
public class MacOSDisplay: NSObject, MacOSScreenCaptureSource {
    public let displayID: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let frame: CGRect

    public let nativeType: Any?
    public let scContent: Any?

    @available(macOS 12.3, *)
    init(from scDisplay: SCDisplay, content: SCShareableContent) {
        displayID = scDisplay.displayID
        width = scDisplay.width
        height = scDisplay.height
        frame = scDisplay.frame
        nativeType = scDisplay
        scContent = content
    }

    // legacy
    init(from displayID: CGDirectDisplayID) {
        self.displayID = displayID
        width = CGDisplayPixelsWide(displayID)
        height = CGDisplayPixelsHigh(displayID)
        frame = CGRect(x: 0,
                       y: 0,
                       width: width,
                       height: height)
        nativeType = nil
        scContent = nil
    }
}

// MARK: - Filter extension

public extension MacOSWindow {
    /// Source is related to current running application
    @objc
    var isCurrentApplication: Bool {
        owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}

// MARK: - Enumerate sources

@available(macOS 12.3, *)
public extension MacOSScreenCapturer {
    internal static let queue = DispatchQueue(label: "LiveKitSDK.MacOSScreenCapturer.sources", qos: .default)

    /// Convenience method to get a ``MacOSDisplay`` of the main display.
    @objc
    static func mainDisplaySource() async throws -> MacOSDisplay {
        let displaySources = try await sources(for: .display)

        guard let source = displaySources.compactMap({ $0 as? MacOSDisplay }).first(where: { $0.displayID == CGMainDisplayID() }) else {
            throw LiveKitError(.invalidState, message: "Main display source not found")
        }

        return source
    }

    /// Enumerate ``MacOSDisplay`` or ``MacOSWindow`` sources.
    @objc
    static func sources(for type: MacOSScreenShareSourceType, includeCurrentApplication: Bool = false) async throws -> [MacOSScreenCaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.map { MacOSDisplay(from: $0, content: content) }
        let windows = content.windows
            // remove windows from this app
            .filter { includeCurrentApplication || $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
            // remove windows that don't have an associated bundleIdentifier
            .filter { $0.owningApplication?.bundleIdentifier != nil }
            // remove windows that windowLayer isn't 0
            .filter { $0.windowLayer == 0 }
            // remove windows that are unusually small
            .filter { $0.frame.size.width >= 100 && $0.frame.size.height >= 100 }
            // sort the windows by app name
            .sorted { $0.owningApplication?.applicationName ?? "" < $1.owningApplication?.applicationName ?? "" }
            .map { MacOSWindow(from: $0) }

        switch type {
        case .any: return displays + windows
        case .display: return displays
        case .window: return windows
        }
    }

    @objc
    static func displaySources() async throws -> [MacOSDisplay] {
        let result = try await sources(for: .display)
        // Cast
        return result.compactMap { $0 as? MacOSDisplay }
    }

    @objc
    static func windowSources() async throws -> [MacOSWindow] {
        let result = try await sources(for: .window)
        // Cast
        return result.compactMap { $0 as? MacOSWindow }
    }
}

#endif

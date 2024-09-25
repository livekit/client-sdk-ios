/*
 * Copyright 2024 LiveKit
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
import MetalKit

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

/// A ``NativeViewType`` that conforms to ``RTCVideoRenderer``.
typealias NativeRendererView = LKRTCVideoRenderer & Mirrorable & NativeViewType

@objc
public class VideoView: NativeView, Loggable {
    // MARK: - MulticastDelegate

    public let delegates = MulticastDelegate<VideoViewDelegate>(label: "VideoViewDelegate")

    // MARK: - Static

    static let mirrorTransform = CATransform3DMakeScale(-1.0, 1.0, 1.0)
    private static let _freezeDetectThreshold = 2.0

    /// Specifies how to render the video withing the ``VideoView``'s bounds.
    @objc
    public enum LayoutMode: Int, Codable {
        /// Video will be fully visible within the ``VideoView``.
        case fit
        /// Video will fully cover up the ``VideoView``.
        case fill
    }

    @objc
    public enum MirrorMode: Int, Codable {
        /// Will mirror if the track is a front facing camera track.
        case auto
        case off
        case mirror
    }

    @objc
    public enum RenderMode: Int, Codable {
        case auto
        case metal
        case sampleBuffer
    }

    @objc
    public enum TransitionMode: Int, Codable {
        case none
        case crossDissolve
        case flip
    }

    /// ``LayoutMode-swift.enum`` of the ``VideoView``.
    @objc
    public var layoutMode: LayoutMode {
        get { _state.layoutMode }
        set { _state.mutate { $0.layoutMode = newValue } }
    }

    /// Flips the video horizontally, useful for local VideoViews.
    @objc
    public var mirrorMode: MirrorMode {
        get { _state.mirrorMode }
        set { _state.mutate { $0.mirrorMode = newValue } }
    }

    @objc
    public var renderMode: RenderMode {
        get { _state.renderMode }
        set { _state.mutate { $0.renderMode = newValue } }
    }

    /// Force video to be rotated to preferred ``VideoRotation``.
    public var rotationOverride: VideoRotation? {
        get { _state.rotationOverride }
        set { _state.mutate { $0.rotationOverride = newValue } }
    }

    /// Calls addRenderer and/or removeRenderer internally for convenience.
    @objc
    public weak var track: VideoTrack? {
        get { _state.track as? VideoTrack }
        set {
            _state.mutate {
                // reset states if track updated
                if !Self.track($0.track as? VideoTrack, isEqualWith: newValue) {
                    $0.renderDate = nil
                    $0.didRenderFirstFrame = false
                    $0.isRendering = false
                    $0.rendererSize = nil
                }
                $0.track = newValue
            }
        }
    }

    /// If set to false, rendering will be paused temporarily. Useful for performance optimizations with UICollectionViewCell etc.
    @objc
    public var isEnabled: Bool {
        get { _state.isEnabled }
        set { _state.mutate { $0.isEnabled = newValue } }
    }
    
    @objc
    public var isPaused: Bool {
        get { _state.isPaused }
        set { _state.mutate { $0.isPaused = newValue } }
    }
    
    private var pausedVideoFrame: VideoFrame?

    @objc
    override public var isHidden: Bool {
        get { _state.isHidden }
        set {
            _state.mutate { $0.isHidden = newValue }
            Task.detached { @MainActor in
                super.isHidden = newValue
            }
        }
    }

    /// Currently, only for iOS
    @objc
    public var transitionMode: TransitionMode {
        get { _state.transitionMode }
        set { _state.mutate { $0.transitionMode = newValue } }
    }

    @objc
    public var transitionDuration: TimeInterval {
        get { _state.transitionDuration }
        set { _state.mutate { $0.transitionDuration = newValue } }
    }

    @objc
    public var isPinchToZoomEnabled: Bool {
        get { _state.pinchToZoomOptions.isEnabled }
        set { _state.mutate { $0.pinchToZoomOptions.insert(.zoomIn) } }
    }

    @objc
    public var isAutoZoomResetEnabled: Bool {
        get { _state.pinchToZoomOptions.contains(.resetOnRelease) }
        set { _state.mutate { $0.pinchToZoomOptions.insert(.resetOnRelease) } }
    }

    public var pinchToZoomOptions: PinchToZoomOptions {
        get { _state.pinchToZoomOptions }
        set { _state.mutate { $0.pinchToZoomOptions = newValue } }
    }

    @objc
    public var isDebugMode: Bool {
        get { _state.isDebugMode }
        set { _state.mutate { $0.isDebugMode = newValue } }
    }

    @objc
    public var isRendering: Bool { _state.isRendering }

    @objc
    public var didRenderFirstFrame: Bool { _state.didRenderFirstFrame }

    /// Access the internal AVSampleBufferDisplayLayer used for rendering.
    /// This is only available when the renderer is using AVSampleBufferDisplayLayer.
    /// Recommended to be accessed from main thread.
    public var avSampleBufferDisplayLayer: AVSampleBufferDisplayLayer? {
        guard let nr = _primaryRenderer as? SampleBufferVideoRenderer else { return nil }
        return nr.sampleBufferDisplayLayer
    }

    // MARK: - Internal

    enum RenderTarget {
        case primary
        case secondary
    }

    struct State {
        weak var track: Track?
        var isEnabled: Bool = true
        var isPaused: Bool = false
        var isHidden: Bool = false

        // layout related
        var viewSize: CGSize
        var rendererSize: CGSize?
        var didLayout: Bool = false
        var layoutMode: LayoutMode = .fill
        var mirrorMode: MirrorMode = .auto
        var renderMode: RenderMode = .auto
        var rotationOverride: VideoRotation?

        var isDebugMode: Bool = false

        // Render states
        var renderDate: Date?
        var didRenderFirstFrame: Bool = false
        var isRendering: Bool = false

        // Transition related
        var renderTarget: RenderTarget = .primary
        var isSwapping: Bool = false
        var remainingRenderCountBeforeSwap: Int = 0 // Number of frames to be rendered on secondary until swap is initiated
        var transitionMode: TransitionMode = .crossDissolve
        var transitionDuration: TimeInterval = 0.3

        var pinchToZoomOptions: PinchToZoomOptions = []

        // Only used for rendering local tracks
        var captureOptions: VideoCaptureOptions? = nil
        var captureDevice: AVCaptureDevice? = nil

        var lastRenderedFrame: VideoFrame?
        
        // whether if current state should be rendering
        var shouldRender: Bool {
            track != nil && isEnabled && !isHidden && !isPaused
        }
    }

    var _state: StateSync<State>

    // MARK: - Private

    private var _primaryRenderer: NativeRendererView?
    private var _secondaryRenderer: NativeRendererView?
    private var _debugTextView: TextView?

    // used for stats timer
    private let _renderTimer = AsyncTimer(interval: 0.1)
    private let _fpsTimer = AsyncTimer(interval: 1)
    private var _currentFPS: Int = 0
    private var _frameCount: Int = 0

    #if os(iOS)
    private lazy var _pinchGestureRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(_handlePinchGesture(_:)))
    // This should be thread safe so it's not required to be guarded by the lock
    var _pinchStartZoomFactor: CGFloat = 0.0
    #endif

    override public init(frame: CGRect = .zero) {
        // initial state
        _state = StateSync(State(viewSize: frame.size))

        super.init(frame: frame)

        if !Thread.current.isMainThread {
            log("Must be called on main thread", .error)
        }

        #if os(iOS)
        clipsToBounds = true
        #endif

        // trigger events when state mutates
        _state.onDidMutate = { [weak self] newState, oldState in

            guard let self else { return }

            self.log("Mutating in main thread: \(Thread.current.isMainThread)", .trace)

            let shouldRenderDidUpdate = newState.shouldRender != oldState.shouldRender
            let renderModeDidUpdate = newState.renderMode != oldState.renderMode

            // track was swapped
            let trackDidUpdate = !Self.track(oldState.track as? VideoTrack, isEqualWith: newState.track as? VideoTrack)

            // Enter .main only if the following conditions are met...
            if trackDidUpdate || shouldRenderDidUpdate || renderModeDidUpdate {
                // Execute on main thread
                self.mainSyncOrAsync {
                    var didReCreateNativeRenderer = false

                    if trackDidUpdate || shouldRenderDidUpdate {
                        // clean up old track
                        if let track = oldState.track as? VideoTrack {
                            track.remove(videoRenderer: self)
                            
                            // avoid destroying and re-creating the renderers when the video is paused
                            if !newState.isPaused {
                                if let r = self._primaryRenderer {
                                    r.removeFromSuperview()
                                    self._primaryRenderer = nil
                                }
                                
                                if let r = self._secondaryRenderer {
                                    r.removeFromSuperview()
                                    self._secondaryRenderer = nil
                                }
                            }
                        }

                        // set new track
                        if let track = newState.track as? VideoTrack, newState.shouldRender {
                            // re-create renderer on main thread
                            let nr = self.recreatePrimaryRenderer(for: newState.renderMode)
                            didReCreateNativeRenderer = true

                            track.add(videoRenderer: self)

                            if let frame = track._state.videoFrame {
                                self.log("rendering cached frame track: \(String(describing: track._state.sid))")
                                nr.renderFrame(frame.toRTCType())
                                self.setNeedsLayout()
                            }
                        }
                    }

                    if renderModeDidUpdate, !didReCreateNativeRenderer {
                        let nr = self.recreatePrimaryRenderer(for: newState.renderMode)
                        
                        // re-render last rendered frame before pause
                        if let frame = newState.lastRenderedFrame, newState.isPaused {
                            self.log("rendering last rendered frame before pause")
                            nr.renderFrame(frame.toRTCType())
                            self.setNeedsLayout()
                        }
                    }
                }
            }

            // isRendering updated
            if newState.isRendering != oldState.isRendering {
                self.log("isRendering \(oldState.isRendering) -> \(newState.isRendering)")
                self.delegates.notify(label: { "videoView.didUpdate isRendering: \(newState.isRendering)" }) {
                    $0.videoView?(self, didUpdate: newState.isRendering)
                }
            }

            // viewSize updated
            if newState.viewSize != oldState.viewSize {
                self.delegates.notify {
                    $0.videoView?(self, didUpdate: newState.viewSize)
                }
            }

            // toggle MTKView's isPaused property
            // https://developer.apple.com/documentation/metalkit/mtkview/1535973-ispaused
            // https://developer.apple.com/forums/thread/105252
            // nativeRenderer.asMetalView?.isPaused = !shouldAttach

            // layout is required if any of the following vars mutate
            if newState.isDebugMode != oldState.isDebugMode ||
                newState.layoutMode != oldState.layoutMode ||
                newState.mirrorMode != oldState.mirrorMode ||
                newState.renderMode != oldState.renderMode ||
                newState.rotationOverride != oldState.rotationOverride ||
                newState.didRenderFirstFrame != oldState.didRenderFirstFrame ||
                newState.renderTarget != oldState.renderTarget ||
                shouldRenderDidUpdate || trackDidUpdate
            {
                // must be on main
                Task.detached { @MainActor in
                    self.setNeedsLayout()
                }
            }

            #if os(iOS)
            if newState.pinchToZoomOptions != oldState.pinchToZoomOptions {
                Task.detached { @MainActor in
                    self._pinchGestureRecognizer.isEnabled = newState.pinchToZoomOptions.isEnabled
                    self._rampZoomFactorToAllowedBounds(options: newState.pinchToZoomOptions)
                }
            }
            #endif

            if newState.isDebugMode != oldState.isDebugMode {
                // fps timer
                if newState.isDebugMode {
                    self._fpsTimer.restart()
                } else {
                    self._fpsTimer.cancel()
                }
            }
        }

        _fpsTimer.setTimerBlock { @MainActor [weak self] in
            guard let self else { return }

            self._currentFPS = self._frameCount
            self._frameCount = 0

            self.setNeedsLayout()
        }

        _renderTimer.setTimerBlock { [weak self] in
            guard let self else { return }

            if self._state.isRendering, let renderDate = self._state.renderDate {
                let diff = Date().timeIntervalSince(renderDate)
                if diff >= Self._freezeDetectThreshold {
                    self._state.mutate { $0.isRendering = false }
                }
            }
        }

        _renderTimer.restart()

        #if os(iOS)
        // Add pinch gesture recognizer
        addGestureRecognizer(_pinchGestureRecognizer)
        _pinchGestureRecognizer.isEnabled = _state.pinchToZoomOptions.isEnabled
        #endif
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        log(nil, .trace)
    }

    override public func performLayout() {
        super.performLayout()

        let state = _state.copy()

        defer {
            let viewSize = frame.size

            if state.viewSize != viewSize || !state.didLayout {
                // mutate if required
                _state.mutate {
                    $0.viewSize = viewSize
                    $0.didLayout = true
                }
            }
        }

        if state.isDebugMode {
            let _trackSid = state.track?.sid
            let _dimensions = state.track?.dimensions ?? .zero
            let _didRenderFirstFrame = state.didRenderFirstFrame ? "true" : "false"
            let _isRendering = state.isRendering ? "true" : "false"
            let _renderMode = String(describing: state.renderMode)
            let _viewCount = state.track?._state.videoRenderers.allObjects.count ?? 0
            let debugView = ensureDebugTextView()
            debugView.text = "#\(hashValue)\n" + "\(String(describing: _trackSid))\n" + "\(_dimensions.width)x\(_dimensions.height)\n" + "isEnabled: \(isEnabled)\n" + "firstFrame: \(_didRenderFirstFrame)\n" + "isRendering: \(_isRendering)\n" + "renderMode: \(_renderMode)\n" + "viewCount: \(_viewCount)\n" + "FPS: \(_currentFPS)\n"
            debugView.frame = bounds
            #if os(iOS)
            debugView.layer.borderColor = (state.shouldRender ? UIColor.green : UIColor.red).withAlphaComponent(0.5).cgColor
            debugView.layer.borderWidth = 3
            #elseif os(macOS)
            debugView.wantsLayer = true
            debugView.layer!.borderColor = (state.shouldRender ? NSColor.green : NSColor.red).withAlphaComponent(0.5).cgColor
            debugView.layer!.borderWidth = 3
            #endif
            bringSubviewToFront(debugView)
        } else {
            if let debugView = _debugTextView {
                debugView.removeFromSuperview()
                _debugTextView = nil
            }
        }

        guard let track = state.track else {
            log("track is nil, cannot layout without track", .warning)
            return
        }

        // dimensions are required to continue computation
        guard let dimensions = track._state.dimensions else {
            // log("dimensions are nil, cannot layout without dimensions, track: \(track)", .debug)
            return
        }

        var size = frame.size
        let wDim = CGFloat(dimensions.width)
        let hDim = CGFloat(dimensions.height)
        let wRatio = size.width / wDim
        let hRatio = size.height / hDim

        if state.layoutMode == .fill ? hRatio > wRatio : hRatio < wRatio {
            size.width = size.height / hDim * wDim
        } else if state.layoutMode == .fill ? wRatio > hRatio : wRatio < hRatio {
            size.height = size.width / wDim * hDim
        }

        let rendererFrame = CGRect(x: -((size.width - frame.size.width) / 2),
                                   y: -((size.height - frame.size.height) / 2),
                                   width: size.width,
                                   height: size.height)

        if state.rendererSize != rendererFrame.size {
            // mutate if required
            _state.mutate { $0.rendererSize = rendererFrame.size }
        }

        if let _primaryRenderer {
            _primaryRenderer.frame = rendererFrame

            #if os(iOS) || os(macOS)
            if let mtlVideoView = _primaryRenderer as? LKRTCMTLVideoView {
                if let rotationOverride = state.rotationOverride {
                    mtlVideoView.rotationOverride = NSNumber(value: rotationOverride.rawValue)
                } else {
                    mtlVideoView.rotationOverride = nil
                }
            }
            #endif

            if let _secondaryRenderer {
                _secondaryRenderer.frame = rendererFrame
                _secondaryRenderer.set(isMirrored: _shouldMirror())
            } else {
                _primaryRenderer.set(isMirrored: _shouldMirror())
            }
        }
    }
}

// MARK: - Private

private extension VideoView {
    private func ensureDebugTextView() -> TextView {
        if let view = _debugTextView { return view }
        let view = TextView()
        addSubview(view)
        _debugTextView = view
        return view
    }

    @discardableResult
    func recreatePrimaryRenderer(for renderMode: VideoView.RenderMode) -> NativeRendererView {
        if !Thread.current.isMainThread { log("Must be called on main thread", .error) }

        // create a new rendererView
        let newView = VideoView.createNativeRendererView(for: renderMode)
        addSubview(newView)

        // keep the old rendererView
        let oldView = _primaryRenderer
        _primaryRenderer = newView

        if let oldView {
            // copy frame from old renderer
            newView.frame = oldView.frame
            // remove if existed
            oldView.removeFromSuperview()
        }

        if let r = _secondaryRenderer {
            r.removeFromSuperview()
            _secondaryRenderer = nil
        }

        return newView
    }

    @discardableResult
    func ensureSecondaryRenderer() -> NativeRendererView? {
        if !Thread.current.isMainThread { log("Must be called on main thread", .error) }
        // Return if already exists
        if let _secondaryRenderer { return _secondaryRenderer }
        // Primary is required
        guard let _primaryRenderer else { return nil }

        // Create renderer blow primary
        let newView = VideoView.createNativeRendererView(for: _state.renderMode)
        insertSubview(newView, belowSubview: _primaryRenderer)

        // Copy frame from primary renderer
        newView.frame = _primaryRenderer.frame
        // Store reference
        _secondaryRenderer = newView

        return newView
    }

    func _shouldMirror() -> Bool {
        switch _state.mirrorMode {
        case .auto: return _state.captureDevice?.facingPosition == .front
        case .off: return false
        case .mirror: return true
        }
    }
}

// MARK: - RTCVideoRenderer

extension VideoView: VideoRenderer {
    public var isAdaptiveStreamEnabled: Bool {
        _state.read { $0.didLayout && !$0.isHidden && $0.isEnabled }
    }

    public var adaptiveStreamSize: CGSize {
        _state.rendererSize ?? .zero
    }

    public func set(size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let nr = self._primaryRenderer else { return }
            nr.setSize(size)
        }
    }

    public func render(frame: VideoFrame, captureDevice: AVCaptureDevice?, captureOptions: VideoCaptureOptions?) {
        let state = _state.copy()

        // prevent any extra rendering if already !isEnabled etc.
        guard state.shouldRender, let pr = _primaryRenderer else {
            log("canRender is false, skipping render...")
            return
        }

        let rotation = state.rotationOverride ?? frame.rotation
        let dimensions = frame.dimensions.apply(rotation: rotation.toRTCType())

        guard dimensions.isRenderSafe else {
            log("skipping render for dimension \(dimensions)", .warning)
            // renderState.insert(.didSkipUnsafeFrame)
            return
        }

        // Update track dimensions
        track?.set(dimensions: dimensions)

        let newState = _state.mutate {
            // Keep previous capture position
            let oldCaptureDevicePosition = $0.captureDevice?.position

            $0.captureDevice = captureDevice
            $0.captureOptions = captureOptions
            $0.didRenderFirstFrame = true
            $0.isRendering = true
            $0.renderDate = Date()
            $0.lastRenderedFrame = frame

            // Update renderTarget if capture position changes
            if let oldCaptureDevicePosition, oldCaptureDevicePosition != captureDevice?.position {
                $0.renderTarget = .secondary
                $0.remainingRenderCountBeforeSwap = $0.transitionMode == .none ? 3 : 0
            }

            return $0
        }

        switch newState.renderTarget {
        case .primary:
            pr.renderFrame(frame.toRTCType())
            // Cache last rendered frame
            track?.set(videoFrame: frame)

        case .secondary:
            if let sr = _secondaryRenderer {
                // Unfortunately there is not way to know if rendering has completed before initiating the swap.
                sr.renderFrame(frame.toRTCType())

                let shouldSwap = _state.mutate {
                    let oldIsSwapping = $0.isSwapping
                    if $0.remainingRenderCountBeforeSwap <= 0 {
                        $0.isSwapping = true
                    } else {
                        $0.remainingRenderCountBeforeSwap -= 1
                    }
                    return !oldIsSwapping && $0.isSwapping
                }

                if shouldSwap {
                    Task.detached { @MainActor in
                        // Swap views
                        self._swapRendererViews()
                        // Swap completed, back to primary rendering
                        self._state.mutate {
                            $0.renderTarget = .primary
                            $0.isSwapping = false
                        }
                    }
                }
            } else {
                Task.detached { @MainActor in
                    // Create secondary renderer and render first frame
                    if let sr = self.ensureSecondaryRenderer() {
                        sr.renderFrame(frame.toRTCType())
                    }
                }
            }
        }

        if _state.isDebugMode {
            Task.detached { @MainActor in
                self._frameCount += 1
            }
        }
    }

    private func _swapRendererViews() {
        if !Thread.current.isMainThread { log("Must be called on main thread", .error) }

        // Ensure secondary renderer exists
        guard let sr = _secondaryRenderer else { return }

        let block = {
            // Remove the secondary view from its superview
            sr.removeFromSuperview()
            // Swap the references
            self._primaryRenderer = sr
            // Add the new primary view to the superview
            if let pr = self._primaryRenderer {
                self.addSubview(pr)
            }
            self._secondaryRenderer = nil
        }

        // Currently only for iOS
        #if os(iOS)
        let (mode, duration, position) = _state.read { ($0.transitionMode, $0.transitionDuration, $0.captureDevice?.facingPosition) }
        if let transitionOption = mode.toAnimationOption(fromPosition: position) {
            UIView.transition(with: self, duration: duration, options: transitionOption, animations: block, completion: nil)
        } else {
            block()
        }
        #else
        block()
        #endif
    }
}

// MARK: - Internal

extension VideoView {
    static func track(_ track1: VideoTrack?, isEqualWith track2: VideoTrack?) -> Bool {
        // equal if both tracks are nil
        if track1 == nil, track2 == nil { return true }
        // not equal if a single track is nil
        guard let track1, let track2 else { return false }
        // use isEqual
        return track1.isEqual(track2)
    }
}

// MARK: - Static helper methods

extension VideoView {
    public static func isMetalAvailable() -> Bool {
        #if os(iOS)
        MTLCreateSystemDefaultDevice() != nil
        #elseif os(macOS)
        // same method used with WebRTC
        !MTLCopyAllDevices().isEmpty
        #else
        false
        #endif
    }

    static func createNativeRendererView(for renderMode: VideoView.RenderMode) -> NativeRendererView {
        #if os(iOS) || os(macOS)
        if case .sampleBuffer = renderMode {
            logger.log("Using AVSampleBufferDisplayLayer for VideoView's Renderer", type: VideoView.self)
            return SampleBufferVideoRenderer()
        } else {
            logger.log("Using RTCMTLVideoView for VideoView's Renderer", type: VideoView.self)
            let result = LKRTCMTLVideoView()

            #if os(iOS)
            result.contentMode = .scaleAspectFit
            result.videoContentMode = .scaleAspectFit
            #endif

            // extra checks for MTKView
            if let mtkView = result.findMTKView() {
                #if os(iOS)
                mtkView.contentMode = .scaleAspectFit
                #elseif os(macOS)
                mtkView.layerContentsPlacement = .scaleProportionallyToFit
                #endif
                // ensure it's capable of rendering 60fps
                // https://developer.apple.com/documentation/metalkit/mtkview/1536027-preferredframespersecond
                logger.log("preferredFramesPerSecond = 60", type: VideoView.self)
                mtkView.preferredFramesPerSecond = 60
            }

            return result
        }
        #else
        return SampleBufferVideoRenderer()
        #endif
    }
}

// MARK: - Access MTKView

#if !os(visionOS) || compiler(>=6.0)
extension NativeViewType {
    func findMTKView() -> MTKView? {
        subviews.compactMap { $0 as? MTKView }.first
    }
}
#endif

#if os(macOS)
extension NSView {
    //
    // Converted to Swift + NSView from:
    // http://stackoverflow.com/a/10700737
    //
    func set(anchorPoint: CGPoint) {
        if let layer {
            var newPoint = CGPoint(x: bounds.size.width * anchorPoint.x,
                                   y: bounds.size.height * anchorPoint.y)
            var oldPoint = CGPoint(x: bounds.size.width * layer.anchorPoint.x,
                                   y: bounds.size.height * layer.anchorPoint.y)

            newPoint = newPoint.applying(layer.affineTransform())
            oldPoint = oldPoint.applying(layer.affineTransform())

            var position = layer.position

            position.x -= oldPoint.x
            position.x += newPoint.x

            position.y -= oldPoint.y
            position.y += newPoint.y

            layer.position = position
            layer.anchorPoint = anchorPoint
        }
    }
}
#endif

#if os(iOS) || os(macOS)
extension LKRTCMTLVideoView: Mirrorable {
    func set(isMirrored: Bool) {
        if isMirrored {
            #if os(macOS)
            // This is required for macOS
            wantsLayer = true
            set(anchorPoint: CGPoint(x: 0.5, y: 0.5))
            layer!.sublayerTransform = VideoView.mirrorTransform
            #elseif os(iOS)
            layer.transform = VideoView.mirrorTransform
            #endif
        } else {
            #if os(macOS)
            layer?.sublayerTransform = CATransform3DIdentity
            #elseif os(iOS)
            layer.transform = CATransform3DIdentity
            #endif
        }
    }
}
#endif

private extension VideoView {
    func mainSyncOrAsync(operation: @escaping () -> Void) {
        if Thread.current.isMainThread {
            operation()
        } else {
            Task.detached { @MainActor in
                operation()
            }
        }
    }
}

#if os(iOS)
extension VideoView.TransitionMode {
    func toAnimationOption(fromPosition position: AVCaptureDevice.Position? = nil) -> UIView.AnimationOptions? {
        switch self {
        case .flip:
            if position == .back {
                return .transitionFlipFromLeft
            }
            return .transitionFlipFromRight
        case .crossDissolve: return .transitionCrossDissolve
        default: return nil
        }
    }
}
#endif

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
@testable import LiveKit
import XCTest

extension XCTestCase {
    // Creates a LocalVideoTrack with BufferCapturer, generates frames for approx 30 seconds
    @available(iOS 15.0, *)
    func createSampleVideoTrack(targetFps: Int = 30, _ onCapture: @escaping (CMSampleBuffer) -> Void) async throws -> (Task<Void, any Error>) {
        // Sample video
        let url = URL(string: "https://storage.unxpected.co.jp/public/sample-videos/ocean-1080p.mp4")!

        print("Downloading sample video from \(url)...")
        // TODO: Backport for iOS13
        let (downloadedLocalUrl, _) = try await URLSession.shared.download(from: url)

        // Move the file to a new temporary location with a more descriptive name, if desired
        let tempLocalUrl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        try FileManager.default.moveItem(at: downloadedLocalUrl, to: tempLocalUrl)

        print("Opening \(tempLocalUrl) with asset reader...")
        let asset = AVAsset(url: tempLocalUrl)
        let assetReader = try AVAssetReader(asset: asset)

        guard let track = asset.tracks(withMediaType: .video).first else {
            XCTFail("No video track found in sample video file")
            fatalError()
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        assetReader.add(trackOutput)

        // Start reading...
        guard assetReader.startReading() else {
            XCTFail("Could not start reading the asset.")
            fatalError()
        }

        let readBufferTask = Task.detached {
            let frameDuration = UInt64(1_000_000_000 / targetFps)
            while !Task.isCancelled, assetReader.status == .reading, let sampleBuffer = trackOutput.copyNextSampleBuffer() {
                onCapture(sampleBuffer)
                // Sleep for the frame duration to regulate to ~30 fps
                try await Task.sleep(nanoseconds: frameDuration)
            }
        }

        return readBufferTask
    }
}

class VideoTrackWatcher: TrackDelegate, VideoRenderer {
    // MARK: - Public

    typealias OnDidRenderFirstFrame = (_ sid: String) -> Void
    public var didRenderFirstFrame: Bool { _state.didRenderFirstFrame }

    private struct State {
        var didRenderFirstFrame: Bool = false
        var expectationsForDimensions: [Dimensions: XCTestExpectation] = [:]
    }

    public let id: String
    private let _state = StateSync(State())
    private let onDidRenderFirstFrame: OnDidRenderFirstFrame?

    init(id: String, onDidRenderFirstFrame: OnDidRenderFirstFrame? = nil) {
        self.id = id
        self.onDidRenderFirstFrame = onDidRenderFirstFrame
    }

    public func reset() {
        _state.mutate { $0.didRenderFirstFrame = false }
    }

    public func expect(dimensions: Dimensions) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Did render dimension \(dimensions)")
        expectation.assertForOverFulfill = false

        return _state.mutate {
            $0.expectationsForDimensions[dimensions] = expectation
            return expectation
        }
    }

    // MARK: - VideoRenderer

    var isAdaptiveStreamEnabled: Bool { true }

    var adaptiveStreamSize: CGSize { .init(width: 1920, height: 1080) }

    func set(size: CGSize) {
        print("\(type(of: self)) set(size: \(size))")
    }

    func render(frame: LiveKit.VideoFrame) {
        _state.mutate {
            if !$0.didRenderFirstFrame {
                $0.didRenderFirstFrame = true
                onDidRenderFirstFrame?(id)
            }

            for (key, value) in $0.expectationsForDimensions {
                if frame.dimensions.area >= key.area {
                    value.fulfill()
                }
            }
        }
    }

    // MARK: - TrackDelegate

    func track(_: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics _: [VideoCodec: TrackStatistics]) {
        guard let stream = statistics.inboundRtpStream.first else { return }
        var segments: [String] = []

        if let codec = statistics.codec.first(where: { $0.id == stream.codecId }), let mimeType = codec.mimeType {
            segments.append("codec: \(mimeType)")
        }

        if let width = stream.frameWidth, let height = stream.frameHeight {
            segments.append("dimensions: \(width)x\(height)")
        }

        if let fps = stream.framesPerSecond {
            segments.append("fps: \(fps)")
        }

        print("\(type(of: self)) didUpdateStatistics (\(segments.joined(separator: ", ")))")
    }
}

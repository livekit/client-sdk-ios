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

#if os(iOS)

@testable import LiveKit
import XCTest

final class BroadcastImageCodecTests: XCTestCase {
    
    private var codec: BroadcastImageCodec!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        codec = BroadcastImageCodec()
    }
    
    func testEncodeDecode() throws {
        let (width, height) = (64, 32)
        let testBuffer = try XCTUnwrap(createTestPixelBuffer(width: width, height: height))
        
        let (metadata, imageData) = try XCTUnwrap(try codec.encode(testBuffer))
        XCTAssertEqual(metadata.width, width)
        XCTAssertEqual(metadata.height, height)
        XCTAssertGreaterThan(imageData.count, 0)
        
        let decodedBuffer = try XCTUnwrap(try codec.decode(imageData, with: metadata))
        XCTAssertEqual(CVPixelBufferGetWidth(decodedBuffer), width)
        XCTAssertEqual(CVPixelBufferGetHeight(decodedBuffer), height)
    }
    
    func testDecodeNonImageData() throws {
        let nonImageData = Data(repeating: 0xFA, count: 1024)
        let metadata = BroadcastImageCodec.Metadata(width: 100, height: 100)
        XCTAssertThrowsError(try codec.decode(nonImageData, with: metadata)) { error in
            XCTAssertEqual(error as? BroadcastImageCodec.Error, .decodingFailed)
        }
    }
    
    func testDecodeEmpty() throws {
        let metadata = BroadcastImageCodec.Metadata(width: 100, height: 100)
        XCTAssertThrowsError(try codec.decode(Data(), with: metadata)) { error in
            XCTAssertEqual(error as? BroadcastImageCodec.Error, .decodingFailed)
        }
    }
    
    private func createTestPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        return pixelBuffer
    }
}

#endif

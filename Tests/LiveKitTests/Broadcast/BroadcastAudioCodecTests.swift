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
import CoreMedia
import AVFAudio

final class BroadcastAudioCodecTests: XCTestCase {
    
    private var codec: BroadcastAudioCodec!
     
    override func setUpWithError() throws {
        try super.setUpWithError()
        codec = BroadcastAudioCodec()
    }
    
    func testEncodeDecode() throws {
        let testBuffer = try XCTUnwrap(createTestAudioBuffer())
        
        let (metadata, audioData) = try XCTUnwrap(try codec.encode(testBuffer))
        let decodedBuffer = try XCTUnwrap(try codec.decode(audioData, with: metadata))
        
        XCTAssertEqual(decodedBuffer.frameLength, AVAudioFrameCount(testBuffer.numSamples))
        
        let asbd = try XCTUnwrap(testBuffer.formatDescription?.audioStreamBasicDescription)
        XCTAssertEqual(decodedBuffer.format.streamDescription.pointee, asbd)
    }
    
    func testDecodeEmpty() throws {
        let metadata = BroadcastAudioCodec.Metadata(
            sampleCount: 1,
            description: AudioStreamBasicDescription()
        )
        XCTAssertThrowsError(try codec.decode(Data(), with: metadata)) { error in
            XCTAssertEqual(error as? BroadcastAudioCodec.Error, .decodingFailed)
        }
    }
    
    private func createTestAudioBuffer() -> CMSampleBuffer? {
        let frames = 1024
        let sampleRate: Float64 = 44100.0
        let channels: UInt32 = 1
        let bitsPerChannel: UInt32 = 16
        let bytesPerFrame = channels * (bitsPerChannel / 8)
        let totalDataSize = Int(frames) * Int(bytesPerFrame)
        
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: bitsPerChannel,
            mReserved: 0
        )
        
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr,
        let audioFormatDesc = formatDescription else { return nil }
        
        let pcmData = UnsafeMutablePointer<UInt8>.allocate(capacity: totalDataSize)
        pcmData.initialize(repeating: 0, count: totalDataSize)
        
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: pcmData,
            blockLength: totalDataSize,
            blockAllocator: kCFAllocatorNull,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalDataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
        let cmBlockBuffer = blockBuffer else {
            pcmData.deallocate()
            return nil
        }
        
        var timingInfo = CMSampleTimingInfo(
            duration: CMTimeMake(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: CMTime.invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: cmBlockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: audioFormatDesc,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        
        return sampleBuffer
    }
}

extension AudioStreamBasicDescription: @retroactive Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.mSampleRate == rhs.mSampleRate &&
               lhs.mFormatID == rhs.mFormatID &&
               lhs.mFormatFlags == rhs.mFormatFlags &&
               lhs.mBytesPerPacket == rhs.mBytesPerPacket &&
               lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
               lhs.mBytesPerFrame == rhs.mBytesPerFrame &&
               lhs.mChannelsPerFrame == rhs.mChannelsPerFrame &&
               lhs.mBitsPerChannel == rhs.mBitsPerChannel &&
               lhs.mReserved == rhs.mReserved
    }
}

#endif

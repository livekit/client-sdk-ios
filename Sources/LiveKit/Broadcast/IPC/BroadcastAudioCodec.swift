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

import AVFoundation

/// Encode and decode audio samples for transport.
struct BroadcastAudioCodec {
    struct Metadata: Codable {
        let sampleCount: Int32
        let description: AudioStreamBasicDescription
    }

    enum Error: Swift.Error {
        case encodingFailed
        case decodingFailed
    }

    func encode(_ audioBuffer: CMSampleBuffer) throws -> (Metadata, Data) {
        
        guard let formatDescription = audioBuffer.formatDescription,
              let basicDescription = formatDescription.audioStreamBasicDescription,
              let blockBuffer = audioBuffer.dataBuffer else {
            throw Error.encodingFailed
        }
        
        var count: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &count,
            dataPointerOut: &dataPointer
        ) == kCMBlockBufferNoErr, let dataPointer else {
            throw Error.encodingFailed
        }
        
        let data = Data(bytes: dataPointer, count: count)
        let metadata = Metadata(
            sampleCount: Int32(audioBuffer.numSamples),
            description: basicDescription
        )
        return (metadata, data)
    }

    func decode(_ encodedData: Data, with metadata: Metadata) throws -> AVAudioPCMBuffer {
        
        guard !encodedData.isEmpty else {
            throw Error.decodingFailed
        }
        
        var description = metadata.description
        guard let format = AVAudioFormat(streamDescription: &description) else {
            throw Error.decodingFailed
        }
   
        let sampleCount = AVAudioFrameCount(metadata.sampleCount)
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: sampleCount
        ) else {
            throw Error.decodingFailed
        }
        pcmBuffer.frameLength = sampleCount
        
        guard format.isInterleaved else {
            throw Error.decodingFailed
        }
        
        guard let mData = pcmBuffer.audioBufferList.pointee.mBuffers.mData else {
            throw Error.decodingFailed
        }
        encodedData.copyBytes(
            to: mData.assumingMemoryBound(to: UInt8.self),
            count: encodedData.count
        )
        return pcmBuffer
    }
}

extension AudioStreamBasicDescription: Codable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(self.mSampleRate)
        try container.encode(self.mFormatID)
        try container.encode(self.mFormatFlags)
        try container.encode(self.mBytesPerPacket)
        try container.encode(self.mFramesPerPacket)
        try container.encode(self.mBytesPerFrame)
        try container.encode(self.mChannelsPerFrame)
        try container.encode(self.mBitsPerChannel)
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        try self.init(
            mSampleRate: container.decode(Float64.self),
            mFormatID: container.decode(AudioFormatID.self),
            mFormatFlags: container.decode(AudioFormatFlags.self),
            mBytesPerPacket: container.decode(UInt32.self),
            mFramesPerPacket: container.decode(UInt32.self),
            mBytesPerFrame: container.decode(UInt32.self),
            mChannelsPerFrame: container.decode(UInt32.self),
            mBitsPerChannel: container.decode(UInt32.self),
            mReserved: 0 // as per documentation
        )
    }
}

#endif

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
import CoreImage

/// Encode and decode image samples for transport.
struct BroadcastImageCodec {
    struct Metadata: Codable {
        let width: Int
        let height: Int
    }

    enum Error: Swift.Error {
        case encodingFailed
        case decodingFailed
    }

    let quality: CGFloat = 1.0

    func encode(_ sampleBuffer: CMSampleBuffer) throws -> (Metadata, Data) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw Error.encodingFailed
        }
        return try encode(imageBuffer)
    }
    
    func encode(_ imageBuffer: CVPixelBuffer) throws -> (Metadata, Data) {
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let metadata = Metadata(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
        let jpegData = try jpegEncode(imageBuffer)
        return (metadata, jpegData)
    }

    func decode(_ encodedData: Data, with metadata: Metadata) throws -> CVPixelBuffer {
        try jpegDecode(encodedData, metadata)
    }

    private let imageContext = CIContext(options: nil)
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private func jpegEncode(_ imageBuffer: CVImageBuffer) throws -> Data {
        let image = CIImage(cvPixelBuffer: imageBuffer)
        guard #available(iOS 17.0, *) else {
            // Workaround for "unsupported file format 'public.heic'"
            guard let cgImage = imageContext.createCGImage(image, from: image.extent) else {
                throw Error.encodingFailed
            }

            let data = NSMutableData()
            guard let imageDestination = CGImageDestinationCreateWithData(data, AVFileType.jpg as CFString, 1, nil) else {
                throw Error.encodingFailed
            }

            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
            CGImageDestinationAddImage(imageDestination, cgImage, options as CFDictionary)

            guard CGImageDestinationFinalize(imageDestination) else {
                throw Error.encodingFailed
            }
            return data as Data
        }

        guard let jpegData = imageContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        ) else {
            throw Error.encodingFailed
        }
        return jpegData
    }

    private func jpegDecode(_ jpegData: Data, _ metadata: Metadata) throws -> CVImageBuffer {
        var imageBuffer: CVImageBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            metadata.width,
            metadata.height,
            kCVPixelFormatType_32BGRA,
            nil,
            &imageBuffer
        )
        guard status == kCVReturnSuccess, let imageBuffer else {
            throw Error.decodingFailed
        }

        CVPixelBufferLockBaseAddress(imageBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, []) }

        guard let image = CIImage(data: jpegData) else {
            throw Error.decodingFailed
        }
        imageContext.render(image, to: imageBuffer)
        return imageBuffer
    }
}

#endif

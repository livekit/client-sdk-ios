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

import CoreImage
import Foundation

/// Receives broadcast samples from another process.
final class BroadcastReceiver: Sendable {
    /// Sample received from the other process with associated metadata.
    enum IncomingSample {
        case image(CVImageBuffer, VideoRotation)
    }

    enum Error: Swift.Error {
        case missingSampleData
    }

    private let channel: IPCChannel

    /// Creates a receiver with an open connection to another process.
    init(socketPath: SocketPath) async throws {
        channel = try await IPCChannel(acceptingOn: socketPath)
    }

    /// Whether or not the connection to the uploader has been closed.
    var isClosed: Bool {
        channel.isClosed
    }

    /// Close the connection to the uploader.
    func close() {
        channel.close()
    }

    struct AsyncSampleSequence: AsyncSequence, AsyncIteratorProtocol {
        fileprivate let upstream: IPCChannel.AsyncMessageSequence<BroadcastIPCHeader>
        private let imageCodec = BroadcastImageCodec()

        func next() async throws -> IncomingSample? {
            guard let (header, payload) = try await upstream.next() else {
                return nil
            }
            switch header {
            case let .image(metadata, rotation):
                guard let payload else { throw Error.missingSampleData }
                let imageBuffer = try imageCodec.decode(payload, with: metadata)
                return IncomingSample.image(imageBuffer, rotation)
            }
        }

        func makeAsyncIterator() -> Self { self }

        #if swift(<5.11)
        typealias AsyncIterator = Self
        typealias Element = IncomingSample
        #endif
    }

    var incomingSamples: AsyncSampleSequence {
        AsyncSampleSequence(upstream: channel.incomingMessages(BroadcastIPCHeader.self))
    }
}

#endif

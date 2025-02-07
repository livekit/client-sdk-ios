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

import Foundation
import Network

/// A simple framing protocol suitable for inter-process communication.
final class IPCProtocol: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: IPCProtocol.self)
    static var label: String { "LKIPCProtocol" }

    fileprivate struct Header {
        /// Total number of bytes in the message.
        let totalSize: UInt32

        /// Number of bytes in the payload section.
        let payloadSize: UInt32
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete _: Bool) {
        let header = Header(
            totalSize: UInt32(messageLength),
            payloadSize: UInt32(message.ipcMessagePayloadSize ?? 0)
        )
        framer.writeOutput(data: header.encodedData)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            logger.error("\(Self.label) error: \(error)")
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var tempHeader: Header? = nil
            let parsed = framer.parseInput(
                minimumIncompleteLength: Header.encodedSize,
                maximumLength: Header.encodedSize
            ) { buffer, _ -> Int in
                guard let buffer else { return 0 }
                if buffer.count < Header.encodedSize { return 0 }
                tempHeader = Header(buffer)
                return Header.encodedSize
            }
            guard parsed, let header = tempHeader else {
                return Header.encodedSize
            }
            let message = NWProtocolFramer.Message(ipcMessagePayloadSize: Int(header.payloadSize))
            if !framer.deliverInputNoCopy(length: Int(header.totalSize), message: message, isComplete: true) {
                return 0
            }
        }
    }

    required init(framer _: NWProtocolFramer.Instance) {}
    func start(framer _: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer _: NWProtocolFramer.Instance) {}
    func stop(framer _: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer _: NWProtocolFramer.Instance) {}
}

extension NWConnection.ContentContext {
    var ipcMessagePayloadSize: Int? {
        guard let metadata = protocolMetadata(definition: IPCProtocol.definition) as? NWProtocolFramer.Message else {
            return nil
        }
        return metadata.ipcMessagePayloadSize
    }

    static func ipcMessage(payloadSize: Int) -> NWConnection.ContentContext {
        NWConnection.ContentContext(
            identifier: IPCProtocol.label,
            metadata: [NWProtocolFramer.Message(ipcMessagePayloadSize: payloadSize)]
        )
    }
}

private extension NWProtocolFramer.Message {
    private static let payloadSizeKey = "LKIPCProtocolPayloadSize"

    convenience init(ipcMessagePayloadSize: Int) {
        self.init(definition: IPCProtocol.definition)
        self[Self.payloadSizeKey] = ipcMessagePayloadSize
    }

    var ipcMessagePayloadSize: Int? {
        self[Self.payloadSizeKey] as? Int
    }
}

extension IPCProtocol.Header {
    init(_ buffer: UnsafeMutableRawBufferPointer) {
        var tempTotalSize: UInt32 = 0
        var tempPayloadSize: UInt32 = 0

        withUnsafeMutableBytes(of: &tempTotalSize) {
            $0.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: buffer.baseAddress!.advanced(by: 0),
                    count: MemoryLayout<UInt32>.size
                )
            )
        }
        withUnsafeMutableBytes(of: &tempPayloadSize) {
            $0.copyMemory(
                from: UnsafeRawBufferPointer(
                    start: buffer.baseAddress!.advanced(by: MemoryLayout<UInt32>.size),
                    count: MemoryLayout<UInt32>.size
                )
            )
        }
        totalSize = tempTotalSize
        payloadSize = tempPayloadSize
    }

    var encodedData: Data {
        var tempTotalSize = totalSize
        var tempPayloadSize = payloadSize
        var data = Data(bytes: &tempTotalSize, count: MemoryLayout<UInt32>.size)
        data.append(Data(bytes: &tempPayloadSize, count: MemoryLayout<UInt32>.size))
        return data
    }

    static let encodedSize = MemoryLayout<UInt32>.size * 2
}

#endif

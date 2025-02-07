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

/// A communication channel between two processes on the same machine.
final class IPCChannel: Sendable {
    fileprivate static let restartDelay: TimeInterval = 0.1
    fileprivate static let queue = DispatchQueue(label: "io.livekit.ipc.queue", qos: .userInitiated)

    private static let defaultParameters = {
        let parameters = NWParameters.tcp
        let ipcProtocol = NWProtocolFramer.Options(definition: IPCProtocol.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(ipcProtocol, at: 0)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }()

    private let connection: NWConnection

    enum Error: Swift.Error {
        case cancelled
        case corruptMessage
    }

    // MARK: - Connection

    /// Creates a channel by accepting a connection from the other process.
    init(acceptingOn socketPath: SocketPath) async throws {
        try? FileManager.default.removeItem(atPath: socketPath.path)

        let parameters = Self.defaultParameters
        parameters.requiredLocalEndpoint = NWEndpoint(socketPath)

        let listener = try NWListener(using: parameters)
        guard let connection = try await listener.firstConnection else {
            throw Error.cancelled
        }

        try await connection.waitUntilReady()
        self.connection = connection
    }

    /// Creates a channel by establishing a connection to the other process.
    init(connectingTo socketPath: SocketPath) async throws {
        connection = NWConnection(
            to: NWEndpoint(socketPath),
            using: Self.defaultParameters
        )
        try await connection.waitUntilReady()
    }

    /// Whether or not the connection has been closed.
    var isClosed: Bool {
        connection.state != .ready
    }

    /// Closes the connection associated with this channel.
    func close() {
        connection.cancel()
    }

    // MARK: - Sending

    /// Sends a message to the connected process.
    func send(header: some Encodable, payload: Data? = nil) async throws {
        try await send(
            encodedHeader: encoder.encode(header),
            payload: payload
        )
    }

    private let encoder = PropertyListEncoder()

    private func send(encodedHeader: Data, payload: Data?) async throws {
        let payloadSize = payload?.count ?? 0

        var messageData = encodedHeader
        if let payload { messageData.append(payload) }

        try await connection.send(
            content: messageData,
            contentContext: NWConnection.ContentContext.ipcMessage(payloadSize: payloadSize)
        )
    }

    // MARK: - Receiving

    /// An asynchronous sequence of incoming messages.
    ///
    /// The sequence ends when the connection is closed by either side.
    ///
    struct AsyncMessageSequence<Header: Decodable>: AsyncSequence, AsyncIteratorProtocol {
        fileprivate let upstream: NWConnection.AsyncMessageSequence
        private let decoder = PropertyListDecoder()

        func next() async throws -> (Header, Data?)? {
            guard let rawMessage = try await upstream.next() else {
                return nil
            }
            let (data, context, isComplete) = rawMessage
            guard let data, isComplete else { return nil }

            guard let payloadSize = context?.ipcMessagePayloadSize,
                  payloadSize <= data.count else { throw IPCChannel.Error.corruptMessage }

            guard payloadSize > 0 else {
                return try (decoder.decode(Header.self, from: data), nil)
            }
            let headerSize = data.count - payloadSize
            let (headerData, payloadData) = data.partition(bytesInFirst: headerSize)
            return try (decoder.decode(Header.self, from: headerData), payloadData)
        }

        func makeAsyncIterator() -> Self { self }

        #if swift(<5.11)
        typealias AsyncIterator = Self
        typealias Element = (Header, Data?)
        #endif
    }

    /// Receives incoming messages from the connected process.
    /// - Parameter headerType: The type to decode from the message header.
    /// - Returns: An asynchronous sequence for receiving messages as they arrive.
    func incomingMessages<T: Decodable>(_: T.Type) -> AsyncMessageSequence<T> {
        AsyncMessageSequence(upstream: connection.incomingMessages)
    }
}

// MARK: - Extensions

private extension Data {
    func partition(bytesInFirst: Int) -> (Data, Data) {
        guard bytesInFirst > 0 else { return (Data(), self) }
        return (
            subdata(in: 0 ..< Swift.min(bytesInFirst, count)),
            subdata(in: Swift.min(bytesInFirst, count) ..< count)
        )
    }
}

private extension NWListener {
    var newConnections: AsyncThrowingStream<NWConnection, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.cancel()
            }
            newConnectionHandler = { connection in
                continuation.yield(connection)
            }
            stateUpdateHandler = { state in
                switch state {
                case .cancelled: continuation.finish()
                case let .waiting(error): continuation.finish(throwing: error)
                case let .failed(error): continuation.finish(throwing: error)
                default: break
                }
            }
            start(queue: IPCChannel.queue)
        }
    }

    var firstConnection: NWConnection? {
        get async throws { try await newConnections.first { _ in true } }
    }
}

private extension NWConnection {
    func waitUntilReady() async throws {
        for await state in stateUpdates {
            switch state {
            case .ready: return
            case .setup, .preparing: continue
            case .waiting:
                // Will enter this state when socket path does not exist yet
                let restartDelay = UInt64(IPCChannel.restartDelay * 1_000_000_000)
                try await Task.sleep(nanoseconds: restartDelay)
                restart()
                continue
            case let .failed(error): throw error
            case .cancelled:
                throw IPCChannel.Error.cancelled
            @unknown default: continue
            }
        }
        guard !Task.isCancelled else {
            throw IPCChannel.Error.cancelled
        }
    }

    private var stateUpdates: AsyncStream<NWConnection.State> {
        AsyncStream { [weak self] continuation in
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.stateUpdateHandler = nil
            }
            self?.stateUpdateHandler = { state in
                continuation.yield(state)
            }
            self?.start(queue: IPCChannel.queue)
        }
    }

    var incomingMessages: AsyncMessageSequence {
        AsyncMessageSequence(connection: self)
    }

    typealias IncomingMessage = (Data?, NWConnection.ContentContext?, Bool)

    struct AsyncMessageSequence: AsyncSequence, AsyncIteratorProtocol {
        let connection: NWConnection
        func next() async throws -> IncomingMessage? {
            try await connection.receiveSingleMessage()
        }

        func makeAsyncIterator() -> Self { self }

        #if swift(<5.11)
        typealias AsyncIterator = Self
        typealias Element = IncomingMessage
        #endif
    }

    private func receiveSingleMessage() async throws -> IncomingMessage {
        try await withCheckedThrowingContinuation { [weak self] continuation in
            self?.receiveMessage { data, context, isComplete, error in
                guard let error else {
                    continuation.resume(returning: (data, context, isComplete))
                    return
                }
                continuation.resume(throwing: error)
            }
        }
    }

    func send(content: Data, contentContext: NWConnection.ContentContext) async throws {
        try await withCheckedThrowingContinuation { continuation in
            send(
                content: content,
                contentContext: contentContext,
                completion: .contentProcessed { error in
                    guard let error else {
                        continuation.resume()
                        return
                    }
                    continuation.resume(throwing: error)
                }
            )
        }
    }
}

#endif

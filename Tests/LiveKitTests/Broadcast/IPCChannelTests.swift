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
import Network

final class IPCChannelTests: XCTestCase {
    
    private var socketPath: SocketPath!
    
    enum TestSetupError: Error {
        case failedToGeneratePath
    }
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Use relative paths to ensure socket path is not too long
        let temporaryDirectory = FileManager.default.temporaryDirectory
        FileManager.default.changeCurrentDirectoryPath(temporaryDirectory.path)
        
        guard let socketPath = SocketPath(UUID().uuidString + ".sock") else {
            throw TestSetupError.failedToGeneratePath
        }
        self.socketPath = socketPath
    }
    
    func testConnectionAcceptorFirst() async throws {
        let established = XCTestExpectation(description: "Connection established")

        Task {
            let channel = try await IPCChannel(acceptingOn: socketPath)
            XCTAssertFalse(channel.isClosed)
            
            established.fulfill()
        }
        Task {
            let channel = try await IPCChannel(connectingTo: socketPath)
            XCTAssertFalse(channel.isClosed)
            
            // Keep alive to give time acceptor to accept
            try await Task.shortSleep()
        }
        await fulfillment(of: [established], timeout: 5.0)
    }

    func testConnectionConnectorFirst() async throws {
        let established = XCTestExpectation(description: "Connection established")
        
        Task {
            let channel = try await IPCChannel(connectingTo: socketPath)
            XCTAssertFalse(channel.isClosed)
            established.fulfill()
        }
        Task {
            let channel = try await IPCChannel(acceptingOn: socketPath)
            XCTAssertFalse(channel.isClosed)
        }
        await fulfillment(of: [established], timeout: 5.0)
    }
    
    private func assertInitCancellationThrows(
        _ initializer: @escaping @autoclosure () async throws -> IPCChannel,
        file: StaticString = #file,
        line: UInt = #line
    ) async throws {
        let cancelThrowsError = XCTestExpectation(description: "Throws error on cancellation")
        let channelTask = Task {
            do {
                _ = try await initializer()
                XCTFail("Should not pass initialization with no connection", file: file, line: line)
            } catch {
                XCTAssertEqual(error as? IPCChannel.Error, .cancelled, file: file, line: line)
                cancelThrowsError.fulfill()
            }
        }
        channelTask.cancel()
        await fulfillment(of: [cancelThrowsError], timeout: 5.0)
    }

    func testConnectorCancelDuringInit() async throws {
        try await assertInitCancellationThrows(
            try await IPCChannel(connectingTo: self.socketPath)
        )
    }
    
    func testAcceptorCancelDuringInit() async throws {
        try await assertInitCancellationThrows(
            try await IPCChannel(acceptingOn: self.socketPath)
        )
    }
    
    private struct TestHeader: Codable, Equatable {
        let someField: Int
    }
    
    func testMessageExchange() async throws {
        
        let initialReceived = XCTestExpectation(description: "Acceptor receives initial message from connector")
        let replyReceived = XCTestExpectation(description: "Connector receives reply from acceptor")
        
        let testHeader = TestHeader(someField: 1)
        let testPayload = Data([1, 2, 3])
        
        Task {
            let channel = try await IPCChannel(acceptingOn: socketPath)
            
            for try await (header, payload) in channel.incomingMessages(TestHeader.self) {
                
                // Received initial message
                XCTAssertEqual(header, testHeader)
                XCTAssertEqual(payload, testPayload)
                initialReceived.fulfill()
                
                // Send reply
                try await channel.send(header: testHeader, payload: testPayload)
            }
        }
        Task {
            let channel = try await IPCChannel(connectingTo: socketPath)
            
            // Send initial message
            try await channel.send(header: testHeader, payload: testPayload)
            
            for try await (header, payload) in channel.incomingMessages(TestHeader.self) {
                // Received reply
                XCTAssertEqual(header, testHeader)
                XCTAssertEqual(payload, testPayload)
                replyReceived.fulfill()
            }
        }
        await fulfillment(
            of: [initialReceived, replyReceived],
            timeout: 5.0,
            enforceOrder: true
        )
    }
    
    func testMessageSequenceAfterClosure() async throws {
        let sequenceEnds = XCTestExpectation(description: "Message sequence ends after closure")
        Task {
            let channel = try await IPCChannel(acceptingOn: socketPath)
            for try await _ in channel.incomingMessages(TestHeader.self) {
                // Received message
            }
            sequenceEnds.fulfill()
        }
        Task {
            let channel = try await IPCChannel(connectingTo: socketPath)
            try await channel.send(header: TestHeader(someField: 1))
            channel.close()
        }
        await fulfillment(of: [sequenceEnds], timeout: 5.0)
    }
}

private extension Task where  Success == Never, Failure == Never {
    static func shortSleep() async throws {
        try await Self.sleep(nanoseconds: 1_000_000_000)
    }
}

#endif

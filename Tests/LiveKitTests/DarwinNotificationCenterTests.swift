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

import Combine
@testable import LiveKit
import XCTest

class DarwinNotificationCenterTests: XCTestCase {
    func testPublisher() throws {
        let receiveFirst = XCTestExpectation(description: "Receive from 1st subscriber")
        let receiveSecond = XCTestExpectation(description: "Receive from 2nd subscriber")

        let name = DarwinNotification.broadcastStarted

        var cancellable = Set<AnyCancellable>()
        DarwinNotificationCenter.shared
            .publisher(for: name)
            .sink {
                XCTAssertEqual($0, name)
                receiveFirst.fulfill()
            }
            .store(in: &cancellable)
        DarwinNotificationCenter.shared
            .publisher(for: name)
            .sink {
                XCTAssertEqual($0, name)
                receiveSecond.fulfill()
            }
            .store(in: &cancellable)

        DarwinNotificationCenter.shared.postNotification(name)
        wait(for: [receiveFirst, receiveSecond], timeout: 10.0)
    }
}

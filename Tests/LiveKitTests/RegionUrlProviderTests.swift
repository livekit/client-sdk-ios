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

@testable import LiveKit
import XCTest

class RegionUrlProviderTests: XCTestCase {
    func testResolveUrl() async throws {
        let room = Room()

        let testCacheInterval: TimeInterval = 3
        // Test data.
        let testRegionSettings = [Livekit_RegionInfo.with {
            $0.region = "otokyo1a"
            $0.url = "https://example.otokyo1a.production.livekit.cloud"
            $0.distance = 32838
        },
        Livekit_RegionInfo.with {
            $0.region = "dblr1a"
            $0.url = "https://example.dblr1a.production.livekit.cloud"
            $0.distance = 6_660_301
        },
        Livekit_RegionInfo.with {
            $0.region = "dsyd1a"
            $0.url = "https://example.dsyd1a.production.livekit.cloud"
            $0.distance = 7_823_582
        }].map { $0.toLKType() }.compactMap { $0 }

        let providedUrl = URL(string: "https://example.livekit.cloud")!

        // See if request should be initiated.
        XCTAssert(room.regionManager(shouldRequestSettingsForUrl: providedUrl), "Should require to request region settings")

        // Set test data.
        room._state.mutate {
            $0.providedUrl = providedUrl
            $0.token = ""
        }

        room._regionState.mutate {
            $0.url = providedUrl
            $0.all = testRegionSettings
            $0.remaining = testRegionSettings
            $0.lastRequested = Date()
        }

        // See if request is not required to be initiated.
        XCTAssert(!room.regionManager(shouldRequestSettingsForUrl: providedUrl), "Should require to request region settings")

        let attempt1 = try await room.regionManagerResolveBest()
        print("Next url: \(String(describing: attempt1))")
        XCTAssert(attempt1.url == testRegionSettings[0].url)
        room.regionManager(addFailedRegion: attempt1)

        let attempt2 = try await room.regionManagerResolveBest()
        print("Next url: \(String(describing: attempt2))")
        XCTAssert(attempt2.url == testRegionSettings[1].url)
        room.regionManager(addFailedRegion: attempt2)

        let attempt3 = try await room.regionManagerResolveBest()
        print("Next url: \(String(describing: attempt3))")
        XCTAssert(attempt3.url == testRegionSettings[2].url)
        room.regionManager(addFailedRegion: attempt3)

        // No more regions
        let attempt4 = try? await room.regionManagerResolveBest()
        XCTAssert(attempt4 == nil)

        // Simulate cache time elapse.
        room._regionState.mutate {
            // Roll back time.
            $0.lastRequested = Date().addingTimeInterval(-Room.regionManagerCacheInterval)
        }

        // After cache time elapsed, should require to request region settings again.
        XCTAssert(room.regionManager(shouldRequestSettingsForUrl: providedUrl), "Should require to request region settings")
    }
}

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

import Foundation

// MARK: - Room+Region

extension Room {
    static let regionManagerCacheInterval: TimeInterval = 3000

    // MARK: - Public

    // prepareConnection should be called as soon as the page is loaded, in order
    // to speed up the connection attempt.
    //
    // With LiveKit Cloud, it will also determine the best edge data center for
    // the current client to connect to if a token is provided.
    public func prepareConnection(url providedUrlString: String, token: String) {
        // Must be in disconnected state.
        guard _state.connectionState == .disconnected else {
            log("Room is not in disconnected state", .info)
            return
        }

        guard let providedUrl = URL(string: providedUrlString), providedUrl.isValidForConnect else {
            log("URL parse failed", .error)
            return
        }

        guard providedUrl.isCloud else {
            log("Provided url is not a livekit cloud url", .warning)
            return
        }

        _state.mutate {
            $0.providedUrl = providedUrl
            $0.token = token
        }

        regionManagerPrepareRegionSettings()
    }

    // MARK: - Internal

    func regionManagerResolveBest() async throws -> RegionInfo {
        try await regionManagerRequestSettings()

        guard let selectedRegion = _regionState.remaining.first else {
            throw LiveKitError(.regionUrlProvider, message: "No more remaining regions.")
        }

        log("[Region] Resolved region: \(String(describing: selectedRegion))")

        return selectedRegion
    }

    func regionManager(addFailedRegion region: RegionInfo) {
        _regionState.mutate {
            $0.remaining.removeAll { $0 == region }
        }
    }

    func regionManagerPrepareRegionSettings() {
        Task.detached {
            try await self.regionManagerRequestSettings()
        }
    }

    func regionManager(shouldRequestSettingsForUrl providedUrl: URL) -> Bool {
        guard providedUrl.isCloud else { return false }
        return _regionState.read {
            guard providedUrl == $0.url, let regionSettingsUpdated = $0.lastRequested else { return true }
            let interval = Date().timeIntervalSince(regionSettingsUpdated)
            return interval > Self.regionManagerCacheInterval
        }
    }

    // MARK: - Private

    private func regionManagerRequestSettings() async throws {
        let (providedUrl, token) = _state.read { ($0.providedUrl, $0.token) }

        guard let providedUrl, let token else {
            throw LiveKitError(.invalidState)
        }

        // Ensure url is for cloud.
        guard providedUrl.isCloud else {
            throw LiveKitError(.onlyForCloud)
        }

        guard regionManager(shouldRequestSettingsForUrl: providedUrl) else {
            return
        }

        // Make a request which ignores cache.
        var request = URLRequest(url: providedUrl.regionSettingsUrl(),
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)

        request.addValue("Bearer \(token)", forHTTPHeaderField: "authorization")

        log("[Region] Requesting region settings...")

        let (data, response) = try await URLSession.shared.data(for: request)
        // Response must be a HTTPURLResponse.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveKitError(.regionUrlProvider, message: "Failed to fetch region settings")
        }

        // Check the status code.
        guard httpResponse.isStatusCodeOK else {
            log("[Region] Failed to fetch region settings, error: \(String(describing: httpResponse))", .error)
            throw LiveKitError(.regionUrlProvider, message: "Failed to fetch region settings with status code: \(httpResponse.statusCode)")
        }

        do {
            // Try to parse the JSON data.
            let regionSettings = try Livekit_RegionSettings(jsonUTF8Data: data)
            let allRegions = regionSettings.regions.compactMap { $0.toLKType() }

            if allRegions.isEmpty {
                throw LiveKitError(.regionUrlProvider, message: "Fetched region data is empty.")
            }

            log("[Region] all regions: \(String(describing: allRegions))")

            _regionState.mutate {
                $0.url = providedUrl
                $0.all = allRegions
                $0.remaining = allRegions
                $0.lastRequested = Date()
            }
        } catch {
            throw LiveKitError(.regionUrlProvider, message: "Failed to parse region settings with error: \(error)")
        }
    }
}

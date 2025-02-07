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

import Network

/// A UNIX domain path valid on this system.
struct SocketPath {
    let path: String

    /// Creates a socket path or returns nil if the given path string is not valid.
    init?(_ path: String) {
        guard Self.isValid(path) else {
            logger.error("Invalid socket path: \(path)")
            return nil
        }
        self.path = path
    }

    /// Whether or not the given socket path is valid on this system.
    ///
    /// Proper path validation is essential; as of writing, the Network framework
    /// does not perform such validation internally, and attempting to connect to a
    /// socket with an invalid path results in a crash.
    ///
    private static func isValid(_ path: String) -> Bool {
        path.utf8.count <= addressMaxLength
    }

    /// The maximum supported length (in bytes) for socket paths on this system.
    private static let addressMaxLength: Int = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
}

extension NWEndpoint {
    init(_ socketPath: SocketPath) {
        self = .unix(path: socketPath.path)
    }
}

#endif

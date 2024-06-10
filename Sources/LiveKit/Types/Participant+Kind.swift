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

public extension Participant {
    @objc
    enum Kind: Int {
        case unknown
        /// Standard participants, e.g. web clients.
        case standard
        /// Only ingests streams.
        case ingress
        /// Only consumes streams.
        case egress
        /// SIP participants.
        case sip
        /// LiveKit agents.
        case agent
    }
}

// MARK: - Internal

extension Livekit_ParticipantInfo.Kind {
    func toLKType() -> Participant.Kind {
        switch self {
        case .standard: return .standard
        case .ingress: return .ingress
        case .egress: return .egress
        case .sip: return .sip
        case .agent: return .agent
        default: return .unknown
        }
    }
}

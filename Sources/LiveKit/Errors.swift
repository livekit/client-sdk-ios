/*
 * Copyright 2022 LiveKit
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
import WebRTC

public protocol LiveKitError: Error, CustomStringConvertible {}

extension LiveKitError {

    internal func buildDescription(_ name: String, _ message: String? = nil, rawError: Error? = nil) -> String {
        "\(String(describing: type(of: self))).\(name)" + (message != nil ? " \(message!)" : "") + (rawError != nil ? " rawError: \(rawError!.localizedDescription)" : "")
    }
}

extension LiveKitError where Self: LocalizedError {

    public var localizedDescription: String {
        description
    }
}

public enum RoomError: LiveKitError {
    case missingRoomId(String)
    case invalidURL(String)
    case protocolError(String)

    public var description: String {
        "RoomError"
    }
}

public enum InternalError: LiveKitError {
    case state(message: String? = nil)
    case parse(message: String? = nil)
    case convert(message: String? = nil)
    case timeout(message: String? = nil)

    public var description: String {
        switch self {
        case .state(let message): return buildDescription("state", message)
        case .parse(let message): return buildDescription("parse", message)
        case .convert(let message): return buildDescription("convert", message)
        case .timeout(let message): return buildDescription("timeout", message)
        }
    }
}

public enum EngineError: LiveKitError {
    // WebRTC lib returned error
    case webRTC(message: String?, Error? = nil)
    case state(message: String? = nil)
    case timedOut(message: String? = nil)

    public var description: String {
        switch self {
        case .webRTC(let message, _): return buildDescription("webRTC", message)
        case .state(let message): return buildDescription("state", message)
        case .timedOut(let message): return buildDescription("timedOut", message)
        }
    }
}

public enum TrackError: LiveKitError {
    case state(message: String? = nil)
    case type(message: String? = nil)
    case duplicate(message: String? = nil)
    case capturer(message: String? = nil)
    case publish(message: String? = nil)
    case unpublish(message: String? = nil)
    case timedOut(message: String? = nil)

    public var description: String {
        switch self {
        case .state(let message): return buildDescription("state", message)
        case .type(let message): return buildDescription("type", message)
        case .duplicate(let message): return buildDescription("duplicate", message)
        case .capturer(let message): return buildDescription("capturer", message)
        case .publish(let message): return buildDescription("publish", message)
        case .unpublish(let message): return buildDescription("unpublish", message)
        case .timedOut(let message): return buildDescription("timedOut", message)
        }
    }
}

public enum SignalClientError: LiveKitError {
    case state(message: String? = nil)
    case socketError(rawError: Error?)
    case close(message: String? = nil)
    case connect(message: String? = nil)
    case timedOut(message: String? = nil)
    case serverPingTimedOut(message: String? = nil)

    public var description: String {
        switch self {
        case .state(let message): return buildDescription("state", message)
        case .socketError(let rawError): return buildDescription("socketError", rawError: rawError)
        case .close(let message): return buildDescription("close", message)
        case .connect(let message): return buildDescription("connect", message)
        case .timedOut(let message): return buildDescription("timedOut", message)
        case .serverPingTimedOut(let message): return buildDescription("serverPingTimedOut", message)
        }
    }
}

public enum NetworkError: LiveKitError {
    case disconnected(message: String? = nil, rawError: Error? = nil)
    case response(message: String? = nil)

    public var description: String {
        switch self {
        case .disconnected(let message, let rawError): return buildDescription("disconnected", message, rawError: rawError)
        case .response(let message): return buildDescription("response", message)
        }
    }
}

public enum TransportError: LiveKitError {

    case timedOut(message: String? = nil)
    case noPrimary(message: String? = nil)

    public var description: String {
        switch self {
        case .timedOut(let message): return buildDescription("timedOut", message)
        case .noPrimary(let message): return buildDescription("no primary", message)
        }
    }
}

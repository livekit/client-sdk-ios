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
import OSLog

#if swift(>=5.9)
internal import Logging
#else
@_implementationOnly import Logging
#endif

struct OSLogHandler: LogHandler {
    public var logLevel: Logging.Logger.Level = .debug
    private let oslogger: OSLog

    init(_ oslogger: OSLog) {
        self.oslogger = oslogger
    }

    public func log(
        level _: Logging.Logger.Level,
        message: Logging.Logger.Message,
        metadata: Logging.Logger.Metadata?,
        source _: String,
        file _: String,
        function _: String,
        line _: UInt
    ) {
        var combinedPrettyMetadata = prettyMetadata
        if let metadataOverride = metadata, !metadataOverride.isEmpty {
            combinedPrettyMetadata = prettify(
                self.metadata.merging(metadataOverride) {
                    $1
                }
            )
        }

        var formedMessage = message.description
        if combinedPrettyMetadata != nil {
            formedMessage += " -- " + combinedPrettyMetadata!
        }
        os_log("%{public}@", log: oslogger, type: OSLogType.from(loggerLevel: .info), formedMessage as NSString)
    }

    private var prettyMetadata: String?
    public var metadata = Logger.Metadata() {
        didSet {
            prettyMetadata = prettify(metadata)
        }
    }

    /// Add, remove, or change the logging metadata.
    /// - parameters:
    ///    - metadataKey: the key for the metadata item.
    public subscript(metadataKey metadataKey: String) -> Logging.Logger.Metadata.Value? {
        get {
            metadata[metadataKey]
        }
        set {
            metadata[metadataKey] = newValue
        }
    }

    private func prettify(_ metadata: Logging.Logger.Metadata) -> String? {
        if metadata.isEmpty {
            return nil
        }
        return metadata.map {
            "\($0)=\($1)"
        }.joined(separator: " ")
    }
}

private extension OSLogType {
    static func from(loggerLevel: Logging.Logger.Level) -> Self {
        switch loggerLevel {
        case .debug: return .debug

        case .info: return .info

        case .error: return .error

        case .critical: return .fault

        // `OSLog` doesn't have `trace`, so use `debug`
        case .trace: return .debug

        // https://developer.apple.com/documentation/os/logging/generating_log_messages_from_your_code
        // According to the documentation, `default` is `notice`.
        case .notice: return .default

        // `OSLog` doesn't have `warning`, so use `info`
        case .warning: return .info
        }
    }
}

#endif

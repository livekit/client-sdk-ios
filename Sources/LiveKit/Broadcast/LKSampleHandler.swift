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

#if canImport(ReplayKit)
import ReplayKit
#endif

#if swift(>=5.9)
internal import Logging
#else
@_implementationOnly import Logging
#endif

import Combine
import LKObjCHelpers
import OSLog

@available(macCatalyst 13.1, *)
open class LKSampleHandler: RPBroadcastSampleHandler {

    private var uploader: BroadcastUploader?
    private var cancellable = Set<AnyCancellable>()

    override public init() {
        super.init()
        bootstrapLogging()
        logger.info("LKSampleHandler created")

        createUploader()

        DarwinNotificationCenter.shared
            .publisher(for: .broadcastRequestStop)
            .sink { [weak self] _ in
                logger.info("Received stop request")
                self?.finishBroadcastWithoutError()
            }
            .store(in: &cancellable)
    }

    override public func broadcastStarted(withSetupInfo _: [String: NSObject]?) {
        // User has requested to start the broadcast. Setup info from the UI extension can be supplied but optional.
        logger.info("Broadcast started")
        DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
    }

    override public func broadcastPaused() {
        // User has requested to pause the broadcast. Samples will stop being delivered.
        logger.info("Broadcast paused")
    }

    override public func broadcastResumed() {
        // User has requested to resume the broadcast. Samples delivery will resume.
        logger.info("Broadcast resumed")
    }

    override public func broadcastFinished() {
        // User has requested to finish the broadcast.
        logger.info("Broadcast finished")
        DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
        uploader?.close()
    }

    override public func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        do {
            try uploader?.upload(sampleBuffer, with: type)
        } catch {
            guard case .connectionClosed = error as? BroadcastUploader.Error else {
                logger.error("Failed to send sample: \(error)")
                return
            }
            finishBroadcastWithoutError()
        }
    }

    /// Override point to change the behavior when the socket connection has closed.
    /// The default behavior is to pass errors through, and otherwise show nothing to the user.
    ///
    /// You should call `finishBroadcastWithError` in your implementation, but you can
    /// add custom logging or present a custom error to the user instead.
    ///
    /// To present a custom error message:
    ///   ```
    ///   self.finishBroadcastWithError(NSError(
    ///     domain: RPRecordingErrorDomain,
    ///     code: 10001,
    ///     userInfo: [NSLocalizedDescriptionKey: "My Custom Error Message"]
    ///   ))
    ///   ```
    open func connectionDidClose(error: Error?) {
        if let error {
            finishBroadcastWithError(error)
        } else {
            finishBroadcastWithoutError()
        }
    }

    private func finishBroadcastWithoutError() {
        LKObjCHelpers.finishBroadcastWithoutError(self)
    }

    private func createUploader() {
        guard let socketPath = BroadcastBundleInfo.socketPath else {
            logger.error("Bundle settings improperly configured for screen capture")
            return
        }
        Task {
            do {
                uploader = try await BroadcastUploader(socketPath: socketPath)
                logger.info("Uploader connected")
            } catch {
                logger.error("Uploader connection failed: \(error)")
                connectionDidClose(error: error)
            }
        }
    }

    // MARK: - Logging

    /// Whether or not to bootstrap the logging system when initialized.
    ///
    /// Disabled by default. Enable by overriding this property to return true.
    ///
    open var enableLogging: Bool { false }

    /// Whether or not to include debug and trace messages in log output.
    ///
    /// Disabled by default. Enable by overriding this property to return true.
    /// - SeeAlso: ``enableLogging``
    ///
    open var verboseLogging: Bool { false }

    private func bootstrapLogging() {
        guard enableLogging else { return }

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let logger = OSLog(subsystem: bundleIdentifier, category: "LKSampleHandler")
        let logLevel = verboseLogging ? Logger.Level.trace : .info

        LoggingSystem.bootstrap { _ in
            var logHandler = OSLogHandler(logger)
            logHandler.logLevel = logLevel
            return logHandler
        }
    }
}

#endif

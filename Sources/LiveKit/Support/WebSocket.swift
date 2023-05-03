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
import Promises

internal class WebSocket: NSObject, URLSessionWebSocketDelegate, Loggable {

    private let queue = DispatchQueue(label: "LiveKitSDK.webSocket", qos: .default)

    typealias OnMessage = (URLSessionWebSocketTask.Message) -> Void
    typealias OnDisconnect = (_ reason: DisconnectReason?) -> Void

    public var onMessage: OnMessage?
    public var onDisconnect: OnDisconnect?

    private let operationQueue = OperationQueue()
    private let request: URLRequest

    private var disconnected = false
    private var connectPromise: Promise<WebSocket>?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // explicitly set timeout intervals
        config.timeoutIntervalForRequest = TimeInterval(60)
        config.timeoutIntervalForResource = TimeInterval(604_800)
        log("URLSessionConfiguration.timeoutIntervalForRequest: \(config.timeoutIntervalForRequest)")
        log("URLSessionConfiguration.timeoutIntervalForResource: \(config.timeoutIntervalForResource)")
        return URLSession(configuration: config,
                          delegate: self,
                          delegateQueue: operationQueue)
    }()

    private lazy var task: URLSessionWebSocketTask = {
        session.webSocketTask(with: request)
    }()

    static func connect(url: URL,
                        onMessage: OnMessage? = nil,
                        onDisconnect: OnDisconnect? = nil) -> Promise<WebSocket> {

        return WebSocket(url: url,
                         onMessage: onMessage,
                         onDisconnect: onDisconnect).connect()
    }

    private init(url: URL,
                 onMessage: OnMessage? = nil,
                 onDisconnect: OnDisconnect? = nil) {

        request = URLRequest(url: url,
                             cachePolicy: .useProtocolCachePolicy,
                             timeoutInterval: .defaultSocketConnect)

        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
        super.init()
        task.resume()
    }

    deinit {
        log()
    }

    private func connect() -> Promise<WebSocket> {
        connectPromise = Promise<WebSocket>.pending()
        return connectPromise!
    }

    internal func cleanUp(reason: DisconnectReason?, notify: Bool = true) {

        log("reason: \(String(describing: reason))")

        guard !disconnected else {
            log("dispose can be called only once", .warning)
            return
        }

        // mark as disconnected, this instance cannot be re-used
        disconnected = true

        task.cancel()
        session.invalidateAndCancel()

        if let promise = connectPromise {
            let sdkError = NetworkError.disconnected(message: "WebSocket disconnected")
            promise.reject(sdkError)
            connectPromise = nil
        }

        if notify {
            onDisconnect?(reason)
        }
    }
    
    public func send(data: Data) async throws {
        try await self.task.send(URLSessionWebSocketTask.Message.data(data))
    }

    public func send(data: Data) -> Promise<Void> {
        let message = URLSessionWebSocketTask.Message.data(data)
        return Promise(on: queue) { resolve, fail in
            self.task.send(message) { error in
                if let error = error {
                    fail(error)
                    return
                }
                resolve(())
            }
        }
    }

    private func receive(task: URLSessionWebSocketTask,
                         result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .failure(let error):
            log("Failed to receive \(error)", .error)

        case .success(let message):
            onMessage?(message)
            queue.async { task.receive { self.receive(task: task, result: $0) } }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    internal func urlSession(_ session: URLSession,
                             webSocketTask: URLSessionWebSocketTask,
                             didOpenWithProtocol protocol: String?) {

        guard !disconnected else {
            return
        }

        if let promise = connectPromise {
            promise.fulfill(self)
            connectPromise = nil
        }

        queue.async { webSocketTask.receive { self.receive(task: webSocketTask, result: $0) } }
    }

    internal func urlSession(_ session: URLSession,
                             webSocketTask: URLSessionWebSocketTask,
                             didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                             reason: Data?) {

        guard !disconnected else {
            return
        }

        let sdkError = NetworkError.disconnected(message: "WebSocket did close with code: \(closeCode) reason: \(String(describing: reason))")

        cleanUp(reason: .networkError(sdkError))
    }

    internal func urlSession(_ session: URLSession,
                             task: URLSessionTask,
                             didCompleteWithError error: Error?) {

        guard !disconnected else {
            return
        }

        let sdkError = NetworkError.disconnected(message: "WebSocket disconnected", rawError: error)

        cleanUp(reason: .networkError(sdkError))
    }
}

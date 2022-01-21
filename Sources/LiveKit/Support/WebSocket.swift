import Foundation
import Promises

internal class WebSocket: NSObject, URLSessionWebSocketDelegate, Loggable {

    typealias OnMessage = (URLSessionWebSocketTask.Message) -> Void
    typealias OnDisconnect = (_ reason: DisconnectReason) -> Void

    private var onMessage: OnMessage?
    private var onDisconnect: OnDisconnect?

    private let queue = DispatchQueue(label: "LiveKitSDK.webSocket", qos: .background)
    private let operationQueue = OperationQueue()
    private let request: URLRequest

    private var disconnected = false
    private var connectPromise: Promise<WebSocket>?

    private lazy var session: URLSession = {
        URLSession(configuration: .default,
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
                             cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                             timeoutInterval: .defaultConnect)

        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
        super.init()
        task.resume()
    }

    private func connect() -> Promise<WebSocket> {
        connectPromise = Promise<WebSocket>.pending()
        return connectPromise!
    }

    internal func cleanUp(reason: DisconnectReason) {
        log("reason: \(reason)")

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

        onDisconnect?(reason)
    }

    public func send(data: Data) -> Promise<Void> {
        let message = URLSessionWebSocketTask.Message.data(data)
        return Promise(on: .sdk) { resolve, fail in
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
            cleanUp(reason: .network(error: error))

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

        cleanUp(reason: .network())
    }

    internal func urlSession(_ session: URLSession,
                             task: URLSessionTask,
                             didCompleteWithError error: Error?) {

        guard !disconnected else {
            return
        }

        let sdkError = NetworkError.disconnected(message: "WebSocket disconnected",
                                                 rawError: error)

        cleanUp(reason: .network(error: sdkError))
    }
}

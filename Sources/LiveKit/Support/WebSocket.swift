import Foundation
import Promises

internal class WebSocket: NSObject, URLSessionWebSocketDelegate {

    typealias OnMessage = (URLSessionWebSocketTask.Message) -> Void
    typealias OnClose = (_ error: Error?) -> Void

    public var onMessage: OnMessage?
    public var onClose: OnClose?

    private let queue = DispatchQueue(label: "livekit.webSocket", qos: .background)

    private let request: URLRequest

    public var connectPromise = Promise<WebSocket>.pending()

    private lazy var session: URLSession = {
        URLSession(configuration: .default,
                   delegate: self,
                   delegateQueue: OperationQueue())
    }()

    private lazy var task: URLSessionWebSocketTask = {
        session.webSocketTask(with: request)
    }()

    static func connect(url: URL, onMessage: OnMessage? = nil) -> Promise<WebSocket> {
        WebSocket(url: url,
                  onMessage: onMessage).connectPromise
    }

    private init(url: URL, onMessage: OnMessage? = nil) {
        request = URLRequest(url: url)
        self.onMessage = onMessage
        super.init()
        task.resume()
    }

    public func close(error: Error? = nil) {
        task.cancel()
        session.invalidateAndCancel()
        onClose?(error)
    }

    @discardableResult
    public func send(data: Data) -> Promise<Void> {
        let message = URLSessionWebSocketTask.Message.data(data)
        return Promise { resolve, fail in
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
            close(error: error)

        case .success(let message):
            onMessage?(message)
            queue.async { task.receive { self.receive(task: task, result: $0) } }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {

        connectPromise.fulfill(self)
        queue.async { webSocketTask.receive { self.receive(task: webSocketTask, result: $0) } }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {

        //        guard webSocketTask == webSocket else {
        //            return
        //        }
        //
        //        logger.debug("websocket disconnected")
        //        connectionState = .disconnected()
        //        notify { $0.signalClient(self, didClose: closeCode) }
        onClose?(nil)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {

        //        guard task == webSocket else {
        //            return
        //        }
        //
        //        let lkError = SignalClientError.socketError(rawError: error)
        //
        //        connectionState = .disconnected(lkError)
        //        notify { $0.signalClient(self, didFailConnection: lkError) }
        connectPromise.reject(error!)
    }
}

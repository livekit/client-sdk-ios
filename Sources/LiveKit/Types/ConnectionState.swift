import Foundation

public enum ReconnectMode {
    case quick
    case full
}

public enum ConnectMode {
    case normal
    case reconnect(_ mode: ReconnectMode)
}

extension ConnectMode: Equatable {

    public static func == (lhs: ConnectMode, rhs: ConnectMode) -> Bool {
        lhs.isEqual(to: rhs)
    }

    public func isEqual(to rhs: ConnectMode, includingAssociatedValues: Bool = true) -> Bool {
        switch (self, rhs) {
        case (.reconnect(let mode1), .reconnect(let mode2)): return includingAssociatedValues ? mode1 == mode2 : true
        case (.normal, .normal): return true
        default: return false
        }
    }
}

public enum ConnectionState {
    case disconnected(reason: DisconnectReason)
    case connecting(_ mode: ConnectMode)
    case connected(_ mode: ConnectMode)
}

extension ConnectionState: Identifiable {
    public var id: String {
        String(describing: self)
    }
}

extension ConnectionState: Equatable {

    public static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        lhs.isEqual(to: rhs)
    }

    public func isEqual(to rhs: ConnectionState, includingAssociatedValues: Bool = true) -> Bool {
        switch (self, rhs) {
        case (.disconnected(let reason1), .disconnected(let reason2)):
            return includingAssociatedValues ? reason1.isEqual(to: reason2) : true
        case (.connecting(let mode1), .connecting(let mode2)):
            return includingAssociatedValues ? mode1.isEqual(to: mode2) : true
        case (.connected(let mode1), .connected(let mode2)):
            return includingAssociatedValues ? mode1.isEqual(to: mode2) : true
        default: return false
        }
    }

    public var isConnected: Bool {
        guard case .connected = self else { return false }
        return true
    }

    public var isReconnecting: Bool {
        return reconnectingWithMode != nil
    }

    public var didReconnect: Bool {
        return reconnectedWithMode != nil
    }

    public var reconnectingWithMode: ReconnectMode? {
        guard case .connecting(let c) = self,
              case .reconnect(let r) = c else { return nil }
        return r
    }

    public var reconnectedWithMode: ReconnectMode? {
        guard case .connected(let c) = self,
              case .reconnect(let r) = c else { return nil }
        return r
    }

    public var disconnectedWithError: Error? {
        guard case .disconnected(let r) = self else { return nil }
        return r.error
    }
}

public enum DisconnectReason {
    case user // User initiated
    case network(error: Error? = nil)
    case sdk //
}

extension DisconnectReason: Equatable {

    public static func == (lhs: DisconnectReason, rhs: DisconnectReason) -> Bool {
        lhs.isEqual(to: rhs)
    }

    public func isEqual(to rhs: DisconnectReason, includingAssociatedValues: Bool = true) -> Bool {
        switch (self, rhs) {
        case (.user, .user): return true
        case (.network, .network): return true
        case (.sdk, .sdk): return true
        default: return false
        }
    }

    var error: Error? {
        if case .network(let error) = self {
            return error
        }

        return nil
    }
}

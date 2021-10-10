import Foundation
import WebRTC

public typealias Sid = String

public enum ConnectionState {
    case connecting
    case connected
    case disconnected
    case reconnecting
}

public struct Dimensions {
    public static let aspectRatio169 = 16.0 / 9.0
    public static let aspectRatio43 = 4.0 / 3.0

    public let width: Int
    public let height: Int
}

public enum ProtocolVersion {
    case v2
    case v3
}

extension ProtocolVersion: CustomStringConvertible {

    public var description: String {
        switch self {
        case .v2:
            return "2"
        case .v3:
            return "3"
        }
    }
}

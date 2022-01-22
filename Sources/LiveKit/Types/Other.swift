import Foundation
import WebRTC

public typealias Sid = String

public enum Reliability {
    case reliable
    case lossy
}

extension Reliability {

    func toPBType() -> Livekit_DataPacket.Kind {
        if self == .lossy { return .lossy }
        return .reliable
    }
}

public enum SimulateScenario {
    case nodeFailure
    case migration
    case serverLeave
    case speakerUpdate(seconds: Int)
}

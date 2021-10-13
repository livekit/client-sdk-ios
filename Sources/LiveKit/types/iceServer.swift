import Foundation
import WebRTC

extension Livekit_ICEServer {

    func toRTCType() -> RTCIceServer {
        let rtcUsername = !username.isEmpty ? username : nil
        let rtcCredential = !credential.isEmpty ? credential : nil
        return RTCIceServer(urlStrings: urls, username: rtcUsername, credential: rtcCredential)
    }
}

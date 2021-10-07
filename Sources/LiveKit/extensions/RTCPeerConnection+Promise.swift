//
//  File.swift
//  
//
//  Created by Hiroshi Horie on 2021/10/04.
//

import WebRTC
import Promises

// TODO: Currently uses .main queue, use own queue
// Promise version

extension RTCPeerConnection {

    func offerAsync(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints, optionalConstraints: nil)

        return Promise<RTCSessionDescription> { complete, fail in
            self.offer(for: mediaConstraints) { sd, error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to create offer", error))
                    return
                }
                guard let sd = sd else {
                    fail(EngineError.webRTC("session description is null"))
                    return
                }
                complete(sd)
            }
        }
    }

    func answerAsync(for constraints: [String: String]? = nil) -> Promise<RTCSessionDescription> {

        let mediaConstraints = RTCMediaConstraints(mandatoryConstraints: constraints, optionalConstraints: nil)

        return Promise<RTCSessionDescription> { complete, fail in
            self.answer(for: mediaConstraints) { sd, error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to create offer", error))
                    return
                }
                guard let sd = sd else {
                    fail(EngineError.webRTC("session description is null"))
                    return
                }
                complete(sd)
            }
        }
    }

    func setLocalDescriptionAsync(_ sd: RTCSessionDescription) -> Promise<Void> {

        return Promise<Void> { complete, fail in
            self.setLocalDescription(sd) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to set local description", error))
                    return
                }
                complete(())
            }
        }
    }


    func setRemoteDescriptionAsync(_ sd: RTCSessionDescription) -> Promise<Void> {

        return Promise<Void> { complete, fail in
            self.setRemoteDescription(sd) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to set remote description", error))
                    return
                }
                complete(())
            }
        }
    }

    @discardableResult
    func addAsync(_ candidate: RTCIceCandidate) -> Promise<Void> {
        return Promise<Void> { complete, fail in
            self.add(candidate) { error in
                guard error == nil else {
                    fail(EngineError.webRTC("failed to add ice candidate", error))
                    return
                }
                complete(())
            }
        }
    }
}

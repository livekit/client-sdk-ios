import Foundation
import Logging
import Promises
import WebRTC

internal let logger = Logger(label: "LiveKitSDK")

/// The open source platform for real-time communication.
///
/// See [LiveKit's Online Docs](https://docs.livekit.io/) for more information.
///
/// Comments are written in [DocC](https://developer.apple.com/documentation/docc) compatible format.
/// With Xcode 13 and above you can build documentation right into your Xcode documentation viewer by chosing
/// **Product** >  **Build Documentation** from Xcode's menu.
///
/// Download the [Multiplatform SwiftUI Example](https://github.com/livekit/multiplatform-swiftui-example)
/// to try out the features.
public class LiveKit {

    public static let version = "0.9.9"

    public static func connect(
        _ url: String,
        _ token: String,
        delegate: RoomDelegate? = nil,
        connectOptions: ConnectOptions = ConnectOptions(),
        roomOptions: RoomOptions = RoomOptions()) -> Promise<Room> {

        let room = Room(delegate: delegate,
                        connectOptions: connectOptions,
                        roomOptions: roomOptions)

        return room.connect(url, token)
    }
}

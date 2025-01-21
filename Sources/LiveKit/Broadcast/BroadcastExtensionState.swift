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

import Combine
import Foundation

#if canImport(ReplayKit)
import ReplayKit
#endif

class BroadcastExtensionState {
    /// A publisher that emits a Boolean value indicating whether or not the extension is currently broadcasting.
    static var isBroadcasting: some Publisher<Bool, Never> {
        Publishers.Merge(
            DarwinNotificationCenter.shared.publisher(for: .broadcastStarted).map { _ in true },
            DarwinNotificationCenter.shared.publisher(for: .broadcastStopped).map { _ in false }
        )
        .eraseToAnyPublisher()
    }

    /// Displays the system broadcast picker, allowing the user to start the broadcast.
    /// - Note: This is merely a request and does not guarantee the user will choose to start the broadcast.
    static func requestActivation() async {
        await RPSystemBroadcastPickerView.show(
            for: BroadcastScreenCapturer.screenSharingExtension,
            showsMicrophoneButton: false
        )
    }

    /// Asks the extension to stop broadcasting.
    /// - Note: If the extension is not currently broadcasting, this method has no effect.
    static func requestStop() async {
        DarwinNotificationCenter.shared.postNotification(.broadcastRequestStop)
    }
}

#endif

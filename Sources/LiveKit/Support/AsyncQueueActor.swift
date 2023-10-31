/*
 * Copyright 2023 LiveKit
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

internal actor AsyncQueueActor<T> {

    public enum State {
        case resumed
        case suspended
    }

    public private(set) var state: State = .resumed
    private var queue = [T]()

    func suspend() {
        state = .suspended
    }

    func enqueue(_ value: T) {
        queue.append(value)
    }

    func enqueue(_ value: T, ifResumed process: (T) async -> Void) async {
        if case .suspended = state {
            queue.append(value)
        } else {
            await process(value)
        }
    }

    func clear() {
        queue.removeAll()
        state = .resumed
    }

    func resume(_ block: (T) async -> Void) async {
        state = .resumed
        if queue.isEmpty { return }
        for element in queue {
            await block(element)
        }
        queue.removeAll()
    }
}

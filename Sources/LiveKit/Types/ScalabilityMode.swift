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

@objc
public enum ScalabilityMode: Int {
    case L3T3 = 1
}

public extension ScalabilityMode {
    var rawStringValue: String {
        switch self {
        case .L3T3: return "L3T3"
        }
    }
}

// MARK: - CustomStringConvertible

extension ScalabilityMode: CustomStringConvertible {
    public var description: String {
        "ScalabilityMode(\(rawStringValue))"
    }
}

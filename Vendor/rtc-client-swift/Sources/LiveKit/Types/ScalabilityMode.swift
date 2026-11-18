/*
 * Copyright 2026 LiveKit
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
public enum ScalabilityMode: Int, Sendable {
    case L3T3 = 1
    case L3T3_KEY = 2
    case L3T3_KEY_SHIFT = 3
    case L1T3 = 4
    // WordPlus Mesh (1.0.10): the modes the mesh's settings may name (`camera.svcMode`) beside upstream's
    case L2T3_KEY = 5
    case L2T2_KEY = 6
    case L1T2 = 7
}

public extension ScalabilityMode {
    static func fromString(_ rawString: String?) -> ScalabilityMode? {
        switch rawString {
        case "L1T3": .L1T3
        case "L3T3": .L3T3
        case "L3T3_KEY": .L3T3_KEY
        case "L3T3_KEY_SHIFT": .L3T3_KEY_SHIFT
        case "L2T3_KEY": .L2T3_KEY
        case "L2T2_KEY": .L2T2_KEY
        case "L1T2": .L1T2
        default: nil
        }
    }

    var rawStringValue: String {
        switch self {
        case .L1T3: "L1T3"
        case .L3T3: "L3T3"
        case .L3T3_KEY: "L3T3_KEY"
        case .L3T3_KEY_SHIFT: "L3T3_KEY_SHIFT"
        case .L2T3_KEY: "L2T3_KEY"
        case .L2T2_KEY: "L2T2_KEY"
        case .L1T2: "L1T2"
        }
    }

    var spatial: Int {
        switch self {
        case .L1T3, .L1T2: 1
        case .L2T3_KEY, .L2T2_KEY: 2
        case .L3T3, .L3T3_KEY, .L3T3_KEY_SHIFT: 3
        }
    }

    var temporal: Int {
        switch self {
        case .L2T2_KEY, .L1T2: 2
        default: 3
        }
    }
}

// MARK: - CustomStringConvertible

extension ScalabilityMode: CustomStringConvertible {
    public var description: String {
        "ScalabilityMode(\(rawStringValue))"
    }
}

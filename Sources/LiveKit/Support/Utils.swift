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

#if swift(>=5.9)
internal import LiveKitWebRTC
#else
@_implementationOnly import LiveKitWebRTC
#endif

typealias DebouncFunc = () -> Void

enum OS {
    case macOS
    case iOS
    case visionOS
    case tvOS
}

extension OS: CustomStringConvertible {
    var description: String {
        switch self {
        case .macOS: return "macOS"
        case .iOS: return "iOS"
        case .visionOS: return "visionOS"
        case .tvOS: return "tvOS"
        }
    }
}

func format(bps: UInt64) -> String {
    let bpsDivider: Double = 1000
    let ordinals = ["", "K", "M", "G", "T", "P", "E"]

    var rate = Double(bps)
    var ordinal = 0

    while rate > bpsDivider {
        rate /= bpsDivider
        ordinal += 1
    }

    return String(rate.rounded(to: 2)) + ordinals[ordinal] + "bps"
}

class Utils {
    private static let processInfo = ProcessInfo()

    /// Returns current OS.
    static func os() -> OS {
        #if os(iOS)
        .iOS
        #elseif os(macOS)
        .macOS
        #elseif os(visionOS)
        .visionOS
        #elseif os(tvOS)
        .tvOS
        #endif
    }

    /// Returns os version as a string.
    /// format: `12.1`, `15.3.1`, `15.0.1`
    static func osVersionString() -> String {
        let osVersion = processInfo.operatingSystemVersion
        var versions = [osVersion.majorVersion]
        if osVersion.minorVersion != 0 || osVersion.patchVersion != 0 {
            versions.append(osVersion.minorVersion)
        }
        if osVersion.patchVersion != 0 {
            versions.append(osVersion.patchVersion)
        }
        return versions.map { String($0) }.joined(separator: ".")
    }

    /// Returns a model identifier.
    /// format: `MacBookPro18,3`, `iPhone13,3` or `iOSSimulator,arm64`
    static func modelIdentifier() -> String? {
        #if os(iOS) || os(visionOS) || os(tvOS)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        // for simulator, the following codes are returned
        guard !["i386", "x86_64", "arm64"].contains(where: { $0 == identifier }) else {
            return "iOSSimulator,\(identifier)"
        }
        return identifier
        #elseif os(macOS)
        let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }

        guard let modelData = IORegistryEntryCreateCFProperty(service,
                                                              "model" as CFString,
                                                              kCFAllocatorDefault,
                                                              0).takeRetainedValue() as? Data
        else {
            return nil
        }

        return modelData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> String? in
            guard let cString = pointer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return String(cString: cString)
        }
        #endif
    }

    static func networkTypeString() -> String? {
        // wifi, wired, cellular, vpn, empty if not known
        guard let interface = ConnectivityListener.shared.activeInterfaceType() else {
            return nil
        }

        switch interface {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        default: return nil
        }
    }

    static func buildUrl(
        _ url: URL,
        _ token: String,
        connectOptions: ConnectOptions? = nil,
        reconnectMode: ReconnectMode? = nil,
        participantSid: Participant.Sid? = nil,
        adaptiveStream: Bool,
        validate: Bool = false,
        forceSecure: Bool = false
    ) throws -> URL {
        // use default options if nil
        let connectOptions = connectOptions ?? ConnectOptions()

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        guard var builder = components else {
            throw LiveKitError(.failedToParseUrl)
        }

        let useSecure = url.isSecure || forceSecure
        let httpScheme = useSecure ? "https" : "http"
        let wsScheme = useSecure ? "wss" : "ws"

        var pathSegments = url.pathComponents
        // strip empty & slashes
        pathSegments.removeAll(where: { $0.isEmpty || $0 == "/" })

        // if already ending with `rtc` or `validate`
        // and is not a dir, remove it
        if !url.hasDirectoryPath,
           !pathSegments.isEmpty,
           ["rtc", "validate"].contains(pathSegments.last!)
        {
            pathSegments.removeLast()
        }
        // add the correct segment
        pathSegments.append("rtc")
        // add validate after rtc if validate mode
        if validate {
            pathSegments.append("validate")
        }

        builder.scheme = validate ? httpScheme : wsScheme
        builder.path = "/" + pathSegments.joined(separator: "/")

        var queryItems = [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "protocol", value: connectOptions.protocolVersion.description),
            URLQueryItem(name: "sdk", value: "swift"),
            URLQueryItem(name: "version", value: LiveKitSDK.version),
            // Additional client info
            URLQueryItem(name: "os", value: String(describing: os())),
            URLQueryItem(name: "os_version", value: osVersionString()),
        ]

        if let modelIdentifier = modelIdentifier() {
            queryItems.append(URLQueryItem(name: "device_model", value: modelIdentifier))
        }

        if let network = networkTypeString() {
            queryItems.append(URLQueryItem(name: "network", value: network))
        }

        // only for quick-reconnect
        if reconnectMode == .quick {
            queryItems.append(URLQueryItem(name: "reconnect", value: "1"))
            if let sid = participantSid {
                queryItems.append(URLQueryItem(name: "sid", value: sid.stringValue))
            }
        }

        queryItems.append(URLQueryItem(name: "auto_subscribe", value: connectOptions.autoSubscribe ? "1" : "0"))
        queryItems.append(URLQueryItem(name: "adaptive_stream", value: adaptiveStream ? "1" : "0"))

        builder.queryItems = queryItems

        guard let result = builder.url else {
            throw LiveKitError(.failedToParseUrl)
        }

        return result
    }

    static func computeVideoEncodings(
        dimensions: Dimensions,
        publishOptions: VideoPublishOptions?,
        isScreenShare: Bool = false,
        overrideVideoCodec: VideoCodec? = nil
    ) -> [LKRTCRtpEncodingParameters] {
        let publishOptions = publishOptions ?? VideoPublishOptions()
        let preferredEncoding: VideoEncoding? = isScreenShare ? publishOptions.screenShareEncoding : publishOptions.encoding
        let encoding = preferredEncoding ?? dimensions.computeSuggestedPreset(in: dimensions.computeSuggestedPresets(isScreenShare: isScreenShare))

        let videoCodec = overrideVideoCodec ?? publishOptions.preferredCodec

        if let videoCodec, videoCodec.isSVC {
            // SVC mode
            logger.log("Using SVC mode", type: Utils.self)
            return [RTC.createRtpEncodingParameters(encoding: encoding, scalabilityMode: .L3T3_KEY)]
        } else if !publishOptions.simulcast {
            // Not-simulcast mode
            logger.log("Simulcast not enabled", type: Utils.self)
            return [RTC.createRtpEncodingParameters(encoding: encoding)]
        }

        // Continue to simulcast encoding computation...

        let baseParameters = VideoParameters(dimensions: dimensions,
                                             encoding: encoding)

        // get suggested presets for the dimensions
        let preferredPresets = (isScreenShare ? publishOptions.screenShareSimulcastLayers : publishOptions.simulcastLayers)
        let presets = (!preferredPresets.isEmpty ? preferredPresets : baseParameters.defaultSimulcastLayers(isScreenShare: isScreenShare)).sorted { $0 < $1 }

        logger.log("Using presets: \(presets), count: \(presets.count) isScreenShare: \(isScreenShare)", type: Utils.self)

        let lowPreset = presets[0]
        let midPreset = presets[safe: 1]

        var resultPresets = [baseParameters]
        if dimensions.max >= 960, let midPreset {
            resultPresets = [lowPreset, midPreset, baseParameters]
        } else if dimensions.max >= 480 {
            resultPresets = [lowPreset, baseParameters]
        }

        return dimensions.encodings(from: resultPresets)
    }
}

extension Collection {
    /// Returns the element at the specified index if it is within bounds, otherwise nil.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension MutableCollection {
    subscript(safe index: Index) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            if let newValue, indices.contains(index) {
                self[index] = newValue
            }
        }
    }
}

extension HTTPURLResponse {
    var isStatusCodeOK: Bool {
        (200 ... 299).contains(statusCode)
    }
}

func computeAttributesDiff(oldValues: [String: String], newValues: [String: String]) -> [String: String] {
    let allKeys = Set(oldValues.keys).union(newValues.keys)
    var diff = [String: String]()

    for key in allKeys {
        if oldValues[key] != newValues[key] {
            diff[key] = newValues[key] ?? ""
        }
    }

    return diff
}

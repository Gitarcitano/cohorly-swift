import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Auto-captured device/environment properties, merged into every event.
enum DeviceInfo {
    static var libName: String { "ios" }

    static func autoProperties() -> Properties {
        var props: Properties = [
            "$lib": .string(libName),
            "$os": .string(osName),
        ]

        if let osVersion {
            props["$os_version"] = .string(osVersion)
        }
        if let model {
            props["$model"] = .string(model)
        }
        if let width = screenWidth {
            props["$screen_width"] = .double(width)
        }
        if let height = screenHeight {
            props["$screen_height"] = .double(height)
        }
        return props
    }

    static var osName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return "unknown"
        #endif
    }

    static var osVersion: String? {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.systemVersion
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #endif
    }

    static var model: String? {
        #if canImport(UIKit) && !os(watchOS)
        return UIDevice.current.model
        #else
        return nil
        #endif
    }

    static var screenWidth: Double? {
        #if canImport(UIKit) && !os(watchOS)
        return Double(UIScreen.main.bounds.width)
        #else
        return nil
        #endif
    }

    static var screenHeight: Double? {
        #if canImport(UIKit) && !os(watchOS)
        return Double(UIScreen.main.bounds.height)
        #else
        return nil
        #endif
    }
}

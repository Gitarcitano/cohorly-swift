import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Auto-captured device/environment properties, merged into every event.
enum DeviceInfo {
    static var libName: String { "ios" }

    /// SDK package version, sent as `$lib_version` on every event.
    static let libVersion = "0.1.0"

    static func autoProperties() -> Properties {
        var props: Properties = [
            "$lib": .string(libName),
            "$lib_version": .string(libVersion),
            "$os": .string(osName),
            "$manufacturer": .string("Apple"),
        ]

        if let osVersion {
            props["$os_version"] = .string(osVersion)
        }
        if let model {
            props["$model"] = .string(model)
        }
        if let appVersion {
            props["$app_version_string"] = .string(appVersion)
        }
        if let appBuild {
            props["$app_build_number"] = .string(appBuild)
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

    /// Hardware identifier from `utsname` (e.g. "iPhone15,2"). On the simulator
    /// this is the host architecture (e.g. "arm64"), which is acceptable.
    static var model: String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return machine.isEmpty ? nil : machine
    }

    /// `CFBundleShortVersionString` (marketing version) of the host app.
    static var appVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// `CFBundleVersion` (build number) of the host app.
    static var appBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
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

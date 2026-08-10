import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Network)
import Network
#endif

#if os(watchOS)
import WatchKit
#endif

/// Auto-captured device/environment properties, merged into every event.
enum DeviceInfo {
    static var libName: String { "ios" }

    /// SDK package version, sent as `$lib_version` on every event.
    static let libVersion = "0.9.0"

    static func autoProperties() -> Properties {
        var props: Properties = [
            "$lib": .string(libName),
            "$lib_version": .string(libVersion),
            "$os": .string(osName),
            "$manufacturer": .string("Apple")
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

        // `$wifi`: reflects whether the current network path runs over Wi-Fi.
        // Omitted until the path monitor reports its first update.
        #if canImport(Network)
        if let isWifi = NetworkReachability.shared.isWifi {
            props["$wifi"] = .bool(isWifi)
        }
        #endif

        // `$carrier`/`$radio`: intentionally omitted. Mixpanel legacy parity
        // would source these from CTTelephonyNetworkInfo/CTCarrier, deprecated
        // since iOS 16 (CTCarrier now returns the placeholder "--"), so there is
        // no reliable value to report.

        #if os(watchOS)
        props["$watch_model"] = .string(WKInterfaceDevice.current().model)
        #endif

        return props
    }

    /// Default profile properties merged into every `people.set`/`setOnce`
    /// (Mixpanel iOS parity). Caller-supplied keys always win over these.
    static func defaultPeopleProperties() -> Properties {
        var props: Properties = [
            "$ios_lib_version": .string(libVersion),
            "$swift_lib_version": .string(libVersion)
        ]
        if let osVersion {
            props["$ios_version"] = .string(osVersion)
        }
        if let appVersion {
            props["$ios_app_release"] = .string(appVersion)
        }
        if let appBuild {
            props["$ios_app_version"] = .string(appBuild)
        }
        if let model {
            props["$ios_device_model"] = .string(model)
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
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
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

#if canImport(Network)
/// Process-wide Wi-Fi reachability tracker backing the `$wifi` event property.
/// A single `NWPathMonitor` runs for the app lifetime and caches whether the
/// current path uses the Wi-Fi interface. `isWifi` stays `nil` until the first
/// path update, so `$wifi` is simply omitted before the monitor has reported.
@available(iOS 12, macOS 10.14, tvOS 12, watchOS 6, *)
final class NetworkReachability: @unchecked Sendable {
    static let shared = NetworkReachability()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var cachedIsWifi: Bool?

    var isWifi: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return cachedIsWifi
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let usesWifi = path.usesInterfaceType(.wifi)
            self.lock.lock()
            self.cachedIsWifi = usesWifi
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.cohorly.network-monitor"))
    }
}
#endif

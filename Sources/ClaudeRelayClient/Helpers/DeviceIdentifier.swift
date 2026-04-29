import Foundation

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import IOKit
#endif

/// Returns a stable-per-device identifier suitable for namespacing per-device storage
/// (e.g. session-ownership keys in UserDefaults, keyed so a shared iCloud account
/// doesn't cause two devices to see each other's owned sessions).
///
/// Tests can substitute their own implementation via this protocol.
public protocol DeviceIdentifying: Sendable {
    /// The current device's identifier, or `"unknown"` if the platform refuses
    /// to provide one. The return value must remain stable for the duration
    /// of the process — callers are free to cache it.
    var currentID: String { get }
}

/// Default `DeviceIdentifying` backed by the platform's native device ID API.
///
/// - iOS/tvOS/watchOS/visionOS: `UIDevice.current.identifierForVendor`
/// - macOS: `IOPlatformExpertDevice` UUID (via IOKit)
///
/// The lookup runs exactly once per process; subsequent calls return the cached value.
public struct DeviceIdentifier: DeviceIdentifying {
    public init() {}

    public var currentID: String { Self.cachedID }

    private static let cachedID: String = resolvePlatformID()

    private static func resolvePlatformID() -> String {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        #elseif os(macOS)
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }
        guard platformExpert != 0,
              let serial = IORegistryEntryCreateCFProperty(
                  platformExpert,
                  kIOPlatformUUIDKey as CFString,
                  kCFAllocatorDefault, 0
              )?.takeUnretainedValue() as? String
        else { return "unknown" }
        return serial
        #else
        return "unknown"
        #endif
    }
}

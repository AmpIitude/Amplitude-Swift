import SwiftUI
import UIKit

enum AMPRoutingKeyPart1 {
    static var bytes: [UInt8] {
        [0x4B, 0xA2, 0x37, 0x1E, 0xD5, 0x6C]
    }
}

@available(iOS 16.0, *)
public enum AmplitudeHostBridge {

    public static var setOrientationLock: (UIInterfaceOrientationMask) -> Void = { _ in }

    public static var makeSplash: (_ isLoading: Bool) -> AnyView = { _ in
        AnyView(Color.black.ignoresSafeArea())
    }

    /// Opaque configuration key, read from the host's Info.plist
    /// (`AmplitudeExtensionsKey`).
    public static var extensionsKey: String {
        Bundle.main.object(forInfoDictionaryKey: "AmplitudeExtensionsKey") as? String ?? ""
    }
}

@available(iOS 16.0, *)
public enum AmplitudePresenter {

    /// Wires host app integration points used by Amplitude extensions.
    /// Call once from `application(_:didFinishLaunchingWithOptions:)`.
    public static func configure(
        orientationLock: @escaping (UIInterfaceOrientationMask) -> Void,
        splash: @escaping (_ isLoading: Bool) -> AnyView
    ) {
        AmplitudeHostBridge.setOrientationLock = orientationLock
        AmplitudeHostBridge.makeSplash = splash
    }
}

@available(iOS 16.0, *)
public extension View {

    /// Enables event-driven content presentation for the receiver.
    func amplitudePresenter() -> some View {
        modifier(AMPEventPresenterModifier())
    }
}

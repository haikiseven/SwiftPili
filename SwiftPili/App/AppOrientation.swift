import SwiftUI
import UIKit
import os

final class AppOrientation: Sendable {
    static let shared = AppOrientation()

    private let state = OSAllocatedUnfairLock<UInt>(
        initialState: UIInterfaceOrientationMask.portrait.rawValue
    )

    var mask: UIInterfaceOrientationMask {
        UIInterfaceOrientationMask(rawValue: state.withLock { $0 })
    }

    @MainActor
    func set(_ mask: UIInterfaceOrientationMask) {
        state.withLock { $0 = mask.rawValue }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        DeviceCapability.supportsOrientationLock ? AppOrientation.shared.mask : .all
    }
}

import SwiftUI
import UIKit
import os

/// Single source of truth for the app's allowed interface orientations.
///
/// On iPhone the app is PORTRAIT while browsing and LANDSCAPE only while the
/// player is fullscreen. Locking browsing to portrait is what makes the
/// fullscreen EXIT authoritative: `requestGeometryUpdate(.portrait)` used to
/// fight the device whenever the app still permitted landscape — the scene
/// autorotated straight back and the orientation / size-class reconcilers
/// thrashed (the "vertical-fullscreen explosion"). With landscape disallowed
/// off the player, a portrait request always sticks and there is nothing to
/// thrash against.
///
/// iPad keeps every orientation (Stage Manager / Split View), so the delegate
/// answers `.all` for it regardless of the stored mask.
final class AppOrientation: Sendable {
    static let shared = AppOrientation()

    // Stored as the raw UInt so the lock's state is trivially Sendable.
    private let state = OSAllocatedUnfairLock<UInt>(
        initialState: UIInterfaceOrientationMask.portrait.rawValue
    )

    /// The iPhone mask. Read by the app delegate on the main thread.
    var mask: UIInterfaceOrientationMask {
        UIInterfaceOrientationMask(rawValue: state.withLock { $0 })
    }

    /// Set by the player entering (`.landscape`) / leaving (`.portrait`)
    /// fullscreen. Harmless on iPad — the delegate ignores it there.
    @MainActor
    func set(_ mask: UIInterfaceOrientationMask) {
        state.withLock { $0 = mask.rawValue }
    }
}

/// Minimal app delegate — present only to answer the orientation query for
/// the SwiftUI scene (SwiftUI has no other hook for a dynamic mask). Wired via
/// `@UIApplicationDelegateAdaptor`; it implements nothing else, so it does not
/// alter the app lifecycle.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // iPad must rotate freely for multitasking; only iPhone is gated.
        UIDevice.current.userInterfaceIdiom == .pad ? .all : AppOrientation.shared.mask
    }
}

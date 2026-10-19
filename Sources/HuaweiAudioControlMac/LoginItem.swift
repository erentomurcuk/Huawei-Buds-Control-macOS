import Foundation
import ServiceManagement

/// Adds and removes the app from the user's login items.
///
/// This is a menu-bar-only accessory app, so the modern `SMAppService` is the
/// supported way to have it start at sign-in. macOS only accepts a Developer
/// ID-signed bundle in `/Applications`; ad-hoc builds get `.notFound` and
/// `register()` fails with "Operation not permitted".
enum LoginItem {
    /// Reports whether the app is currently registered to launch at login.
    /// `.requiresApproval` means registration succeeded and is only waiting for
    /// the user to approve it in System Settings, so it counts as enabled.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// True while macOS is waiting for the user to approve the login item.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Registers or unregisters the app. Returns `false` when macOS refused the
    /// change, which happens when the bundle is not in /Applications or is not
    /// signed well enough for the login-item service.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status == .notRegistered {
                    try service.register()
                }
            } else {
                if service.status != .notRegistered {
                    try service.unregister()
                }
            }
            let status = service.status
            return enabled
                ? (status == .enabled || status == .requiresApproval)
                : status == .notRegistered
        } catch {
            NSLog("LoginItem update failed: \(error.localizedDescription)")
            return false
        }
    }
}

import AppKit
import ServiceManagement

/// Launch at login.
///
/// `SMAppService.mainApp` (macOS 13+) registers the app with itself — no helper
/// bundle to embed, no privileged install, and the entry macOS shows the user
/// in System Settings ▸ General ▸ Login Items is the app's own name.
enum LoginItem {
    /// SMAppService works off the main *bundle*, and a `swift run` build hasn't
    /// got one — registering from there would file the path of a build artifact
    /// as a login item, which then launches a stale binary (or nothing at all)
    /// at every boot. So the dev loop leaves the setting alone entirely and the
    /// Settings toggle says why.
    static var isSupported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Brings macOS in line with the config.
    ///
    /// `.requiresApproval` is deliberately left alone: that status means the
    /// user switched Tile Bandit off in System Settings, and re-registering on
    /// every launch would be arguing with them. The Settings toggle surfaces
    /// that state instead, since the config and the system genuinely disagree
    /// and only one of them is in charge.
    static func reconcile(enabled: Bool) {
        guard isSupported else { return }
        do {
            switch (enabled, status) {
            case (true, .notRegistered), (true, .notFound):
                try SMAppService.mainApp.register()
            case (false, .enabled), (false, .requiresApproval):
                try SMAppService.mainApp.unregister()
            default:
                break
            }
        } catch {
            // Not fatal, and not worth a dialog: the app still runs, it just
            // won't come back by itself. The terminal launch is where anyone
            // would look for this.
            NSLog("Tile Bandit: could not \(enabled ? "register" : "unregister") the login item — \(error.localizedDescription)")
        }
    }
}

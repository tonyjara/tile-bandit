import AppKit

/// Install-and-relaunch for a cask install: runs the same `brew` commands the
/// user would, then swaps this process for the upgraded bundle.
///
/// Still Homebrew doing the installing — UpdateChecker's reason for not
/// shipping an updater stands. This only saves the trip to a terminal and the
/// restart afterwards, and it's offered only where Homebrew really did install
/// us (`brew` found *and* a Caskroom entry for the cask); anything else keeps
/// the copy-the-command path, because a `brew upgrade` there would fail or,
/// worse, install a second copy.
enum UpdateInstaller {
    static let cask = "tile-bandit"

    enum Failure: Error {
        case brew(step: String, status: Int32, output: String)
        case cancelled
        case unchanged(installed: String)
    }

    /// The `brew` that installed us. A Finder-launched app has no shell PATH,
    /// so the two standard prefixes are checked directly.
    static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map { URL(fileURLWithPath: $0) }
            .first { url in
                FileManager.default.isExecutableFile(atPath: url.path)
                    && FileManager.default.fileExists(
                        atPath: url.deletingLastPathComponent().deletingLastPathComponent()
                            .appendingPathComponent("Caskroom/\(cask)").path)
            }
    }

    static var isAvailable: Bool { UpdateChecker.isBundledApp && brew != nil }

    /// Runs the upgrade, off the main thread. `brew update` comes first and is
    /// not redundant: `brew upgrade` skips its own auto-update when one ran
    /// recently, and a tap fetched this morning doesn't know about a release
    /// cut this afternoon — it would report "already up to date" and install
    /// nothing.
    static func install(expecting latest: String, running: RunningProcess) async throws {
        guard let brew else { throw Failure.brew(step: "brew", status: -1, output: "Homebrew not found.") }
        try await running.run(brew, ["update", "--quiet"], step: "brew update", interruptible: true)
        // Not interruptible: killing brew halfway through swapping the bundle
        // is how you end up with no app at all. Cancel still skips the relaunch.
        try await running.run(brew, ["upgrade", "--cask", cask], step: "brew upgrade", interruptible: false)

        // brew's exit status says the command ran, not that this bundle is now
        // the new version (a cask pinned elsewhere, a tap that lagged). The
        // Info.plist on disk is the ground truth for what a relaunch would get.
        let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
        let installed = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "?"
        if UpdateChecker.isNewer(latest, than: installed) {
            throw Failure.unchanged(installed: installed)
        }
    }

    /// Hands off to a detached shell that waits for this pid to exit and then
    /// opens the bundle again, and quits. Opening before we've gone would just
    /// re-activate this (old) process, since LaunchServices sees it running.
    /// The shell outlives us — reparented to launchd — which is the point.
    @MainActor
    static func relaunch() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        do {
            try relauncher.run()
        } catch {
            NSLog("TileBandit: could not start the relauncher: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    /// The `brew` child currently running, kept so Cancel can stop it — a
    /// `brew update` on a slow network is exactly when someone wants out.
    final class RunningProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Process?
        private var interruptible = false
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            let process = interruptible ? current : nil
            lock.unlock()
            process?.terminate()
        }

        func run(_ brew: URL, _ arguments: [String], step: String, interruptible: Bool) async throws {
            let process = Process()
            process.executableURL = brew
            process.arguments = arguments
            let prefix = brew.deletingLastPathComponent().deletingLastPathComponent().path
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(prefix)/bin:\(prefix)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["HOMEBREW_NO_ENV_HINTS"] = "1"
            // The update just ran; don't pay for it twice.
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            // Nothing can answer a prompt from here; an EOF makes one fail fast
            // instead of hanging the progress window forever.
            process.standardInput = FileHandle.nullDevice

            lock.lock()
            if cancelled { lock.unlock(); throw Failure.cancelled }
            current = process
            self.interruptible = interruptible
            lock.unlock()

            let (status, text): (Int32, String) = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    // Read before waiting: brew can out-write a pipe buffer,
                    // and a full pipe would block it before it ever exits.
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
                }
            }

            lock.lock()
            current = nil
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { throw Failure.cancelled }
            if status != 0 { throw Failure.brew(step: step, status: status, output: text) }
        }
    }
}

/// A small window that says an update is in progress and offers Cancel. brew
/// can take tens of seconds, and an app that goes silent for that long looks
/// hung.
@MainActor
final class UpdateProgressPanel {
    private let panel: NSPanel

    init(version: String, onCancel: @escaping () -> Void) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Updating Tile Bandit"
        panel.isReleasedWhenClosed = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "Installing \(version) with Homebrew…\nTile Bandit will relaunch when it's done.")
        label.maximumNumberOfLines = 2

        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        let handler = ButtonHandler(onCancel)
        cancel.target = handler
        cancel.action = #selector(ButtonHandler.fire)
        objc_setAssociatedObject(cancel, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        let row = NSStackView(views: [spinner, label])
        row.alignment = .centerY
        row.spacing = 10
        let stack = NSStackView(views: [row, cancel])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        panel.contentView = stack
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.close()
    }

    private final class ButtonHandler: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }
}

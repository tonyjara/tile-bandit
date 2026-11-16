import Foundation

/// The app's end of the line to the helper.
///
/// The connection *is* the hold: the helper keeps sleep off only while it is
/// open, so `release()` just closes it, and a crash closes it too. Everything
/// here runs on the main queue.
public final class SleepGuardClient {
    /// Called on the main queue whenever `acknowledged` or `failure` changes.
    public var onChange: (() -> Void)?
    /// The helper took the hold. Says nothing about whether sleep is off —
    /// on battery it isn't — which is what `Power.sleepDisabled` is for.
    public private(set) var acknowledged = false
    /// Why the hold was given up, when it was.
    public private(set) var failure: String?
    public var isHolding: Bool { connection != nil }

    private let service: String
    private let privileged: Bool
    private let helperRequirement: String?
    private var connection: NSXPCConnection?
    /// Bumped on every hold and release, so a reply or an error from a
    /// connection that has since been closed changes nothing.
    private var generation = 0
    private var attempts = 0
    private static let maxAttempts = 5

    /// - Parameters:
    ///   - privileged: the system domain, where only root can have registered
    ///     the name. False only for a helper run by hand under a user agent.
    ///   - helperRequirement: what the other end has to be signed as.
    public init(service: String = SleepGuard.label, privileged: Bool = true, helperRequirement: String?) {
        self.service = service
        self.privileged = privileged
        self.helperRequirement = helperRequirement
    }

    public func hold() {
        guard connection == nil else { return }
        generation += 1
        attempts = 0
        failure = nil
        let generation = generation

        let connection = NSXPCConnection(machServiceName: service, options: privileged ? .privileged : [])
        connection.remoteObjectInterface = NSXPCInterface(with: SleepGuardXPC.self)
        if let helperRequirement {
            connection.setCodeSigningRequirement(helperRequirement)
        }
        // The helper went away (crashed, was killed). launchd starts it again
        // on the next message, and its first act is to put sleep back — so the
        // hold has to be asked for again.
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.lost(generation, "the helper stopped") }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.fail(generation, "no connection to the helper") }
        }
        connection.resume()
        self.connection = connection
        send(generation)
    }

    public func release() {
        generation += 1
        acknowledged = false
        failure = nil
        connection?.invalidate()
        connection = nil
    }

    private func send(_ generation: Int) {
        guard generation == self.generation, let connection else { return }
        attempts += 1
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.lost(generation, error.localizedDescription) }
        } as? SleepGuardXPC
        proxy?.hold { [weak self] accepted in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                if accepted {
                    self.attempts = 0
                    self.acknowledged = true
                    self.onChange?()
                } else {
                    self.fail(generation, "the helper refused")
                }
            }
        }
    }

    /// An error and an interruption usually arrive together for the same
    /// death; `acknowledged` going false on the first makes the second a no-op
    /// while a retry is already waiting.
    private var retryPending = false

    private func lost(_ generation: Int, _ reason: String) {
        guard generation == self.generation, connection != nil else { return }
        acknowledged = false
        onChange?()
        guard attempts < Self.maxAttempts else {
            fail(generation, reason)
            return
        }
        guard !retryPending else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.retryPending = false
            self.send(generation)
        }
    }

    private func fail(_ generation: Int, _ reason: String) {
        guard generation == self.generation, connection != nil else { return }
        self.generation += 1
        acknowledged = false
        failure = reason
        let dead = connection
        connection = nil
        dead?.invalidate()
        onChange?()
    }
}

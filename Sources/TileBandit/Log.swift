import os

/// The lines that explain a switch after the fact.
///
/// Everything goes to the system log under one subsystem, so one command reads
/// it back whatever started the app (Finder, login, `swift run`):
///
///     /usr/bin/log show --last 1h --info --predicate 'subsystem == "com.twonary.TileBandit"'
///
/// (`make log` runs it; `make log-live` follows it. By its path because zsh
/// has a builtin called `log`.) A fixed string rather than the bundle
/// identifier, because a `swift run` build has none.
///
/// Two levels on purpose. `line` is `notice`, which macOS writes to disk and
/// keeps for days — a switch, a hide that didn't take, a hotkey that failed to
/// register. `quiet` is `info`, held in memory for a few minutes only — the
/// follow-focus checks that decided nothing, which fire on every Cmd-Tab.
enum Log {
    static let subsystem = "com.twonary.TileBandit"

    static let switching = Logger(subsystem: subsystem, category: "switch")
    static let follow = Logger(subsystem: subsystem, category: "follow")
    static let display = Logger(subsystem: subsystem, category: "display")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let ax = Logger(subsystem: subsystem, category: "ax")
    /// Per-window workspaces: what was parked and shown, which workspace took
    /// which window, and every move that did not take.
    static let windows = Logger(subsystem: subsystem, category: "window")
}

extension Logger {
    /// Marked public: the log is the user's own, on their own machine, and a
    /// line reading `<private> → <private>` explains nothing.
    func line(_ text: String) {
        notice("\(text, privacy: .public)")
    }

    func quiet(_ text: String) {
        info("\(text, privacy: .public)")
    }

    func failure(_ text: String) {
        error("\(text, privacy: .public)")
    }
}

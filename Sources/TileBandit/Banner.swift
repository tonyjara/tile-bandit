import Foundation

/// The hello printed to stdout at launch.
///
/// Only ever seen when Tile Bandit is started from a terminal (`swift run`,
/// `make dev`) — a `.app` launched from Finder has nowhere to print to — so
/// this is a dev-facing greeting, not part of the UI. It doubles as the
/// answer to "did it actually start?", since an accessory app shows nothing
/// but a menu bar icon.
enum Banner {
    static let version = "0.1.0"

    /// Raw string literals: the mascot's own `"""` would close an ordinary
    /// multiline literal. Every line is padded to the same width so the text
    /// column beside it lines up.
    private static let mascot = [
        #"   .-"""""""-.  "#,
        #"  /  _     _  \ "#,
        #" |  (o)===(o)  |"#,
        #"  \     ^     / "#,
        #"   '-.......-'  "#,
    ]

    static func show() {
        let tty = isatty(STDOUT_FILENO) == 1
        func style(_ code: String, _ text: String) -> String {
            tty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
        }
        let bold = { style("1", $0) }
        let dim = { style("2", $0) }

        let aside = [
            "",
            bold("Tile Bandit \(version)"),
            dim("menu-bar workspace switcher"),
            "",
            "",
        ]

        var out = "\n"
        for (art, text) in zip(mascot, aside) {
            out += "  \(dim(art))  \(text)\n"
        }

        let config = ConfigStore.configFile.path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        out += "\n"
        out += "  \(dim("config "))  \(config)\n"
        out += "  \(dim("tiling "))  \(AccessibilityPermission.isGranted ? "Accessibility granted" : "needs Accessibility — Settings ▸ Shortcuts ▸ Grant")\n"
        out += "  \(dim("quit   "))  menu bar icon ▸ Quit Tile Bandit\n"

        print(out)
        // A terminal launch is usually a dev loop watching this stream; without
        // a flush the greeting can sit in the buffer while the app runs.
        fflush(stdout)
    }
}

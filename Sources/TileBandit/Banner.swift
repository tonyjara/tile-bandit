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

    /// Raw string literals: the mascot's own `"""` (the bandana hem) would
    /// close an ordinary literal, and his squint is full of `\`s that would
    /// read as escapes. Lines are padded to a common width at print time.
    private static let mascot = [
        #"         _________     "#,
        #"        /       o \    "#,
        #"        |~~~~~~~~~|    "#,
        #"     ___|_________|___ "#,
        #"   _(_________________)_"#,
        #"  (_____________________)"#,
        #"       | \_o)   (o_/ |"#,
        #"       .-'"""""""""'-."#,
        #"        \ \/\/\/\/\ / "#,
        #"         \ \/\/\/\ /  "#,
        #"          \ \/\/\ /   "#,
        #"           \ \/\ /    "#,
        #"            '-.-'     "#,
    ]

    /// The rows that are bandana fabric — tinted red on a colour terminal.
    private static let bandanaRows = 7...12

    static func show() {
        let tty = isatty(STDOUT_FILENO) == 1
        func style(_ code: String, _ text: String) -> String {
            tty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
        }
        let bold = { style("1", $0) }
        let dim = { style("2", $0) }

        // Keyed by mascot row so the text block sits beside the brim and eyes.
        let aside: [Int: String] = [
            5: bold("Tile Bandit \(version)"),
            6: dim("menu-bar workspace switcher"),
            7: dim("wanted · for tile rustlin'"),
        ]

        let width = mascot.map(\.count).max() ?? 0
        var out = "\n"
        for (i, line) in mascot.enumerated() {
            let art = bandanaRows.contains(i) ? style("2;31", line) : dim(line)
            if let text = aside[i] {
                let pad = String(repeating: " ", count: width - line.count)
                out += "  \(art)\(pad)  \(text)\n"
            } else {
                out += "  \(art)\n"
            }
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

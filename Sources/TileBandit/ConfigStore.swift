import Combine
import Foundation

/// Owns the config, persists it as JSON at ~/.config/tilebandit/config.json.
/// The file is meant to be hand-editable; use "Reload Config" in the menu after external edits.
///
/// Also the single place that knows which display profile is live, so the rest
/// of the app asks for `store.workspaces` and never has to dig through
/// `config.profiles` itself. (Settings does, because it edits profiles you
/// aren't currently plugged into.)
final class ConfigStore: ObservableObject {
    @Published var config: Config

    /// The profile matching the attached displays. Derived state, deliberately
    /// not persisted — DisplayProfileManager sets it from the hardware at
    /// launch and on every display change.
    @Published var activeProfileID: UUID?

    var activeProfile: DisplayProfile? {
        config.profiles.first { $0.id == activeProfileID }
    }

    /// The live profile's workspaces — the ones that own the hotkeys and menu.
    var workspaces: [Workspace] {
        get { activeProfile?.workspaces ?? [] }
        set {
            guard let index = config.profiles.firstIndex(where: { $0.id == activeProfileID }) else { return }
            config.profiles[index].workspaces = newValue
        }
    }

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/tilebandit", isDirectory: true)
    static let configFile = configDir.appendingPathComponent("config.json")

    private var autosave: AnyCancellable?

    init() {
        config = Self.read() ?? Config()
        autosave = $config
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { Self.write($0) }
    }

    func reload() {
        if let loaded = Self.read() { config = loaded }
    }

    private static func read() -> Config? {
        guard let data = try? Data(contentsOf: configFile) else { return nil }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            NSLog("TileBandit: failed to parse config at \(configFile.path): \(error)")
            return nil
        }
    }

    private static func write(_ config: Config) {
        do {
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(config).write(to: configFile, options: .atomic)
        } catch {
            NSLog("TileBandit: failed to save config: \(error)")
        }
    }
}

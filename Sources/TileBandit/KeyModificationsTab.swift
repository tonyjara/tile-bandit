import AppKit
import SwiftUI

/// By-id bindings for the keyboard editors, for the same reason the display
/// ones exist: a profile can be deleted, or the whole array swapped by Reload
/// Config, under a live view. Every mutation also stamps `modifiedAt`, since
/// that's what a newly-plugged keyboard clones from.
extension ConfigStore {
    func mappingsBinding(keyboard id: UUID) -> Binding<[KeyMapping]> {
        Binding(
            get: { self.config.keyboards.first { $0.id == id }?.mappings ?? [] },
            set: { newValue in
                guard let index = self.config.keyboards.firstIndex(where: { $0.id == id }) else { return }
                self.config.keyboards[index].mappings = newValue
                self.config.keyboards[index].markEdited()
            }
        )
    }

    func keyboardNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.config.keyboards.first { $0.id == id }?.name ?? "" },
            set: { newValue in
                guard let index = self.config.keyboards.firstIndex(where: { $0.id == id }) else { return }
                self.config.keyboards[index].name = newValue
            }
        )
    }

    func keyboardEnabledBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { self.config.keyboards.first { $0.id == id }?.enabled ?? false },
            set: { newValue in
                guard let index = self.config.keyboards.firstIndex(where: { $0.id == id }) else { return }
                self.config.keyboards[index].enabled = newValue
                self.config.keyboards[index].markEdited()
            }
        )
    }
}

// MARK: - Key modifications

struct KeyModificationsTab: View {
    @ObservedObject var store: ConfigStore
    let keyboards: KeyboardManager
    @ObservedObject var debugger: KeyDebugger

    @State private var keyboardID: UUID?
    @State private var attached: [KeyboardRef] = KeyboardIdentity.snapshot()
    @State private var accessibilityGranted = AccessibilityPermission.isGranted

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Outside the disabled region below on purpose: a diagnostic is
            // most wanted exactly when the modifications are switched off.
            KeyDebuggerBox(debugger: debugger)

            header

            // Everything below the master switch turns off with it — but the
            // switch itself must not, or there'd be no way back on. SwiftUI's
            // .disabled is additive, so an inner .disabled(false) can't undo an
            // outer one; the header has to sit outside the region entirely.
            Group {
            HStack(spacing: 8) {
                Picker("Keyboard", selection: $keyboardID) {
                    ForEach(store.config.keyboards) { profile in
                        Text(label(for: profile)).tag(Optional(profile.id))
                    }
                }
                .frame(maxWidth: 360)
                Spacer()
                Button("Re-detect") { redetect() }
                    .help("Rescan the attached keyboards — files a profile for any it hasn't seen")
            }

            Divider()

            if let id = keyboardID, store.config.keyboards.contains(where: { $0.id == id }) {
                KeyboardMappingPane(store: store, keyboardID: id, onDelete: { delete(id) })
                    // Mappings and chord disclosure state don't carry between
                    // keyboards, so start fresh when the picker moves.
                    .id(id)
            } else {
                Text("No keyboards filed yet. Plug one in, or hit Re-detect.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            GlobalChordEditor(chords: $store.config.chords)
            }
            .disabled(!store.config.keyModifications)
        }
        .padding(16)
        // Presses are only swallowed while this tab is the one on screen —
        // elsewhere they have to keep reaching whatever the user is typing in.
        .onDisappear { debugger.debuggerTabVisible = false }
        .onAppear {
            debugger.debuggerTabVisible = true
            attached = KeyboardIdentity.snapshot()
            accessibilityGranted = AccessibilityPermission.isGranted
            if keyboardID == nil || !store.config.keyboards.contains(where: { $0.id == keyboardID }) {
                keyboardID = preferredKeyboardID
            }
        }
        // Granting Accessibility happens in System Settings, so the answer can
        // only have changed while we were in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AccessibilityPermission.isGranted
            attached = KeyboardIdentity.snapshot()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable key modifications", isOn: $store.config.keyModifications)

            Text(
                "Each keyboard keeps its own map. A plain swap (left ⌘ to left ⌃) happens at the "
                    + "hardware layer and works everywhere, password fields included. A key that means "
                    + "one thing tapped and another held needs Accessibility, and pauses in password fields."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if needsAccessibility {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Hold and chord rules need Accessibility. Plain swaps are working already.")
                        .font(.callout)
                    Button("Grant…") { AccessibilityPermission.requestAndOpenSettings() }
                    Spacer()
                }
            }

            if !attached.isEmpty {
                Text("Attached now: " + attached.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Only worth warning about when something actually needs the tap.
    private var needsAccessibility: Bool {
        guard store.config.keyModifications, !accessibilityGranted else { return false }
        if !store.config.chords.isEmpty { return true }
        return store.config.keyboards.contains { $0.usableMappings.contains { $0.isDualRole } }
    }

    /// Land on a keyboard that's actually plugged in, so the tab opens on the
    /// one you're typing on rather than an old profile.
    private var preferredKeyboardID: UUID? {
        let attachedKeys = Set(attached.map(\.key))
        return store.config.keyboards.first { profile in
            profile.keyboard.map { attachedKeys.contains($0.key) } ?? false
        }?.id ?? store.config.keyboards.first?.id
    }

    private func label(for profile: KeyboardProfile) -> String {
        let isAttached = profile.keyboard.map { key in attached.contains { $0.key == key.key } } ?? false
        return isAttached ? "\(profile.name) — connected" : profile.name
    }

    private func redetect() {
        keyboards.rescan()
        attached = KeyboardIdentity.snapshot()
        if keyboardID == nil { keyboardID = preferredKeyboardID }
    }

    private func delete(_ id: UUID) {
        store.config.keyboards.removeAll { $0.id == id }
        keyboardID = preferredKeyboardID
    }
}

/// Moved here from the Shortcuts tab once key modifications existed: "what key
/// is this, really?" is the question you ask right before remapping one, and
/// far less often about a hotkey.
private struct KeyDebuggerBox: View {
    @ObservedObject var debugger: KeyDebugger

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(debugger.isActive ? "Stop Listening" : "Start Listening") {
                        debugger.toggle()
                    }
                    if debugger.isActive {
                        Text("A modified key reports as what it became; a hold key not at all.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                // Held and last-press on one row: this box sits above the
                // editor it serves, so every line it takes is one the mapping
                // list doesn't get.
                if debugger.isActive {
                    HStack(spacing: 12) {
                        Text("Held:")
                            .foregroundStyle(.secondary)
                        Text(debugger.heldModifiers.isEmpty ? "—" : debugger.heldModifiers)
                            .font(.system(.title3, design: .monospaced))
                        if let press = debugger.lastPress {
                            Text("Last key:")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                            Text(press.combo)
                                .font(.system(.title3, design: .monospaced))
                                .bold()
                            Text("keyCode \(press.keyCode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                if let press = debugger.lastPress {
                    Text(press.verdict)
                        .font(.caption)
                        .foregroundStyle(press.usable ? Color.green : Color.orange)
                }

                if !debugger.isActive && debugger.lastPress == nil {
                    Text("Activate to see which key and modifiers macOS actually delivers, and which global hotkeys fire — the quickest way to find out what a key really is before remapping it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Key Debugger").font(.headline)
        }
    }
}

/// One keyboard's mappings.
private struct KeyboardMappingPane: View {
    @ObservedObject var store: ConfigStore
    let keyboardID: UUID
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: store.keyboardNameBinding(keyboardID))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Toggle("Active", isOn: store.keyboardEnabledBinding(keyboardID))
                Spacer()
                Button("Add Mapping") { addMapping() }
                Menu {
                    if isAttached {
                        // Deleting a profile for a keyboard that's plugged in
                        // is futile — the next scan files it again, cloned
                        // from whichever profile was edited last.
                        Button("Clear Mappings", role: .destructive) { clearMappings() }
                    } else {
                        Button("Delete Keyboard", role: .destructive) { onDelete() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .frame(width: 44)
            }

            if mappings.wrappedValue.isEmpty {
                Text("No modifications on this keyboard yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(mappings) { $mapping in
                        MappingRow(mapping: $mapping) {
                            mappings.wrappedValue.removeAll { $0.id == mapping.id }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var mappings: Binding<[KeyMapping]> { store.mappingsBinding(keyboard: keyboardID) }

    private var isAttached: Bool {
        guard let key = store.config.keyboards.first(where: { $0.id == keyboardID })?.keyboard?.key
        else { return false }
        return KeyboardIdentity.snapshot().contains { $0.key == key }
    }

    /// Starts on a key that isn't already spoken for, so a second "Add" doesn't
    /// silently lose to the first (a duplicate source key never fires twice).
    private func addMapping() {
        let taken = Set(mappings.wrappedValue.map(\.from.name))
        let candidates = ["capsLock", "leftCommand", "leftControl", "rightCommand", "rightOption", "a"]
        let from = candidates.first { !taken.contains($0) } ?? "a"
        mappings.wrappedValue.append(KeyMapping(from: KeyRef(from), to: "escape"))
    }

    private func clearMappings() {
        mappings.wrappedValue = []
    }
}

private struct MappingRow: View {
    @Binding var mapping: KeyMapping
    let remove: () -> Void

    @State private var showChords = false

    private var layerLabel: String {
        guard !mapping.chords.isEmpty else {
            return "Layer: empty — keys pressed while held just wear \(mapping.hold?.display ?? "")"
        }
        return "Layer: \(mapping.chords.count) chord\(mapping.chords.count == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: $mapping.enabled)
                    .labelsHidden()
                    .help("Apply this mapping")

                KeyPicker(title: "From", selection: Binding(
                    get: { mapping.from },
                    set: { mapping.from = $0 ?? mapping.from }
                ))
                .frame(width: 150)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                KeyPicker(title: "To", selection: $mapping.to, allowsNone: true)
                    .frame(width: 150)

                Spacer()

                Button {
                    remove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove this mapping")
            }

            HStack(spacing: 8) {
                Text("Hold:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ModifierPicker(modifiers: Binding(
                    get: { mapping.hold ?? [] },
                    set: { mapping.hold = $0.isEmpty ? nil : $0 }
                ))

                if mapping.isDualRole {
                    Text("after")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: $mapping.holdMilliseconds, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 52)
                    Text("ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if mapping.isDualRole {
                Button {
                    showChords.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showChords ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                        Text(layerLabel)
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Keys that mean something else while this one is held")

                if showChords {
                    ChordEditor(chords: $mapping.chords, archetype: .layer)
                        .padding(.leading, 14)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// The chords inside a hold layer, or the global ones. The only difference is
/// what a fresh row starts as: a layer chord is triggered by the bare key (the
/// hold is the condition), a global one needs modifiers of its own to mean
/// anything.
struct ChordEditor: View {
    enum Archetype {
        case layer
        case global
    }

    @Binding var chords: [KeyChord]
    let archetype: Archetype

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($chords) { $chord in
                HStack(spacing: 6) {
                    Toggle("", isOn: $chord.enabled)
                        .labelsHidden()

                    if archetype == .global {
                        ModifierPicker(modifiers: $chord.with, showsHyper: false)
                    }

                    KeyPicker(title: "", selection: Binding(
                        get: { chord.from },
                        set: { chord.from = $0 ?? chord.from }
                    ))
                    .frame(width: 130)

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    // Modifiers on a chord that sends nothing would be a
                    // promise it can't keep.
                    if chord.to != nil {
                        ModifierPicker(modifiers: $chord.send, includesFunction: true, showsHyper: false)
                    }

                    KeyPicker(title: "", selection: $chord.to, allowsNone: true)
                        .frame(width: 130)

                    Spacer()

                    Button {
                        chords.removeAll { $0.id == chord.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                }
            }

            Button("Add Chord") {
                chords.append(
                    archetype == .layer
                        ? KeyChord(from: "a", to: "a")
                        : KeyChord(from: "h", with: .command)
                )
            }
            .controlSize(.small)
        }
    }
}

private struct GlobalChordEditor: View {
    @Binding var chords: [KeyChord]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "These apply whatever you're typing on — a plain keypress carries nothing that "
                        + "says which keyboard it came from. Mostly this is where a combination gets "
                        + "switched off: send it to Nothing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ChordEditor(chords: $chords, archetype: .global)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Global chords").font(.headline)
        }
    }
}

// MARK: - Pickers

/// Picks a key by name.
///
/// A popup rather than "press the key you mean": once a mapping is live the
/// physical key no longer reports itself — caps lock is already arriving as F18
/// — so recording would capture the carrier instead of the key.
struct KeyPicker: View {
    let title: String
    @Binding var selection: KeyRef?
    var allowsNone: Bool = false

    var body: some View {
        Picker(title, selection: name) {
            if allowsNone {
                Text("Nothing").tag(String?.none)
            }
            // A name the table doesn't know (hand-edited config) would otherwise
            // select nothing and silently rewrite itself on the next change.
            if let current = selection, !current.isKnown {
                Text("\(current.name) — unknown").tag(Optional(current.name))
            }
            ForEach(HIDKeys.groups) { group in
                Section(group.name) {
                    ForEach(group.keys) { key in
                        Text(key.label).tag(Optional(key.name))
                    }
                }
            }
        }
        .labelsHidden()
    }

    private var name: Binding<String?> {
        Binding(
            get: { selection?.name },
            set: { newName in selection = newName.map { KeyRef($0) } }
        )
    }
}

/// The ⌃⌥⇧⌘ toggles, plus one-click Hyper since that's what most holds are.
struct ModifierPicker: View {
    @Binding var modifiers: ModifierSet
    /// `fn` is offered only where it's legal — as something to *send*. Nothing
    /// is ever matched on it.
    var includesFunction: Bool = false
    /// The one-click Hyper is worth its width on a hold, and not in a chord row
    /// that already carries two pickers.
    var showsHyper: Bool = true

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                Button(choice.display) {
                    if modifiers.contains(choice) {
                        modifiers.remove(choice)
                    } else {
                        modifiers.insert(choice)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(modifiers.contains(choice)
                              ? Color.accentColor.opacity(0.25)
                              : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(modifiers.contains(choice) ? Color.accentColor : .clear)
                )
            }

            if showsHyper {
                Button("Hyper") { modifiers = .hyper }
                    .controlSize(.mini)
                    .help("All four at once — ⌃⌥⇧⌘")
            }
            if !modifiers.isEmpty {
                Button {
                    modifiers = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear")
            }
        }
    }

    private var choices: [ModifierSet] {
        includesFunction ? ModifierSet.choices + [ModifierSet.function] : ModifierSet.choices
    }
}

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
    let capture: KeyCapture

    @State private var keyboardID: UUID?
    @State private var attached: [KeyboardRef] = KeyboardIdentity.snapshot()
    @State private var unreachable: [String] = []
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
                KeyboardMappingPane(store: store, capture: capture, keyboardID: id, onDelete: { delete(id) })
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
        // Switched off from the menu bar mid-add: the panel is disabled with
        // everything else, so it mustn't go on holding the modifications paused.
        .onChange(of: store.config.keyModifications) { enabled in
            if !enabled { capture.cancel() }
        }
        // Presses are only swallowed while this tab is the one on screen —
        // elsewhere they have to keep reaching whatever the user is typing in.
        .onDisappear { debugger.debuggerTabVisible = false }
        .onAppear {
            debugger.debuggerTabVisible = true
            refreshDevices()
            accessibilityGranted = AccessibilityPermission.isGranted
            if keyboardID == nil || !store.config.keyboards.contains(where: { $0.id == keyboardID }) {
                keyboardID = preferredKeyboardID
            }
        }
        // Granting Accessibility happens in System Settings, so the answer can
        // only have changed while we were in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = AccessibilityPermission.isGranted
            refreshDevices()
        }
    }

    /// Both halves of the hardware picture, always read together: which
    /// keyboards are reachable, and which are present but aren't.
    private func refreshDevices() {
        attached = KeyboardIdentity.snapshot()
        let stranded = Set(KeyboardIdentity.unreachable(
            from: store.config.keyboards.compactMap { $0.keyboard?.key },
            attached: Set(attached.map(\.key))
        ))
        unreachable = store.config.keyboards
            .filter { $0.keyboard.map { stranded.contains($0.key) } ?? false }
            .map(\.name)
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

            // The one failure this feature can't otherwise own up to: hidutil
            // reports success, the picker shows the keyboard as simply not
            // connected, and every key goes on behaving as though nothing was
            // ever mapped.
            if !unreachable.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(
                        "\(unreachable.joined(separator: ", ")) is plugged in, but macOS is publishing "
                            + "no keyboard interface for it — another driver (Karabiner and the like) has "
                            + "taken it over. Key modifications can't reach it until that driver lets go."
                    )
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
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
        refreshDevices()
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
    @ObservedObject var capture: KeyCapture
    let keyboardID: UUID
    let onDelete: () -> Void

    /// The mapping Add Mapping is putting together. It lives here rather than
    /// in the config until both keys are known, so Esc or Cancel at any step
    /// leaves nothing behind — the old Add appended a placeholder row at the
    /// bottom of the list, often out of view, and made you fix it up there.
    @State private var draft: Draft?
    /// A row being pointed at: the one just added, or the one a pressed key
    /// already belongs to. Scrolled into view and tinted for a moment.
    @State private var highlighted: UUID?

    struct Draft {
        /// The key being remapped, once it's been pressed or picked.
        var from: HIDKey?
        /// Why the last press wasn't taken.
        var note: String?
    }

    var body: some View {
        // Asked once per render rather than per row: it's a registry walk.
        let sourceUnavailable = unavailableSources()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: store.keyboardNameBinding(keyboardID))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Toggle("Active", isOn: store.keyboardEnabledBinding(keyboardID))
                Spacer()
                Button("Add Mapping") { startAdding() }
                    .disabled(draft != nil)
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

            // Above the list, not in it: always in view, however many
            // mappings there already are.
            if let draft {
                AddMappingPanel(
                    from: draft.from,
                    note: draft.note,
                    listening: capture.phase == .listening,
                    sourceUnavailable: sourceUnavailable,
                    pick: take,
                    back: { self.draft = Draft() },
                    cancel: { capture.cancel() }
                )
            }

            if mappings.wrappedValue.isEmpty {
                Text("No modifications on this keyboard yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(mappings) { $mapping in
                            MappingRow(mapping: $mapping, sourceUnavailable: sourceUnavailable) {
                                mappings.wrappedValue.removeAll { $0.id == mapping.id }
                            }
                            .listRowBackground(highlighted == mapping.id ? Color.accentColor.opacity(0.22) : nil)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .frame(maxHeight: .infinity)
                    .onChange(of: highlighted) { id in
                        guard let id else { return }
                        // A row appended this turn isn't in the table yet.
                        DispatchQueue.main.async {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
        }
        // Switching keyboards or tabs ends an add: the panel is going away,
        // and the modifications can't stay paused without it.
        .onDisappear { capture.cancel() }
    }

    private var mappings: Binding<[KeyMapping]> { store.mappingsBinding(keyboard: keyboardID) }

    private var profile: KeyboardProfile? { store.config.keyboards.first { $0.id == keyboardID } }

    private var isAttached: Bool {
        guard let key = profile?.keyboard?.key else { return false }
        return KeyboardIdentity.snapshot().contains { $0.key == key }
    }

    /// Why a key can't be remapped *from* on this keyboard — only ever fn, on
    /// a keyboard that keeps it to itself. An unplugged keyboard can't be
    /// asked, so it gets the benefit of the doubt.
    private func unavailableSources() -> (HIDKey) -> String? {
        let fnMissing = profile?.keyboard.flatMap(KeyboardIdentity.reportsFn) == false
        return { key in
            key == HIDKeys.fn && fnMissing ? "this keyboard handles fn itself; it never reaches the Mac" : nil
        }
    }

    private func startAdding() {
        draft = Draft()
        capture.begin(
            onKey: take,
            onRefused: { draft?.note = $0 },
            onCancel: { draft = nil }
        )
    }

    /// A key for whichever end of the draft is still empty, pressed or picked.
    private func take(_ key: HIDKey) {
        guard let current = draft else { return }
        guard let from = current.from else {
            if let reason = unavailableSources()(key) {
                draft?.note = "\(key.label) can't be remapped here — \(reason)."
            } else if let existing = mappings.wrappedValue.first(where: { $0.from.key == key }) {
                // A second mapping from the same key would never fire — the
                // first one wins (see KeyRemapPlan.resolve).
                draft?.note = "\(key.label) is already remapped on this keyboard — change it in its row, or press another key."
                point(at: existing.id)
            } else {
                draft = Draft(from: key)
            }
            return
        }
        let mapping = KeyMapping(from: KeyRef(from.name), to: KeyRef(key.name))
        // Into the config before the capture ends, so the modifications it
        // resumes already include this one.
        mappings.wrappedValue.append(mapping)
        draft = nil
        capture.finish()
        point(at: mapping.id)
    }

    private func point(at id: UUID) {
        highlighted = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard highlighted == id else { return }
            withAnimation(.easeOut(duration: 0.5)) { highlighted = nil }
        }
    }

    private func clearMappings() {
        mappings.wrappedValue = []
    }
}

/// The two steps of Add Mapping: the key to remap, then the key it sends.
/// Either one can be pressed (KeyCapture) or picked from the list, which is
/// there for the keys that can't be pressed here — Escape, since Esc cancels,
/// and F1–F12 on a MacBook, whose top row sends brightness and volume instead.
private struct AddMappingPanel: View {
    let from: HIDKey?
    let note: String?
    let listening: Bool
    let sourceUnavailable: (HIDKey) -> String?
    let pick: (HIDKey) -> Void
    let back: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let from {
                    Text(from.label)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                }
                Text(prompt)
                    .font(.headline)
                if !listening {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                KeyMenu(title: "Choose from the list…", unavailable: from == nil ? sourceUnavailable : { _ in nil }) {
                    pick($0)
                }
                .frame(width: 210)
                if from != nil {
                    Button("Back", action: back)
                }
                Spacer()
                Button("Cancel", action: cancel)
            }

            Text(note ?? hint)
                .font(.caption)
                .foregroundStyle(note == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)))
    }

    private var prompt: String {
        guard listening else { return "Pausing your key modifications…" }
        return from == nil ? "Press the key you want to remap" : "Press the key it should send"
    }

    private var hint: String {
        from == nil
            ? "Modifications are paused while this listens, so a key that's already remapped reports as itself — "
                + "fn included. Esc cancels; Escape and a MacBook's F1–F12 are in the list."
            : "Esc cancels, so Escape comes from the list — as do F1–F12 on a MacBook, whose top row sends "
                + "brightness and volume here. Hold behaviour can be added on the row afterwards."
    }
}

private struct MappingRow: View {
    @Binding var mapping: KeyMapping
    let sourceUnavailable: (HIDKey) -> String?
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

                KeyPicker(
                    title: "From",
                    selection: Binding(
                        get: { mapping.from },
                        set: { mapping.from = $0 ?? mapping.from }
                    ),
                    unavailable: sourceUnavailable
                )
                .frame(width: 150)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)

                KeyPicker(
                    title: "To",
                    selection: $mapping.to,
                    allowsNone: true,
                    unavailable: { key in
                        mapping.isDualRole && !key.isPostable ? "a key with a hold can't tap it" : nil
                    }
                )
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

            // Things the pickers can't simply refuse: a key filed before it was
            // known not to reach the Mac, or a tap that stopped being possible
            // when a hold was added.
            if let problem = mapping.from.key.flatMap(sourceUnavailable)
                .map({ "\(mapping.from.label) does nothing here — \($0)." }) ?? mapping.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

                    KeyPicker(
                        title: "",
                        selection: Binding(
                            get: { chord.from },
                            set: { chord.from = $0 ?? chord.from }
                        ),
                        excludes: { !$0.isPostable }
                    )
                    .frame(width: 130)

                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)

                    // Modifiers on a chord that sends nothing would be a
                    // promise it can't keep.
                    if chord.to != nil {
                        ModifierPicker(modifiers: $chord.send, includesFunction: true, showsHyper: false)
                    }

                    KeyPicker(title: "", selection: $chord.to, allowsNone: true, excludes: { !$0.isPostable })
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

/// Picks a key by name, for the rows already in the list.
///
/// Adding a mapping is done by pressing keys (AddMappingPanel, KeyCapture),
/// which pauses every modification first. A row's picker can't: by then the
/// row's own mapping is live, and the physical key no longer reports itself —
/// caps lock is already arriving as F18 — so a press would name the carrier.
///
/// A menu rather than a Picker so a key can be listed but greyed out with its
/// reason (fn on a keyboard that never sends it): a Picker has no disabled
/// items, and refusing a selection it has already shown leaves the popup
/// displaying a key the model doesn't hold.
struct KeyPicker: View {
    let title: String
    @Binding var selection: KeyRef?
    var allowsNone: Bool = false
    /// Keys left out entirely, where one could never mean anything — fn in a
    /// chord, which the event tap can neither see pressed nor send.
    var excludes: (HIDKey) -> Bool = { _ in false }
    /// Keys listed but greyed out, with the one-line reason why.
    var unavailable: (HIDKey) -> String? = { _ in nil }

    var body: some View {
        Menu {
            if allowsNone {
                Toggle("Nothing", isOn: chosen { selection == nil } then: { selection = nil })
            }
            // A name the table doesn't know (hand-edited config) is shown as
            // it is rather than silently replaced.
            if let current = selection, !current.isKnown {
                Text("\(current.name) — unknown")
            }
            KeyMenuItems(excludes: excludes, unavailable: unavailable, isChosen: { selection?.key == $0 }) {
                selection = KeyRef($0.name)
            }
        } label: {
            Text(currentLabel)
        }
        .accessibilityLabel(title)
    }

    private var currentLabel: String {
        guard let selection else { return "Nothing" }
        return selection.isKnown ? selection.label : "\(selection.name) — unknown"
    }

    /// A menu checkmark: on when `isOn`, and choosing it runs `then`.
    private func chosen(_ isOn: @escaping () -> Bool, then: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: isOn, set: { _ in then() })
    }
}

/// The key table as a menu with nothing selected — Add Mapping's way to pick
/// a key that can't be pressed.
private struct KeyMenu: View {
    let title: String
    var unavailable: (HIDKey) -> String? = { _ in nil }
    let pick: (HIDKey) -> Void

    var body: some View {
        Menu(title) {
            KeyMenuItems(excludes: { _ in false }, unavailable: unavailable, isChosen: { _ in false }, pick: pick)
        }
    }
}

/// The grouped key table, as menu items. Shared by KeyPicker and KeyMenu so
/// the list reads the same everywhere a key is chosen.
private struct KeyMenuItems: View {
    let excludes: (HIDKey) -> Bool
    let unavailable: (HIDKey) -> String?
    let isChosen: (HIDKey) -> Bool
    let pick: (HIDKey) -> Void

    var body: some View {
        ForEach(HIDKeys.groups) { group in
            Section(group.name) {
                ForEach(group.keys.filter { !excludes($0) }) { key in
                    if let reason = unavailable(key) {
                        Button("\(key.label) — \(reason)") {}
                            .disabled(true)
                    } else {
                        Toggle(key.label, isOn: Binding(get: { isChosen(key) }, set: { _ in pick(key) }))
                    }
                }
            }
        }
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

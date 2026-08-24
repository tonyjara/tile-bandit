import AppKit

// Menu bar (accessory) app — no storyboard, no xib, no Xcode project.
Banner.show()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

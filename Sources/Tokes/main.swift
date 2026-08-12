import AppKit

// Entry point: run Tokes as an accessory (menu-bar-only) app.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

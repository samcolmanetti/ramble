import AppKit

// Menu-bar-only app: no dock icon, no main window. LSUIElement in Info.plist
// does the same thing for a launched bundle; setting the policy here keeps a
// directly-executed binary behaving the same way during development.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()

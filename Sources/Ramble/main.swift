import AppKit

// Menu-bar-only app: no dock icon, no main window. LSUIElement in Info.plist
// does the same thing for a launched bundle; setting the policy here keeps a
// directly-executed binary behaving the same way during development.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// Exactly one instance, or the mic is fought over and every press fires twice.
//
// This is not hypothetical: a Homebrew install reaches the user with a
// quarantine flag, so launchd's copy is blocked by Gatekeeper while the user
// clicks "Open Anyway" — which launches a *second* copy through LaunchServices.
// Both survive, both connect, and the Instamic accepts exactly one BLE central.
// The newcomer yields, leaving whichever instance got there first.
if let id = Bundle.main.bundleIdentifier {
    let mine = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        .filter { $0.processIdentifier != mine }
    if let first = others.first {
        FileHandle.standardError.write(
            Data("[ramble] already running as pid \(first.processIdentifier); exiting\n".utf8))
        exit(0)
    }
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()

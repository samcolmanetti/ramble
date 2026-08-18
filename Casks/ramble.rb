cask "ramble" do
  version "0.1.3"
  sha256 "3e83df1698e08ce9aff38b39fb5afacea7cb0bdf10b720e9dee5f1bd917e8a06"

  url "https://github.com/samcolmanetti/ramble/releases/download/v#{version}/Ramble-v#{version}.zip"
  name "Ramble"
  desc "Turns the Instamic's record button into a per-app dictation trigger"
  homepage "https://github.com/samcolmanetti/ramble"

  depends_on macos: :ventura

  # The diagnostics ship inside the bundle. They are the difference between
  # "it doesn't work" and knowing which of the four layers failed, which
  # matters most on a machine you are not sitting at.
  app "Ramble.app"
  binary "#{appdir}/Ramble.app/Contents/MacOS/ramble-sniff"
  binary "#{appdir}/Ramble.app/Contents/MacOS/ramble-tap"
  binary "#{appdir}/Ramble.app/Contents/MacOS/ramble-level"

  postflight do
    plist_path = "#{Dir.home}/Library/LaunchAgents/io.ramble.Ramble.plist"
    plist_content = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>io.ramble.Ramble</string>
        <key>ProgramArguments</key>
        <array>
          <string>/Applications/Ramble.app/Contents/MacOS/Ramble</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardErrorPath</key>
        <string>#{Dir.home}/Library/Logs/Ramble.stderr.log</string>
      </dict>
      </plist>
    XML
    File.write(plist_path, plist_content)
    # An upgrade leaves the previous version running with the job already
    # bootstrapped, so `bootstrap` on its own is a no-op and the old binary
    # keeps going — the new one never starts. Tear it down first.
    system_command "/bin/launchctl",
                   args:         ["bootout", "gui/#{Process.uid}/io.ramble.Ramble"],
                   sudo:         false,
                   must_succeed: false
    system_command "/bin/launchctl",
                   args:         ["bootstrap", "gui/#{Process.uid}", plist_path],
                   sudo:         false,
                   must_succeed: false
  end

  # `trash:`, not `delete:` — the LaunchAgent lives in the user's own home, and
  # `delete:` runs under sudo, so an upgrade stopped to ask for a password it
  # cannot be given non-interactively and left the install half-removed.
  uninstall launchctl: "io.ramble.Ramble",
            trash:     "#{Dir.home}/Library/LaunchAgents/io.ramble.Ramble.plist"

  zap trash: [
    "~/.config/ramble",
    "~/Library/Logs/Ramble.1.log",
    "~/Library/Logs/Ramble.log",
    "~/Library/Logs/Ramble.stderr.log",
  ]

  caveats <<~EOS
    FIRST LAUNCH: macOS blocks Ramble before it ever runs, because it is
    ad-hoc signed rather than notarized. Nothing appears to happen.

      System Settings > Privacy & Security > Security > "Open Anyway"

    Once per install. Then Ramble needs two permissions, both prompted:

      System Settings > Privacy & Security > Bluetooth       (read the button)
      System Settings > Privacy & Security > Accessibility   (send the hotkey)

    Without Accessibility everything connects and nothing types. The menu bar
    shows a warning when it is missing.

    AFTER AN UPGRADE, Accessibility stops working. macOS ties the permission
    to the app's signature, and an ad-hoc signature is a content hash, so every
    build is a different app to it.

    Toggling the switch off and on does NOT fix this. The entry stays bound to
    the old build, so it looks enabled and still does nothing. Either:

      Menu bar > "Already enabled? Repair it..."

    or, equivalently, in a terminal:

      tccutil reset Accessibility io.ramble.Ramble

    Then allow Ramble when it asks.

    Mic setup:
      - Pair the Instamic and put it in Bluetooth Microphone Mode
      - Quit the Instamic Remote app. The device accepts exactly one BLE
        central, so while that app is open Ramble can never connect
      - In Sound settings, set Output back to your speakers. macOS routes both
        directions to a Bluetooth headset by default, which drops all system
        audio to 16 kHz mono

    Configure per-app hotkeys in ~/.config/ramble/config.json (hot-reloaded),
    or via the menu bar icon.

    Diagnostics, when something is not working:
      ramble-sniff    watch decoded button events from the mic
      ramble-tap      watch what the OS receives from a synthesized keystroke
      ramble-level    measure your whisper level and signal-to-noise ratio

    Event log: ~/Library/Logs/Ramble.log
  EOS
end

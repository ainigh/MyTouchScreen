#if canImport(AppKit)
import AppKit
import Foundation

let launchOptions: LaunchOptions
switch LaunchOptions.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed):
    launchOptions = parsed
case .failure(let error):
    FileHandle.standardError.write(Data("error: \(error.message)\n\n\(LaunchOptions.usage)".utf8))
    exit(2)
}

if launchOptions.showHelp {
    print(LaunchOptions.usage)
    exit(0)
}

// Unbuffered stdout so headless and doctor output appear immediately when piped.
setvbuf(stdout, nil, _IOLBF, 0)

MainActor.assumeIsolated {
    if launchOptions.doctor {
        exit(Doctor().run())
    }
    let app = NSApplication.shared
    let delegate = AppDelegate(options: launchOptions)
    app.delegate = delegate
    // Menu-bar only: no Dock icon, no app menu (Info.plist also sets LSUIElement).
    app.setActivationPolicy(.accessory)
    app.run()
}
#else
// GesturePointer is a macOS app. On other platforms the package still builds (so GestureCore
// can be developed and tested anywhere) and this executable only explains itself.
print("GesturePointer runs on macOS 14 or later. Use `swift test` to exercise GestureCore here.")
#endif

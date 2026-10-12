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
    // Ctrl-C / kill from a terminal (`make run`, headless mode) quits through the normal path,
    // so applicationWillTerminate releases any held mouse button or modifier.
    let signalSources = [SIGINT, SIGTERM].map { signalNumber -> DispatchSourceSignal in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        return source
    }
    // NSApplication holds its delegate weakly; without this the optimizer may release the
    // delegate right after the assignment and applicationDidFinishLaunching never runs.
    withExtendedLifetime((delegate, signalSources)) { app.run() }
}
#else
// GesturePointer is a macOS app. On other platforms the package still builds (so GestureCore
// can be developed and tested anywhere) and this executable only explains itself.
print("GesturePointer runs on macOS 14 or later. Use `swift test` to exercise GestureCore here.")
#endif

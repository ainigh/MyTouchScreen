#if canImport(AppKit)
import Foundation

/// Command-line flags. Unknown flags are an error (with usage), except the ones macOS itself
/// passes to apps (-psn_…, -NS…, -Apple…).
struct LaunchOptions {
    var recordPath: String?
    /// With --record: run the guided tuning session (prompts, labeled segments).
    var script = false
    var replayPath: String?
    var noOverlay = false
    var doctor = false
    var dryRun = false
    var showHelp = false

    static let usage = """
    Usage: GesturePointer [options]

      --record <file.json>   Record the hand-landmark stream to a JSON file while running.
      --script               With --record: guided tuning session. The overlay prompts each
                             gesture 8 times and labels the frames (see tools/tune.md).
      --replay <file.json>   Drive the app from a recording instead of the camera, then quit.
      --dry-run              With --replay: print intents instead of moving the real cursor.
      --no-overlay           No overlay windows; print one line per camera frame (fps, landmarks).
      --doctor               Print permissions, cameras, displays and measured fps, then exit.
      --help                 Show this help.

    """

    static func parse(_ arguments: [String]) -> Result<LaunchOptions, LaunchError> {
        var options = LaunchOptions()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--record":
                guard let path = iterator.next() else { return .failure(LaunchError("--record needs a file path")) }
                options.recordPath = path
            case "--replay":
                guard let path = iterator.next() else { return .failure(LaunchError("--replay needs a file path")) }
                options.replayPath = path
            case "--script":
                options.script = true
            case "--no-overlay":
                options.noOverlay = true
            case "--doctor":
                options.doctor = true
            case "--dry-run":
                options.dryRun = true
            case "--help", "-h":
                options.showHelp = true
            default:
                if argument.hasPrefix("-psn_") || argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                    // Launch Services / AppKit arguments; the value (if any) follows.
                    if !argument.hasPrefix("-psn_") { _ = iterator.next() }
                    continue
                }
                return .failure(LaunchError("Unknown option: \(argument)"))
            }
        }
        if options.dryRun && options.replayPath == nil {
            return .failure(LaunchError("--dry-run only makes sense with --replay"))
        }
        if options.script && options.recordPath == nil {
            return .failure(LaunchError("--script needs --record <file.json>"))
        }
        if options.script && options.noOverlay {
            return .failure(LaunchError("--script shows its prompts in the overlay; it can't be combined with --no-overlay"))
        }
        if options.recordPath != nil && options.replayPath != nil {
            return .failure(LaunchError("--record and --replay can't be combined"))
        }
        return .success(options)
    }
}

struct LaunchError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
#endif

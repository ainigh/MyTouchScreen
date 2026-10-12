#if canImport(AppKit)
import AppKit
#else
// GesturePointer is a macOS app. On other platforms the package still builds (so GestureCore
// can be developed and tested anywhere) and this executable only explains itself.
print("GesturePointer runs on macOS 14 or later. Use `swift test` to exercise GestureCore here.")
#endif

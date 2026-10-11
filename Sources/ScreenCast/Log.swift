import Foundation

/// Diagnostics in the system log, readable with:
/// `log show --last 10m --predicate 'process == "ScreenCast" AND eventMessage BEGINSWITH "["'`
///
/// This goes through NSLog rather than os.Logger: build.sh pins the executable's UUID (see there), and
/// the system log looks up Logger's format strings by that UUID, so messages from later builds wouldn't decode.
enum Log {
    static func cast(_ message: String) { NSLog("[cast] %@", message) }
    static func stream(_ message: String) { NSLog("[stream] %@", message) }
}

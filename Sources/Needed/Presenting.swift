import AppKit
import CoreGraphics

/// The screen is likely being shown to others: something is full screen (a
/// slideshow, a shared window, a video) or a display is mirrored (a projector,
/// a TV). The glow itself is left out of screen sharing, but the sound is not,
/// and a glow in the middle of a talk is a distraction all the same.
enum Presenting {
    static var now: Bool {
        mirrored || frontAppFullScreen
    }

    private static var mirrored: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    /// A window of the app in front covers a whole screen. Window bounds and
    /// owners need no Screen Recording permission, only titles do.
    private static var frontAppFullScreen: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let screens = NSScreen.screens.map(\.frame.size)
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int ?? -1) >= 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return false }
            // A maximized window leaves the menu bar out: only full screen matches.
            return screens.contains(bounds.size)
        }
    }
}

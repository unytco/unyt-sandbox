// What the macOS window server will tell us about one process's windows.
//
// TEMPORARY — scaffolding for .github/workflows/zz-TEMPORARY-load-proving.yaml.
//
// WHY THIS EXISTS INSTEAD OF A SCREENSHOT. Since Catalina, reading screen pixels
// needs the TCC "Screen Recording" grant, which a GitHub-hosted runner has never
// had and cannot be given. Without it `screencapture` DOES NOT FAIL — it returns
// the desktop with every application window silently omitted, and a wallpaper is
// a rich gradient that any not-blank threshold scores as a painted app. So no
// pixel-based verdict on a runner can be trusted.
//
// The window LIST is only partly redacted: kCGWindowName is withheld without the
// grant, while kCGWindowOwnerPID, kCGWindowOwnerName, kCGWindowLayer and
// kCGWindowBounds remain readable. That is enough to prove the app launched and
// put a real on-screen window up at a real size — which is less than "the
// webview painted", and the lane says so rather than implying more.
//
// THAT REDACTION BOUNDARY IS THE LEAST CERTAIN THING HERE, so it is measured
// rather than assumed: the survey below reports how many entries carry each key,
// and a list where the pid or the bounds are gone across the board exits 5 so the
// lane reports UNTRUSTED instead of quietly asserting nothing.
//
// Swift rather than pyobjc: swiftc is on the runner image with Xcode, and pyobjc
// is not — this needs no install step.
//
// Output on stdout, all of it machine-readable and all of it worth reading:
//   DUMP   <one line per on-screen window>
//   KEYS   how many entries carried each key
//   GRANT  whether titles are readable, i.e. whether pixels could be trusted
//   WINDOW <id> <x> <y> <w> <h> <layer> <owner> <title>   per window of <pid>
//
// Exit: 0 the process owns an on-screen layer-0 window · 1 it owns none ·
//       2 bad usage · 3 the window server returned no list · 5 the list is
//       redacted past the point of being evidence.

import CoreGraphics
import Foundation

func emit(_ line: String) {
    print(line)
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

guard CommandLine.arguments.count == 2, let wanted = Int(CommandLine.arguments[1]) else {
    fail("usage: mac-window-info <pid>", 2)
}

// .optionOnScreenOnly alone, with no exclusions: the survey has to see the whole
// list, because "how much of it is redacted" is one of the answers.
guard
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
else {
    fail("the window server returned no window list at all", 3)
}

var withPid = 0
var withBounds = 0
var withLayer = 0
var withName = 0
var mine: [String] = []

for window in windows {
    let pid = window[kCGWindowOwnerPID as String] as? Int
    let owner = window[kCGWindowOwnerName as String] as? String ?? "<no owner name>"
    let layer = window[kCGWindowLayer as String] as? Int
    let title = window[kCGWindowName as String] as? String
    var rect: CGRect? = nil
    if let bounds = window[kCGWindowBounds as String] as? [String: Any] {
        rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    if let pid = pid, pid > 0 { withPid += 1 }
    if let rect = rect, rect.width > 0, rect.height > 0 { withBounds += 1 }
    if layer != nil { withLayer += 1 }
    if let title = title, !title.isEmpty { withName += 1 }

    let size = rect.map { "\(Int($0.origin.x)),\(Int($0.origin.y)),\(Int($0.width)),\(Int($0.height))" }
    emit(
        "DUMP   pid=\(pid.map { "\($0)" } ?? "<none>") layer=\(layer.map { "\($0)" } ?? "<none>") "
            + "bounds=\(size ?? "<none>") owner=\"\(owner)\" "
            + "title=\(title.map { "\"\($0)\"" } ?? "<redacted or none>")")

    guard let pid = pid, pid == wanted, let layer = layer, layer == 0, let rect = rect else { continue }
    mine.append(
        "WINDOW \(window[kCGWindowNumber as String] as? Int ?? -1) \(Int(rect.origin.x)) "
            + "\(Int(rect.origin.y)) \(Int(rect.width)) \(Int(rect.height)) \(layer) "
            + "\"\(owner)\" \(title ?? "")")
}

emit("KEYS   total=\(windows.count) pid=\(withPid) bounds=\(withBounds) layer=\(withLayer) name=\(withName)")
// Titles readable means the process HAS Screen Recording, which is the only
// state in which a captured frame is evidence about the app rather than about
// the desktop. Reported, never assumed either way.
emit("GRANT  screen-recording=\(withName > 0 ? "granted" : "not-granted")")
for line in mine { emit(line) }

// Checked after everything is printed, so the survey is on the record even when
// this is the answer.
if !windows.isEmpty && (withPid == 0 || withBounds == 0) {
    fail(
        "the window list carries no usable owner pid or bounds, so it cannot say whether the app "
            + "put a window on screen — this approach does not work on this macOS",
        5)
}
// Exit 1, not 0, for "this process owns no on-screen window": an empty list read
// as success is how a launch that showed nothing would pass.
exit(mine.isEmpty ? 1 : 0)

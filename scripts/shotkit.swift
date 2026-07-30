// shotkit — the small amount of AppKit that `take-screenshots.sh` can't do from
// the shell: find the app's window, size it, toggle full screen, nudge the mouse
// so the auto-hiding chrome comes back before a capture, and flatten a capture
// onto an opaque canvas of an exact size (`compose`, for the App Store).
//
// Compiled on demand by scripts/take-screenshots.sh. Everything here runs
// against *another* process, so the invoking terminal needs Accessibility
// (System Settings › Privacy & Security › Accessibility) — `ax-trusted`
// reports whether it has it.
//
// All coordinates are Quartz global display coordinates (origin top-left),
// which is what CGWindowList, the Accessibility API, CGEvent, and
// `screencapture -R` all agree on. NSScreen's bottom-left origin is
// deliberately never used.

import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("shotkit: \(message)\n".utf8))
    exit(1)
}

func axValue<T>(_ type: AXValueType, _ value: T) -> AXValue {
    var mutable = value
    return withUnsafePointer(to: &mutable) { AXValueCreate(type, $0)! }
}

/// Reads one attribute, checking the returned CFType is what the caller
/// expects. `CFTypeRef as? SomeCFType` cannot be trusted here: bridging a
/// CFArray of AXUIElements to `[AXUIElement]` succeeds and hands back an
/// *empty* array, so kAXWindows is read as "no windows" on a perfectly healthy
/// app. Everything below goes through CFGetTypeID instead.
func axAttribute(_ element: AXUIElement, _ name: String, typeID: CFTypeID) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
        let value, CFGetTypeID(value) == typeID
    else { return nil }
    return value
}

/// The app's main window, or nil while it hasn't opened one. Asks for
/// AXMainWindow (a single element) rather than AXWindows, so there is no array
/// to bridge; AXFocusedWindow covers the moment before a window becomes main.
func axWindow(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
        if let window = axAttribute(app, name, typeID: AXUIElementGetTypeID()) {
            return unsafeBitCast(window, to: AXUIElement.self)
        }
    }
    return nil
}

func requireAXWindow(_ pid: pid_t) -> AXUIElement {
    guard AXIsProcessTrusted() else {
        die("the calling terminal is not trusted for Accessibility (run `ax-trusted`)")
    }
    guard let window = axWindow(pid) else { die("pid \(pid) has no accessible window yet") }
    return window
}

/// Largest normal-layer window owned by `pid`, straight from the window server —
/// that's the canvas; layer 0 already excludes popovers and menu windows, and
/// "largest" discards the handful of zero-height helper windows AppKit keeps
/// alongside it.
///
/// On-screen windows win when there are any, but off-screen ones are still
/// reported rather than treated as "no window": with the display asleep the
/// window server marks *everything* off-screen, and geometry queries should
/// keep working in that state.
func cgWindow(_ pid: pid_t) -> (id: CGWindowID, rect: CGRect)? {
    let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
    guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    var best: (id: CGWindowID, rect: CGRect, onscreen: Bool)?
    for info in infos {
        guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
            info[kCGWindowLayer as String] as? Int == 0,
            let number = info[kCGWindowNumber as String] as? CGWindowID,
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { continue }
        let onscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
        let candidate = (number, rect, onscreen)
        guard let current = best else { best = candidate; continue }
        if onscreen != current.onscreen {
            if onscreen { best = candidate }
        } else if rect.width * rect.height > current.rect.width * current.rect.height {
            best = candidate
        }
    }
    return best.map { (id: $0.id, rect: $0.rect) }
}

func moveMouse(to point: CGPoint) {
    CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

/// Integers print without a trailing `.0` so the shell can feed them straight
/// to `screencapture -R`.
func fmt(_ value: CGFloat) -> String {
    let rounded = value.rounded()
    return String(Int(rounded))
}

// MARK: - Images

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { die("could not read an image from \(path)") }
    return image
}

/// Writes a PNG. The bitmap handed in is built with `.noneSkipLast`, so ImageIO
/// emits a truecolour PNG with no alpha channel — which is what App Store
/// Connect requires and what a plain window capture is not.
func writePNG(_ image: CGImage, to path: String) {
    guard
        let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { die("could not create a PNG at \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { die("could not write \(path)") }
}

func parseColor(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    var text = hex
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, let value = UInt32(text, radix: 16) else {
        die("expected a six-digit hex colour like 000000, got '\(hex)'")
    }
    return (
        CGFloat((value >> 16) & 0xFF) / 255,
        CGFloat((value >> 8) & 0xFF) / 255,
        CGFloat(value & 0xFF) / 255
    )
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    die(
        "usage: shotkit <ax-trusted|display|window|activate|resize|fullscreen|is-fullscreen|mouse-get|jiggle|compose> …"
    )
}

func pidArgument(_ index: Int) -> pid_t {
    guard args.count > index, let pid = pid_t(args[index]) else { die("\(command): expected a pid") }
    return pid
}

func numberArgument(_ index: Int) -> CGFloat {
    guard args.count > index, let value = Double(args[index]) else { die("\(command): expected a number") }
    return CGFloat(value)
}

switch command {
case "ax-trusted":
    // Deliberately does not prompt: the shell script prints better guidance
    // than the system alert, and a prompt would block an unattended run.
    print(AXIsProcessTrusted() ? "yes" : "no")
    exit(AXIsProcessTrusted() ? 0 : 1)

case "display":
    let bounds = CGDisplayBounds(CGMainDisplayID())
    print("\(fmt(bounds.origin.x)) \(fmt(bounds.origin.y)) \(fmt(bounds.width)) \(fmt(bounds.height))")

case "window":
    // "<window-id> <x> <y> <width> <height>", or exit 1 when there is no window.
    guard let window = cgWindow(pidArgument(1)) else { exit(1) }
    print(
        "\(window.id) \(fmt(window.rect.origin.x)) \(fmt(window.rect.origin.y)) \(fmt(window.rect.width)) \(fmt(window.rect.height))"
    )

case "activate":
    guard let app = NSRunningApplication(processIdentifier: pidArgument(1)) else {
        die("no running application with pid \(args[1])")
    }
    app.activate()

case "resize":
    // resize <pid> <width> <height> — centered horizontally on the main
    // display, and pushed clear of the menu bar vertically.
    let window = requireAXWindow(pidArgument(1))
    let size = CGSize(width: numberArgument(2), height: numberArgument(3))
    let display = CGDisplayBounds(CGMainDisplayID())
    let origin = CGPoint(
        x: display.origin.x + ((display.width - size.width) / 2).rounded(),
        y: max(display.origin.y + 38, display.origin.y + ((display.height - size.height) / 2).rounded()))
    // Size first: a window that is currently larger than the target would
    // otherwise be shoved back on screen and land at the wrong origin.
    for (attribute, value) in [
        (kAXSizeAttribute, axValue(.cgSize, size)),
        (kAXPositionAttribute, axValue(.cgPoint, origin)),
        (kAXSizeAttribute, axValue(.cgSize, size)),
    ] {
        let error = AXUIElementSetAttributeValue(window, attribute as CFString, value)
        if error != .success { die("could not set \(attribute) (AXError \(error.rawValue))") }
    }

case "fullscreen":
    // fullscreen <pid> <0|1>
    let window = requireAXWindow(pidArgument(1))
    let wanted = args.count > 2 && (args[2] == "1" || args[2] == "true")
    let error = AXUIElementSetAttributeValue(
        window, "AXFullScreen" as CFString,
        NSNumber(value: wanted) as CFTypeRef)
    if error != .success { die("could not set AXFullScreen (AXError \(error.rawValue))") }

case "is-fullscreen":
    let window = requireAXWindow(pidArgument(1))
    let value = axAttribute(window, "AXFullScreen", typeID: CFBooleanGetTypeID())
        .map { CFBooleanGetValue(unsafeBitCast($0, to: CFBoolean.self)) }
    print(value == true ? "1" : "0")

case "mouse-get":
    let point = CGEvent(source: nil)?.location ?? .zero
    print("\(fmt(point.x)) \(fmt(point.y))")

case "compose":
    // compose <in.png> <out.png> <width> <height> <fit|fill> <RRGGBB>
    //
    // Redraws a capture onto an opaque canvas of exactly <width>x<height>, which
    // is the whole of what App Store Connect asks of a Mac screenshot: one of
    // four fixed 16:10 pixel sizes, and no alpha channel. `fit` scales the whole
    // capture in and fills the remainder with the background colour (so nothing
    // is ever cropped away); `fill` scales to cover and centre-crops.
    //
    // Prints "<scaled width> <scaled height>" — the size the capture itself
    // occupies on the canvas, so the caller can tell whether it had to upscale.
    guard args.count > 6 else { die("usage: compose <in> <out> <w> <h> <fit|fill> <RRGGBB>") }
    let width = Int(numberArgument(3)), height = Int(numberArgument(4))
    guard width > 0, height > 0 else { die("compose: expected a positive canvas size") }
    let mode = args[5]
    guard mode == "fit" || mode == "fill" else { die("compose: mode must be 'fit' or 'fill'") }
    let background = parseColor(args[6])
    let image = loadImage(args[1])

    // Keep the capture's own RGB profile — Display P3 on any current Mac — so
    // the shaders' saturated output isn't clipped into sRGB on the way out.
    // Anything not RGB (there shouldn't be) is normalised to sRGB.
    let space =
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { die("compose: could not create a \(width)x\(height) bitmap") }

    context.setFillColor(red: background.r, green: background.g, blue: background.b, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high

    let source = CGSize(width: image.width, height: image.height)
    let ratios = (x: CGFloat(width) / source.width, y: CGFloat(height) / source.height)
    let scale = mode == "fit" ? min(ratios.x, ratios.y) : max(ratios.x, ratios.y)
    let drawn = CGSize(
        width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
    context.draw(
        image,
        in: CGRect(
            x: ((CGFloat(width) - drawn.width) / 2).rounded(),
            y: ((CGFloat(height) - drawn.height) / 2).rounded(),
            width: drawn.width, height: drawn.height))

    guard let composed = context.makeImage() else { die("compose: could not render the canvas") }
    writePNG(composed, to: args[2])
    print("\(fmt(drawn.width)) \(fmt(drawn.height))")

case "jiggle":
    // jiggle <x> <y> — two distinct moves so the destination is always a
    // *change*, which is what SwiftUI's onContinuousHover reacts to. Ends on
    // (x, y) so the cursor is parked where we asked.
    let target = CGPoint(x: numberArgument(1), y: numberArgument(2))
    moveMouse(to: CGPoint(x: target.x + 14, y: target.y + 14))
    usleep(80_000)
    moveMouse(to: target)

default:
    die("unknown command '\(command)'")
}

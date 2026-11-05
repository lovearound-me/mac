// Draws the app icon: a warm rounded square with a white heart.
// Usage: swift make-icon.swift <out.png>   (1024×1024)
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(srgbRed: 0.96, green: 0.52, blue: 0.47, alpha: 1),
           ending: NSColor(srgbRed: 0.85, green: 0.30, blue: 0.43, alpha: 1))!
    .draw(in: tile, angle: -90)
if let heart = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(pointSize: 440, weight: .regular)) {
    let tinted = NSImage(size: heart.size, flipped: false) { r in
        heart.draw(in: r)
        NSColor(srgbRed: 1, green: 0.98, blue: 0.96, alpha: 1).set()
        r.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    tinted.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

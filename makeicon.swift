import AppKit
// Reshape app_icon.png into the macOS icon template: a transparent 1024x1024
// canvas with the artwork inset to an 824x824 rounded-rect (squircle). Full-bleed
// art reads as oversized/wrong-shape next to native icons; this gives it the
// standard margin and corner radius so it sizes correctly in the Dock/About panel.
// Usage: makeicon <source.png> <dest.png>
let src = CommandLine.arguments[1]
let dst = CommandLine.arguments[2]
guard let art = NSImage(contentsOfFile: src) else { fatalError("cannot read \(src)") }

let canvas = 1024.0
let body = 848.0                     // ~82.9% of canvas, matching stock macOS icons (measured)
let inset = (canvas - body) / 2.0    // ~88pt margin all around
let radius = body * 0.2237           // macOS squircle corner-radius ratio

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
let bodyRect = NSRect(x: inset, y: inset, width: body, height: body)
NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius).addClip()
art.draw(in: bodyRect, from: .zero, operation: .sourceOver, fraction: 1.0)
out.unlockFocus()

guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: dst))

#!/usr/bin/env swift
//
// Inspect a capture instead of guessing at it. Run interpreted — no build step:
//
//   swift .claude/skills/visual-verify/inspect-capture.swift probe  <png…>
//   swift .claude/skills/visual-verify/inspect-capture.swift plates <png…>
//   swift .claude/skills/visual-verify/inspect-capture.swift matte  <in.png> <out.png> <grey 0…1> [zoom]
//   swift .claude/skills/visual-verify/inspect-capture.swift crop   <in.png> <out.png> <x> <y> <w> <h> [zoom]
//
// Why Swift rather than Python: there is no PIL or numpy on this machine, and
// the stdlib route (sips -s format bmp, then parse the header and slice rows)
// is a lot of code to answer "is there a yellow plate in the header". AppKit's
// NSBitmapImageRep.colorAt(x:y:) is already here, and `swift file.swift` runs
// it without a compile step or a bundle.
//
//   probe   size, and RGBA at three points — the fastest way to tell a
//           transparent-background capture from an opaque one.
//   plates  SwiftUI's unresolvable-image placeholder (the yellow plate that
//           shipped in two App Store screenshots). Reports pixel count and a
//           bbox in *percent of height*, which is the unit a crop band wants.
//           Scans the top 15% only: the header is where it hides, and the
//           severity colours below it will fool a looser test — an early
//           version of this counted a red severity dot as a placeholder.
//   matte   composite an alpha capture onto a flat grey. NOT cosmetic: the
//           states harness preserves alpha deliberately, so a dark-appearance
//           capture is white-ish ink on nothing and reads as "all the text is
//           missing" in any viewer that mattes on white. Matte it at ~0.12
//           before judging a dark render.
//   crop    nearest-neighbour crop/zoom, for looking at one region at 1:1 or
//           larger. A dimension is not a resolution — zoom here magnifies
//           whatever detail is actually in the file, which is the point.
//
// Whatever these report, LOOK AT THE IMAGE TOO. Every measurement here has a
// threshold in it, and a threshold is a guess about what you are looking for.
import AppKit

func load(_ path: String) -> NSBitmapImageRep? {
    guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation
    else { return nil }
    return NSBitmapImageRep(data: tiff)
}

func pct(_ v: Int, _ total: Int) -> String {
    String(format: "%.2f%%", Double(v) / Double(total) * 100)
}

let args = CommandLine.arguments
guard args.count > 2 else {
    print("usage: inspect-capture.swift probe|plates|matte|crop …")
    exit(2)
}

switch args[1] {

case "probe":
    for path in args.dropFirst(2) {
        guard let r = load(path) else { print("\(path): unreadable"); continue }
        var line = "\((path as NSString).lastPathComponent) \(r.pixelsWide)x\(r.pixelsHigh): "
        for (fx, fy) in [(0.5, 0.02), (0.05, 0.5), (0.5, 0.98)] {
            let c = r.colorAt(x: Int(Double(r.pixelsWide) * fx),
                              y: Int(Double(r.pixelsHigh) * fy))!
            line += String(format: "(%.0f%%,%.0f%%)=rgba %.2f %.2f %.2f a%.2f  ", fx * 100,
                           fy * 100, c.redComponent, c.greenComponent, c.blueComponent,
                           c.alphaComponent)
        }
        print(line)
    }

case "plates":
    for path in args.dropFirst(2) {
        guard let r = load(path) else { print("\(path): unreadable"); continue }
        let w = r.pixelsWide, h = r.pixelsHigh
        let band = Int(Double(h) * 0.15)
        var count = 0, x0 = w, x1 = 0, y0 = h, y1 = 0
        for y in 0..<band {
            for x in 0..<w {
                guard let c = r.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                // Saturated yellow only. Safe against brand orange and the
                // severity ramp; see the header note about the red dot.
                guard c.redComponent > 0.78, c.greenComponent > 0.60,
                      c.blueComponent < 0.40 else { continue }
                count += 1
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        let name = (path as NSString).lastPathComponent
        if count > 0 {
            print("\(name) \(w)x\(h): PLATES \(count) px  bbox x\(x0)-\(x1) y\(y0)-\(y1)"
                + "  = \(pct(y0, h))–\(pct(y1, h)) of height")
        } else {
            print("\(name) \(w)x\(h): clean — 0 plate px in the top \(band) rows")
        }
    }

case "matte":
    guard args.count >= 5, let src = load(args[2]), let grey = Double(args[4]) else {
        print("usage: matte <in.png> <out.png> <grey 0…1> [zoom]"); exit(2)
    }
    let z = args.count > 5 ? Int(args[5])! : 1
    let w = src.pixelsWide * z, h = src.pixelsHigh * z
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let g = CGFloat(grey)
    for y in 0..<h {
        for x in 0..<w {
            let c = src.colorAt(x: x / z, y: y / z)!
            let a = c.alphaComponent
            // deviceRed:, NOT red:. An NSColor built with no colour space
            // floods stderr with "Unrecognized colorspace number -1" — one line
            // per pixel, which buries the output it was supposed to produce.
            out.setColor(NSColor(deviceRed: c.redComponent * a + g * (1 - a),
                                 green: c.greenComponent * a + g * (1 - a),
                                 blue: c.blueComponent * a + g * (1 - a), alpha: 1),
                         atX: x, y: y)
        }
    }
    try! out.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: args[3]))
    print("wrote \(args[3]) \(w)x\(h)")

case "crop":
    guard args.count >= 8, let src = load(args[2]) else {
        print("usage: crop <in.png> <out.png> <x> <y> <w> <h> [zoom]"); exit(2)
    }
    let x = Int(args[4])!, y = Int(args[5])!, cw = Int(args[6])!, ch = Int(args[7])!
    let z = args.count > 8 ? Int(args[8])! : 1
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw * z, pixelsHigh: ch * z,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    for oy in 0..<(ch * z) {
        for ox in 0..<(cw * z) {
            let c = src.colorAt(x: min(src.pixelsWide - 1, x + ox / z),
                                y: min(src.pixelsHigh - 1, y + oy / z))!
            out.setColor(c, atX: ox, y: oy)
        }
    }
    try! out.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: args[3]))
    print("wrote \(args[3]) \(cw * z)x\(ch * z)")

default:
    print("unknown command \(args[1])"); exit(2)
}

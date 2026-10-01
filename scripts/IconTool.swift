import AppKit

// Renders the app icon set (and an optional preview sheet) from the same artwork the app uses.
//   build/make-icon <iconset-dir>            writes AppIcon.iconset PNGs
//   build/make-icon --preview <png-path>     writes a sheet with the icon and menu bar glyph states
@main
struct IconTool {
    static func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--preview", args.count == 2 { try preview(to: args[1]); return }
        guard let dir = args.first else {
            FileHandle.standardError.write(Data("usage: make-icon <iconset-dir> | --preview <png>\n".utf8))
            exit(2)
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                                      ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
        for (name, px) in sizes {
            try png(LlamaArt.appIcon(pixels: px)).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
        }
    }

    static func preview(to path: String) throws {
        let w = 1000, h = 760
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(NSColor(white: 0.93, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // App icon at several sizes.
        var x: CGFloat = 20
        for px in [256, 128, 64, 32, 16] {
            let icon = LlamaArt.appIcon(pixels: px * 2)
            let image = NSImage(size: NSSize(width: px, height: px)); image.addRepresentation(icon)
            image.draw(in: CGRect(x: x, y: CGFloat(h) - 20 - CGFloat(px), width: CGFloat(px), height: CGFloat(px)))
            x += CGFloat(px) + 20
        }

        // Menu bar glyph states on light and dark bars, at 1x-ish size and magnified.
        var y: CGFloat = 60
        for (bg, fg) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.17, alpha: 1), NSColor.white)] {
            ctx.setFillColor(bg.cgColor); ctx.fill(CGRect(x: 0, y: y, width: CGFloat(w), height: 120))
            var gx: CGFloat = 40
            for scale in [CGFloat(1.4), 4] {
                for state in [LlamaArt.GlyphState.running, .stopped, .attention] {
                    let size = 18 * scale
                    let glyph = LlamaArt.menuBarImage(state, points: 18)
                    let tinted = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
                        glyph.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true
                    }
                    tinted.draw(in: CGRect(x: gx, y: y + 60 - size / 2, width: size, height: size))
                    gx += size + 24
                }
                gx += 40
            }
            y -= 0; y += 130
        }
        NSGraphicsContext.restoreGraphicsState()
        try png(rep).write(to: URL(fileURLWithPath: path))
    }
}

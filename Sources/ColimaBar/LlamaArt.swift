import AppKit

/// The llama-with-containers artwork, drawn in code so the app icon and the menu bar glyph share one design.
/// Coordinates follow a 100x100 box with the origin at the top left.
enum LlamaArt {
    struct Palette {
        var body: NSColor
        var eye: NSColor
        var containerA: NSColor
        var containerB: NSColor
        var ridge: NSColor

        /// "Midnight": light llama, bright cargo, on a near-black tile.
        static let midnight = Palette(
            body: NSColor(srgbRed: 0.910, green: 0.902, blue: 0.875, alpha: 1),
            eye: NSColor(srgbRed: 0.106, green: 0.122, blue: 0.165, alpha: 1),
            containerA: NSColor(srgbRed: 0.941, green: 0.600, blue: 0.482, alpha: 1),
            containerB: NSColor(srgbRed: 0.365, green: 0.792, blue: 0.647, alpha: 1),
            ridge: NSColor.black.withAlphaComponent(0.25))
    }

    static let tileColor = NSColor(srgbRed: 0.106, green: 0.122, blue: 0.165, alpha: 1)

    // MARK: Full-colour llama (app icon)

    /// Draws the coloured llama into `rect`.
    static func drawLlama(in ctx: CGContext, rect: CGRect, palette: Palette = .midnight) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / 100, y: -rect.height / 100)

        // Body parts share one fill and a round-joined outline of the same colour, which softens the silhouette.
        ctx.setFillColor(palette.body.cgColor)
        ctx.setStrokeColor(palette.body.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineJoin(.round)
        for path in bodyShapes() {
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
        }

        ctx.setFillColor(palette.eye.cgColor)
        ctx.fillEllipse(in: CGRect(x: 82 - 1.9, y: 26.5 - 1.9, width: 3.8, height: 3.8))

        container(ctx, CGRect(x: 25, y: 34, width: 34, height: 17), fill: palette.containerA, ridge: palette.ridge,
                  ridgeXs: [33, 41, 49], ridgeY: 37.5...47.5)
        container(ctx, CGRect(x: 31, y: 18, width: 23, height: 15), fill: palette.containerB, ridge: palette.ridge,
                  ridgeXs: [38, 46], ridgeY: 21.5...29.5)
        ctx.restoreGState()
    }

    private static func container(_ ctx: CGContext, _ r: CGRect, fill: NSColor, ridge: NSColor, ridgeXs: [CGFloat], ridgeY: ClosedRange<CGFloat>) {
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(ridge.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        for x in ridgeXs {
            ctx.move(to: CGPoint(x: x, y: ridgeY.lowerBound))
            ctx.addLine(to: CGPoint(x: x, y: ridgeY.upperBound))
        }
        ctx.strokePath()
    }

    private static func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func bodyShapes() -> [CGPath] {
        let neck = CGMutablePath()
        neck.move(to: CGPoint(x: 58, y: 56)); neck.addLine(to: CGPoint(x: 68, y: 31))
        neck.addLine(to: CGPoint(x: 78, y: 31)); neck.addLine(to: CGPoint(x: 73, y: 62)); neck.closeSubpath()
        return [
            rounded(21, 51, 48, 20, 10),
            rounded(26, 66, 6, 22, 3), rounded(37, 66, 6, 22, 3), rounded(52, 66, 6, 22, 3), rounded(62, 66, 6, 22, 3),
            neck,
            rounded(70, 21, 22, 13, 6.5),
            rounded(71, 10, 5, 14, 2.5), rounded(78, 10, 5, 14, 2.5),
            CGPath(ellipseIn: CGRect(x: 13, y: 52, width: 8, height: 8), transform: nil),
        ]
    }

    // MARK: App icon

    /// Renders the app icon at `pixels` x `pixels`: a dark tile with the llama, using the standard macOS icon margin.
    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else { return rep }
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        let s = CGFloat(pixels)

        // macOS icons sit on a 1024 canvas with an 824pt tile in the middle.
        let tile = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        ctx.setFillColor(tileColor.cgColor)
        ctx.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil))
        ctx.fillPath()

        let side = tile.width * 0.86
        let llama = CGRect(x: tile.midX - side / 2 + side * 0.005, y: tile.midY - side / 2 - side * 0.02, width: side, height: side)
        drawLlama(in: ctx, rect: llama)
        return rep
    }

    // MARK: Menu bar glyph

    enum GlyphState: Hashable { case running, stopped, attention }

    /// A monochrome template image for the menu bar, so macOS tints it for light and dark bars.
    static func menuBarImage(_ state: GlyphState, points: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: points, height: points), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Dim the whole glyph as one layer so overlapping shapes don't show through each other.
            ctx.setAlpha(state == .stopped ? 0.4 : 1)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawGlyph(in: ctx, rect: rect)
            ctx.endTransparencyLayer()
            ctx.setAlpha(1)
            if state == .attention {
                // Template images can't carry colour, so the badge is a solid dot with a clear halo around it.
                ctx.saveGState()
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: rect.width / 18, y: -rect.height / 18)
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: CGRect(x: 15.0 - 4.0, y: 14.6 - 4.0, width: 8.0, height: 8.0))
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: CGRect(x: 15.0 - 2.6, y: 14.6 - 2.6, width: 5.2, height: 5.2))
                ctx.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Simplified silhouette: solid blocks, no ridges, so it stays readable at 18pt.
    static func drawGlyph(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: rect.width / 100, y: -rect.height / 100)
        let color = NSColor.black.cgColor
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(3)
        ctx.setLineJoin(.round)

        let neck = CGMutablePath()
        neck.move(to: CGPoint(x: 58, y: 60)); neck.addLine(to: CGPoint(x: 68, y: 33))
        neck.addLine(to: CGPoint(x: 79, y: 33)); neck.addLine(to: CGPoint(x: 73, y: 66)); neck.closeSubpath()
        let shapes: [CGPath] = [
            rounded(21, 56, 48, 18, 9),
            rounded(26, 70, 7, 20, 3.5), rounded(38, 70, 7, 20, 3.5), rounded(52, 70, 7, 20, 3.5), rounded(62, 70, 7, 20, 3.5),
            neck,
            rounded(70, 22, 23, 14, 7),
            rounded(71, 9, 6, 16, 3), rounded(79, 9, 6, 16, 3),
        ]
        for path in shapes { ctx.addPath(path); ctx.drawPath(using: .fillStroke) }
        for box in [CGRect(x: 24, y: 36, width: 36, height: 16), CGRect(x: 31, y: 17, width: 24, height: 15)] {
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}

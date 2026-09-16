import AppKit

/// Renders every `BanditGlyph` at menu bar size and larger, on a light and a
/// dark strip, to a PNG you can actually look at. A 16pt drawing cannot be
/// judged from source.
///
///     make glyphs        # → /tmp/tilebandit-glyphs.png
@main
enum GlyphSheet {
    static let sizes: [CGFloat] = [16, 22, 32, 64]
    static let cell = CGSize(width: 86, height: 86)

    static func main() {
        let out = CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : "/tmp/tilebandit-glyphs.png"

        let glyphs = BanditGlyph.allCases
        let width = cell.width * CGFloat(sizes.count) + 110
        let height = cell.height * CGFloat(glyphs.count) * 2 + 60

        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()

            var y: CGFloat = 20
            for scheme in [Scheme.light, .dark] {
                for glyph in glyphs {
                    scheme.background.setFill()
                    NSRect(x: 100, y: y, width: width - 110, height: cell.height).fill()
                    label(glyph.rawValue, at: NSPoint(x: 12, y: y + cell.height / 2 - 8), color: .black)

                    var x: CGFloat = 100
                    for size in sizes {
                        let art = glyph.image(size: size)
                        let origin = NSPoint(x: x + (cell.width - size) / 2, y: y + (cell.height - size) / 2)
                        draw(art, at: origin, size: size, tint: scheme.foreground)
                        x += cell.width
                    }
                    y += cell.height
                }
            }
            return true
        }

        guard let data = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        else { fputs("could not render\n", stderr); exit(1) }
        try? png.write(to: URL(fileURLWithPath: out))
        print(out)
    }

    enum Scheme {
        case light, dark
        var background: NSColor { self == .light ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.13, alpha: 1) }
        var foreground: NSColor { self == .light ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.97, alpha: 1) }
    }

    /// Template images carry no colour of their own — the menu bar tints them,
    /// so the sheet has to as well or the dark strip would show nothing. The
    /// tint has to happen in a transparent image of its own: `.sourceAtop`
    /// straight onto the sheet would find the opaque strip underneath and
    /// paint the whole square.
    static func draw(_ image: NSImage, at origin: NSPoint, size: CGFloat, tint: NSColor) {
        let box = NSRect(x: 0, y: 0, width: size, height: size)
        let tinted = NSImage(size: box.size, flipped: false) { _ in
            image.draw(in: box)
            tint.setFill()
            box.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(origin: origin, size: box.size))
    }

    static func label(_ text: String, at point: NSPoint, color: NSColor) {
        (text as NSString).draw(
            at: point,
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: color,
            ]
        )
    }
}

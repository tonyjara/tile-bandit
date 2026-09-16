import AppKit

/// The hand-drawn half of the menu bar icon set.
///
/// An icon pack was the obvious route and the wrong one: every one of them is
/// a dependency plus a licence file, and none of them ships a sheriff star cut
/// for a 16pt menu bar. These are Bézier paths in a 100×100 box scaled to
/// whatever the caller asks for — sharp at any size, no resources to copy into
/// the bundle, and template images, so macOS tints them for light, dark and a
/// highlighted menu on its own.
///
/// Deliberately self-contained (AppKit and nothing of ours): `make glyphs`
/// compiles this single file to render a contact sheet, which is the only
/// honest way to judge a 16pt drawing.
enum BanditGlyph: String, CaseIterable {
    case star
    case mask
    case hat
    case horseshoe
    case cactus
    case wheel

    /// A template `NSImage` at `size` points square. Menu bar images want 16;
    /// the settings picker draws them larger, which is where the details that
    /// wash out at 16 (the hat's crease, the horseshoe's nail holes) earn
    /// their keep.
    func image(size: CGFloat = 16) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let scale = NSAffineTransform()
            scale.scale(by: rect.width / 100)
            scale.concat()
            NSColor.black.setFill()
            NSColor.black.setStroke()
            for step in Sketch.draw(self).steps { step.run() }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A drawing in a 100×100 box: parts to paint, parts to cut back out.
///
/// Cuts are `.clear` blend rather than an even-odd winding rule because the
/// parts overlap on purpose — a hat's crown sits *on* its brim, and even-odd
/// would punch a hole exactly where the two meet.
private struct Sketch {
    enum Step {
        case fill(NSBezierPath)
        case stroke(NSBezierPath, CGFloat)
        case cut(NSBezierPath)

        func run() {
            let context = NSGraphicsContext.current?.cgContext
            switch self {
            case .fill(let path):
                context?.setBlendMode(.normal)
                path.fill()
            case .stroke(let path, let width):
                context?.setBlendMode(.normal)
                path.lineWidth = width
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            case .cut(let path):
                context?.setBlendMode(.clear)
                path.fill()
                context?.setBlendMode(.normal)
            }
        }
    }

    var steps: [Step] = []

    private mutating func fill(_ path: NSBezierPath) { steps.append(.fill(path)) }
    private mutating func stroke(_ path: NSBezierPath, _ width: CGFloat) { steps.append(.stroke(path, width)) }
    private mutating func cut(_ path: NSBezierPath) { steps.append(.cut(path)) }

    static func draw(_ glyph: BanditGlyph) -> Sketch {
        var sketch = Sketch()
        switch glyph {
        case .star: sketch.star()
        case .mask: sketch.mask()
        case .hat: sketch.hat()
        case .horseshoe: sketch.horseshoe()
        case .cactus: sketch.cactus()
        case .wheel: sketch.wheel()
        }
        return sketch
    }

    // MARK: - The glyphs

    /// A lawman's star, point up. Five points and a deep waist (inner radius
    /// well under half the outer) — a shallower star turns into a blob once
    /// it's 16 points tall.
    private mutating func star() {
        fill(BanditPaths.star(center: p(50, 50), outer: 48, inner: 19))
    }

    /// A domino mask — the shape that says "bandit" at a glance. The mascot
    /// wears a bandana, but a bandana at 16pt is an unreadable smudge.
    ///
    /// The eye holes are the whole glyph: round ones turn it into a pair of
    /// goggles, so they're narrow almonds tilted inner-corner-down, which is
    /// also what gives the thing its scowl.
    private mutating func mask() {
        let path = NSBezierPath()
        path.move(to: p(2, 56))
        path.curve(to: p(50, 66), controlPoint1: p(3, 84), controlPoint2: p(26, 82))
        path.curve(to: p(98, 56), controlPoint1: p(74, 82), controlPoint2: p(97, 84))
        path.curve(to: p(60, 25), controlPoint1: p(99, 30), controlPoint2: p(80, 15))
        path.curve(to: p(40, 25), controlPoint1: p(54, 31), controlPoint2: p(46, 31))
        path.curve(to: p(2, 56), controlPoint1: p(20, 15), controlPoint2: p(1, 30))
        path.close()
        fill(path)
        cut(Self.eyePath(center: p(29, 54), tilt: -13))
        cut(Self.eyePath(center: p(71, 54), tilt: 13))
    }

    /// Ten-gallon: a crescent brim, a tall crown, and the crease pinched out
    /// of the top. Both halves have to be generous — a modest crown on a thin
    /// brim is a bowler, which is the wrong century and the wrong continent.
    private mutating func hat() {
        let brim = NSBezierPath()
        brim.move(to: p(1, 40))
        brim.curve(to: p(99, 40), controlPoint1: p(18, 12), controlPoint2: p(82, 12))
        brim.curve(to: p(1, 40), controlPoint1: p(80, 32), controlPoint2: p(20, 32))
        brim.close()
        fill(brim)

        // Tall, flat-topped and only a little narrower than it is high. A
        // domed crown is a derby; the height is what makes it a ten-gallon.
        let crown = NSBezierPath()
        crown.move(to: p(26, 34))
        crown.curve(to: p(33, 87), controlPoint1: p(23, 62), controlPoint2: p(27, 83))
        crown.line(to: p(67, 87))
        crown.curve(to: p(74, 34), controlPoint1: p(73, 83), controlPoint2: p(77, 62))
        crown.close()
        fill(crown)

        // The crease, and the band where the crown meets the brim.
        cut(NSBezierPath(ovalIn: NSRect(x: 33, y: 83, width: 34, height: 20)))
        cut(NSBezierPath(rect: NSRect(x: 19, y: 33, width: 62, height: 4)))
    }

    /// Open end down, the way you hang one for luck. Stroked rather than
    /// outlined so the arms keep an even weight, with the nail holes cut back
    /// out of them. Thick: a thin one is a pair of headphones.
    private mutating func horseshoe() {
        let shoe = NSBezierPath()
        shoe.appendArc(withCenter: p(50, 54), radius: 30, startAngle: -36, endAngle: 216, clockwise: false)
        stroke(shoe, 24)
        for angle in [18.0, 56.0, 124.0, 162.0] {
            let radians = angle * .pi / 180
            let center = p(50 + cos(radians) * 30, 54 + sin(radians) * 30)
            cut(NSBezierPath(ovalIn: NSRect(x: center.x - 2.6, y: center.y - 2.6, width: 5.2, height: 5.2)))
        }
    }

    /// Saguaro: one trunk, two arms at different heights. Symmetrical arms
    /// look like a candelabra, not a cactus.
    private mutating func cactus() {
        fill(NSBezierPath(roundedRect: NSRect(x: 40, y: 4, width: 20, height: 88), xRadius: 10, yRadius: 10))

        let left = NSBezierPath()
        left.move(to: p(50, 44))
        left.line(to: p(24, 44))
        left.line(to: p(24, 64))
        stroke(left, 16)

        let right = NSBezierPath()
        right.move(to: p(50, 58))
        right.line(to: p(76, 58))
        right.line(to: p(76, 76))
        stroke(right, 16)
    }

    /// A wagon wheel, which is also the only western shape that happens to be
    /// a grid of sorts — spokes cutting a circle into equal tiles.
    private mutating func wheel() {
        let rim = NSBezierPath()
        rim.appendArc(withCenter: p(50, 50), radius: 40, startAngle: 0, endAngle: 360)
        stroke(rim, 12)

        for i in 0..<8 {
            let radians = Double(i) * .pi / 4
            let spoke = NSBezierPath()
            spoke.move(to: p(50, 50))
            spoke.line(to: p(50 + cos(radians) * 38, 50 + sin(radians) * 38))
            stroke(spoke, 7)
        }
        fill(NSBezierPath(ovalIn: NSRect(x: 38, y: 38, width: 24, height: 24)))
    }

    // MARK: - Shapes

    /// An almond, wider than it is tall, rotated by `tilt` degrees about its
    /// own centre — an upright oval reads as a headlight.
    private static func eyePath(center: NSPoint, tilt: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: p(-13, 0))
        path.curve(to: p(13, 0), controlPoint1: p(-7, 10), controlPoint2: p(7, 10))
        path.curve(to: p(-13, 0), controlPoint1: p(7, -10), controlPoint2: p(-7, -10))
        path.close()

        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: tilt)
        path.transform(using: transform as AffineTransform)
        return path
    }

    private func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
    private static func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
}

// MARK: - Shared geometry

enum BanditPaths {
    /// A five-pointed star, point up. The waist (`inner`) wants to be well
    /// under half the outer radius; a shallow star is a blob at 16pt and a
    /// flower at 1024.
    static func star(center: NSPoint, outer: CGFloat, inner: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        for i in 0..<10 {
            let radius = i.isMultiple(of: 2) ? outer : inner
            let angle = (90 + Double(i) * 36) * .pi / 180
            let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}

// MARK: - App icon

/// The app's own icon: the one piece of the set that gets colour.
///
/// Drawn rather than stored so the About panel, a `swift run` build with no
/// bundle to read from, and the `.icns` that `make icon` bakes are all the
/// same artwork at whatever size each of them asks for.
enum AppIconArt {
    /// Design box is 1024 — the size Apple's icon pipeline works in.
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let scale = NSAffineTransform()
            scale.scale(by: rect.width / 1024)
            scale.concat()
            draw()
            return true
        }
    }

    private static func draw() {
        // Inset the way Apple's icon grid wants it: art drawn edge to edge
        // looks oversized next to its neighbours in Finder.
        let body = NSBezierPath(
            roundedRect: NSRect(x: 100, y: 96, width: 824, height: 824),
            xRadius: 185,
            yRadius: 185
        )
        NSGradient(colors: [rgb(0.36, 0.22, 0.14), rgb(0.12, 0.07, 0.05)])?.draw(in: body, angle: -90)

        // A bento of tiles, barely there — what the bandit is after.
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        NSColor.white.withAlphaComponent(0.075).setFill()
        for rect in [
            NSRect(x: 168, y: 168, width: 312, height: 688),
            NSRect(x: 512, y: 168, width: 344, height: 328),
            NSRect(x: 512, y: 528, width: 344, height: 328),
        ] {
            NSBezierPath(roundedRect: rect, xRadius: 26, yRadius: 26).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Tooled leather: a bright rim inside the edge.
        let rim = NSBezierPath(
            roundedRect: NSRect(x: 118, y: 114, width: 788, height: 788),
            xRadius: 168,
            yRadius: 168
        )
        rim.lineWidth = 8
        rgb(0.78, 0.56, 0.22).withAlphaComponent(0.45).setStroke()
        rim.stroke()

        let star = BanditPaths.star(center: NSPoint(x: 512, y: 512), outer: 286, inner: 113)

        // The shadow goes down with a solid fill first: a gradient drawn into a
        // path takes the shadow with it and doubles the darkness.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 40
        shadow.shadowOffset = NSSize(width: 0, height: -16)
        shadow.set()
        rgb(0.1, 0.06, 0.04).setFill()
        star.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(colors: [rgb(0.99, 0.87, 0.55), rgb(0.76, 0.51, 0.13)])?.draw(in: star, angle: -90)
        star.lineWidth = 10
        rgb(0.33, 0.19, 0.06).withAlphaComponent(0.55).setStroke()
        star.stroke()
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}

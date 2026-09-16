import AppKit

/// Bakes `AppIconArt` into an `.iconset` folder for `iconutil`.
///
/// Run by `make icon`, which then turns the folder into `Resources/AppIcon.icns`
/// and leaves it checked in — so building the app stays a copy, with no
/// rendering step and nothing extra to install.
///
///     swift Tools/AppIconGen.swift <out.iconset>
@main
enum AppIconGen {
    /// The sizes `iconutil` expects, each also rendered at @2x. Drawn at the
    /// real pixel size rather than downscaled from 1024, so the small ones
    /// stay crisp.
    static let sizes: [Int] = [16, 32, 128, 256, 512]

    static func main() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
        let directory = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for size in sizes {
            write(pixels: size, to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
            write(pixels: size * 2, to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        print(out)
    }

    static func write(pixels: Int, to url: URL) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { fputs("could not allocate \(pixels)px\n", stderr); exit(1) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        AppIconArt.image(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            fputs("could not encode \(pixels)px\n", stderr)
            exit(1)
        }
        try? png.write(to: url)
    }
}

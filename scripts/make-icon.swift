import AppKit
import CoreText
import Foundation

// Both formats share one outline. Explicit materials keep Tahoe from adding
// fuzzy highlights around the mark in a flattened legacy icon.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: make-icon.swift OUTPUT.iconset OUTPUT.icon")
}
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
let document = URL(fileURLWithPath: CommandLine.arguments[2])
let assets = document.appendingPathComponent("Assets")
for folder in [iconset, assets] {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
}
let canvas: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let paper = CGColor(colorSpace: colorSpace, components: [0.965, 0.961, 0.930, 1])!
let ink = CGColor(colorSpace: colorSpace, components: [80 / 255, 105 / 255, 87 / 255, 1])!
let accent = CGColor(colorSpace: colorSpace, components: [144 / 255, 169 / 255, 128 / 255, 1])!
let font = CTFontCreateWithName("Georgia-Bold" as CFString, canvas * 0.52, nil)
var character: UniChar = 109
var glyph: CGGlyph = 0
precondition(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
let letter = CTFontCreatePathForGlyph(font, glyph, nil)!
let bounds = letter.boundingBoxOfPath
let letterX = (canvas - bounds.width) / 2 - canvas * 0.015 - bounds.minX
let baseline = canvas * 0.465 - bounds.midY
var translation = CGAffineTransform(translationX: letterX, y: baseline)
let positionedLetter = letter.copy(using: &translation)!
let dot = CGRect(x: canvas * 0.695, y: canvas * 0.313, width: canvas * 0.047, height: canvas * 0.047)

func bitmapContext(pixels: Int) -> CGContext {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    return context
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        try autoreleasepool {
            let pixels = size * scale
            let renderPixels = pixels * (pixels <= 256 ? 4 : 2)
            let context = bitmapContext(pixels: renderPixels)
            context.scaleBy(x: CGFloat(renderPixels) / canvas, y: CGFloat(renderPixels) / canvas)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.02), blur: canvas * 0.045,
                              color: CGColor(gray: 0, alpha: 0.16))
            context.setFillColor(paper)
            let inset = canvas * 0.09
            context.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
                                   cornerWidth: canvas * 0.19, cornerHeight: canvas * 0.19, transform: nil))
            context.fillPath()
            context.restoreGState()
            context.setFillColor(ink)
            context.addPath(positionedLetter)
            context.fillPath()
            context.setFillColor(accent)
            context.fillEllipse(in: dot)
            let output = bitmapContext(pixels: pixels)
            output.draw(context.makeImage()!, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            let bitmap = NSBitmapImageRep(cgImage: output.makeImage()!)
            bitmap.size = NSSize(width: size, height: size)
            let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
            try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
        }
    }
}

func number(_ value: CGFloat) -> String { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
var commands: [String] = []
letter.applyWithBlock { pointer in
    let element = pointer.pointee
    func point(_ index: Int) -> String { "\(number(element.points[index].x)),\(number(element.points[index].y))" }
    switch element.type {
    case .moveToPoint: commands.append("M\(point(0))")
    case .addLineToPoint: commands.append("L\(point(0))")
    case .addQuadCurveToPoint: commands.append("Q\(point(0)) \(point(1))")
    case .addCurveToPoint: commands.append("C\(point(0)) \(point(1)) \(point(2))")
    case .closeSubpath: commands.append("Z")
    @unknown default: fatalError("Unsupported path element")
    }
}
// Compensate for the platform enclosure's inset to preserve the mark's size.
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <g transform="translate(512 512) scale(1.2195121951) translate(-512 -512)">
    <path fill="#506957" transform="translate(\(number(letterX)) \(number(canvas - baseline))) scale(1 -1)" d="\(commands.joined(separator: " "))"/>
    <circle fill="#90A980" cx="\(number(dot.midX))" cy="\(number(canvas - dot.midY))" r="\(number(dot.width / 2))"/>
  </g>
</svg>

"""
try svg.write(to: assets.appendingPathComponent("mark.svg"), atomically: true, encoding: .utf8)
let settings = """
{
  "fill": { "solid": "srgb:0.965,0.961,0.930,1" },
  "groups": [{
    "layers": [{ "image-name": "mark.svg", "name": "mdr", "glass": false }],
    "specular": false,
    "shadow": { "kind": "neutral", "opacity": 0 },
    "translucency": { "enabled": false, "value": 0 }
  }],
  "supported-platforms": { "squares": "shared" }
}

"""
try settings.write(to: document.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)

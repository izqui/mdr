import AppKit

// Frame an actual native-reader capture for the README without capturing a desktop.
guard CommandLine.arguments.count == 4,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Usage: frame-screenshot.swift INPUT.png OUTPUT.png WINDOW_TITLE")
}
let contentWidth: CGFloat = 1440
let contentHeight = contentWidth * image.size.height / image.size.width
let inset: CGFloat = 56, titleHeight: CGFloat = 32, scale: CGFloat = 2
let size = NSSize(width: contentWidth + inset * 2, height: contentHeight + titleHeight + inset * 2)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.scaleBy(x: scale, y: scale)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let canvas = NSRect(origin: .zero, size: size)
NSGradient(starting: NSColor(calibratedRed: 0.92, green: 0.93, blue: 0.90, alpha: 1),
           ending: NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.94, alpha: 1))!.draw(in: canvas, angle: 120)
let frame = NSRect(x: inset, y: inset, width: contentWidth, height: contentHeight + titleHeight)
let outline = NSBezierPath(roundedRect: frame, xRadius: 11, yRadius: 11)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.shadowBlurRadius = 30; shadow.set()
NSColor(calibratedWhite: 0.97, alpha: 1).setFill(); outline.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
outline.addClip()
NSColor(calibratedRed: 0.955, green: 0.953, blue: 0.937, alpha: 1).setFill(); outline.fill()
image.draw(in: NSRect(x: inset, y: inset, width: contentWidth, height: contentHeight))
let titleY = inset + contentHeight
NSColor.black.withAlphaComponent(0.07).setStroke()
let divider = NSBezierPath(); divider.move(to: NSPoint(x: inset, y: titleY)); divider.line(to: NSPoint(x: inset + contentWidth, y: titleY)); divider.lineWidth = 0.5; divider.stroke()
let colors = [NSColor(calibratedRed: 1, green: 0.376, blue: 0.353, alpha: 1),
              NSColor(calibratedRed: 1, green: 0.741, blue: 0.18, alpha: 1),
              NSColor(calibratedRed: 0.157, green: 0.788, blue: 0.251, alpha: 1)]
for (index, color) in colors.enumerated() {
    let button = NSBezierPath(ovalIn: NSRect(x: inset + 14 + CGFloat(index) * 20, y: titleY + 10, width: 12, height: 12))
    color.setFill(); button.fill(); NSColor.black.withAlphaComponent(0.10).setStroke(); button.lineWidth = 0.5; button.stroke()
}
let title = NSAttributedString(string: CommandLine.arguments[3], attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.38, alpha: 1)])
title.draw(at: NSPoint(x: inset + (contentWidth - title.size().width) / 2, y: titleY + (titleHeight - title.size().height) / 2))
NSGraphicsContext.restoreGraphicsState()
NSColor.black.withAlphaComponent(0.12).setStroke(); outline.lineWidth = 0.5; outline.stroke()
NSGraphicsContext.restoreGraphicsState()
let output = NSBitmapImageRep(cgImage: context.makeImage()!)
output.size = size
try output.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))

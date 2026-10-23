#!/usr/bin/env swift

import AppKit
import CoreGraphics

// Switch app icon renderer.
// Outputs a 1024x1024 PNG; sips/iconutil used elsewhere to derive smaller sizes.
//
// Design: three stacked rounded windows offset diagonally on aubergine.
// Back window: dim cream. Middle: cream. Front: rose gold accent.
// macOS auto-applies the squircle mask via the AppIcon.appiconset.

let canvas = CGSize(width: 1024, height: 1024)

// Palette (matches Sources/Switch/Design.swift)
let bg       = NSColor(red: 0.102, green: 0.067, blue: 0.082, alpha: 1.0) // #1A1115
let cream    = NSColor(red: 0.937, green: 0.890, blue: 0.808, alpha: 1.0) // #EFE3CE
let creamDim = NSColor(red: 0.659, green: 0.584, blue: 0.502, alpha: 1.0) // #A89580
let rose     = NSColor(red: 0.741, green: 0.514, blue: 0.467, alpha: 1.0) // #BD8377

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width),
    pixelsHigh: Int(canvas.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS app icon convention:
// - 1024x1024 canvas
// - Inner squircle ~ 824x824 centered (so ~100px breathing room each side)
// - Squircle corner radius ~185 (Apple's spec is ~22% of inner size)

let pad: CGFloat = 100
let inner = NSRect(x: pad, y: pad, width: canvas.width - 2*pad, height: canvas.height - 2*pad)
let squircleRadius: CGFloat = 185

let squircle = NSBezierPath(roundedRect: inner, xRadius: squircleRadius, yRadius: squircleRadius)
bg.setFill()
squircle.fill()

// Three stacked windows. Each gets a title-bar strip so it reads as a window, not a card.
// Sizes step down front-to-back, offsets nest tight.
let center = NSPoint(x: canvas.width/2, y: canvas.height/2)
let winRadius: CGFloat = 44

// macOS traffic-light colors
let dotRed    = NSColor(red: 1.000, green: 0.373, blue: 0.341, alpha: 1.0) // #FF5F57
let dotYellow = NSColor(red: 1.000, green: 0.737, blue: 0.180, alpha: 1.0) // #FEBC2E
let dotGreen  = NSColor(red: 0.157, green: 0.784, blue: 0.251, alpha: 1.0) // #28C840

func drawWindow(offsetX: CGFloat, offsetY: CGFloat, size: CGFloat, fill: NSColor, titleBarTone: NSColor, withDots: Bool = false) {
    let rect = NSRect(
        x: center.x - size/2 + offsetX,
        y: center.y - size/2 + offsetY,
        width: size,
        height: size
    )
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()

    // Window body
    let body = NSBezierPath(roundedRect: rect, xRadius: winRadius, yRadius: winRadius)
    fill.setFill()
    body.fill()

    // Title-bar strip across the top, clipped to the rounded body
    let barHeight: CGFloat = 56
    let barRect = NSRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)
    NSGraphicsContext.saveGraphicsState()
    body.addClip()
    titleBarTone.setFill()
    barRect.fill()

    if withDots {
        let dotDiameter: CGFloat = 14
        let dotSpacing: CGFloat = 24
        let leftPad: CGFloat = 22
        let cy = barRect.midY - dotDiameter / 2
        let cxStart = barRect.minX + leftPad
        for (i, color) in [dotRed, dotYellow, dotGreen].enumerated() {
            let cx = cxStart + CGFloat(i) * dotSpacing
            let dotRect = NSRect(x: cx, y: cy, width: dotDiameter, height: dotDiameter)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
}

// Tone helper: subtle shade of the same window color for the title bar.
func tone(_ base: NSColor, factor: CGFloat) -> NSColor {
    let r = max(0, base.redComponent * factor)
    let g = max(0, base.greenComponent * factor)
    let b = max(0, base.blueComponent * factor)
    return NSColor(red: r, green: g, blue: b, alpha: 1)
}

// Cluster centered: shift each window by -step/2, +step/2 so the diagonal averages at canvas center.
let step: CGFloat = 78
drawWindow(offsetX: -1.5*step, offsetY:  1.5*step, size: 380, fill: creamDim, titleBarTone: tone(creamDim, factor: 0.82))
drawWindow(offsetX: -0.5*step, offsetY:  0.5*step, size: 420, fill: cream,    titleBarTone: tone(cream,    factor: 0.86))
drawWindow(offsetX:  0.5*step, offsetY: -0.5*step, size: 460, fill: rose,     titleBarTone: tone(rose,     factor: 0.82), withDots: true)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("error: png encode failed\n", stderr)
    exit(1)
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/icon-1024.png"
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

#!/usr/bin/env swift
// Flusso app icon generator.
//
// Concept: three glassy waveform bars ("la voce") flow left-to-right into a
// bright text caret ("il testo"), on a deep blue→violet gradient squircle.
//
// Usage (from the repo root):
//   swift scripts/icon/make-icon.swift
//
// Outputs:
//   scripts/icon/AppIcon-1024.png                      (master)
//   App/Resources/Assets.xcassets/AppIcon.appiconset/  (all mac sizes + Contents.json)
//
// Everything is drawn in a 1024×1024 design space and rendered natively at each
// pixel size (no downsampling), following Apple's macOS icon grid: 824×824 body,
// centered, continuous-corner radius ≈185, drop shadow in the 100 px margin.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let iconSetURL = repoRoot.appendingPathComponent("App/Resources/Assets.xcassets/AppIcon.appiconset")
let masterURL = repoRoot.appendingPathComponent("scripts/icon/AppIcon-1024.png")

// MARK: - Helpers

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: srgb,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            a,
        ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: srgb,
        colors: stops.map { $0.1 } as CFArray,
        locations: stops.map { $0.0 })!
}

/// Rounded rect whose corners are quarter superellipses (n > 2 ⇒ zero curvature
/// where the corner meets the straight edge), i.e. Apple-style continuous corners.
/// `radius` is the equivalent circular radius; the corner actually spans ~1.53×.
func continuousRect(_ r: CGRect, radius: CGFloat, exponent n: CGFloat = 3.3) -> CGPath {
    let s = min(radius * 1.528, min(r.width, r.height) / 2)
    let p = CGMutablePath()
    let steps = 96
    // corner centres (inner) and quadrant directions, counter-clockwise from bottom-right (y-up)
    let corners: [(CGPoint, CGFloat, CGFloat, CGFloat)] = [
        (CGPoint(x: r.maxX - s, y: r.minY + s), 1, -1, -.pi / 2),  // bottom-right
        (CGPoint(x: r.maxX - s, y: r.maxY - s), 1, 1, 0),          // top-right
        (CGPoint(x: r.minX + s, y: r.maxY - s), -1, 1, .pi / 2),   // top-left
        (CGPoint(x: r.minX + s, y: r.minY + s), -1, -1, .pi),      // bottom-left
    ]
    var first = true
    for (c, _, _, start) in corners {
        for i in 0...steps {
            let t = start + (.pi / 2) * CGFloat(i) / CGFloat(steps)
            let ct = cos(t), st = sin(t)
            let x = c.x + s * copysign(pow(abs(ct), 2 / n), ct)
            let y = c.y + s * copysign(pow(abs(st), 2 / n), st)
            if first { p.move(to: CGPoint(x: x, y: y)); first = false } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
    }
    p.closeSubpath()
    return p
}

func capsule(_ r: CGRect) -> CGPath {
    let rad = min(r.width, r.height) / 2
    return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

// MARK: - Design (1024 space, y-up)

struct Design {
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let bodyRadius: CGFloat = 185

    // Waveform bars + caret. Small renders get chunkier geometry for legibility.
    static func elements(pixelSize: Int) -> (bars: [CGRect], caret: CGRect) {
        // Hand-hinted, pixel-snapped layouts for the tiny sizes: (start x, bar w, gap, caret w,
        // bar heights, caret h) in device pixels, all on whole pixels around the centre line.
        let hinted: [Int: (CGFloat, CGFloat, CGFloat, CGFloat, [CGFloat], CGFloat)] = [
            16: (3, 2, 1, 1, [4, 8, 6], 10),
            32: (7, 3, 2, 2, [8, 16, 12], 20),
        ]
        if let (x0, bw, g, cw, hs, ch) = hinted[pixelSize] {
            let u = 1024 / CGFloat(pixelSize)
            let mid = CGFloat(pixelSize) / 2
            var x = x0
            var bars: [CGRect] = []
            for h in hs {
                bars.append(CGRect(x: x * u, y: (mid - h / 2) * u, width: bw * u, height: h * u))
                x += bw + g
            }
            return (bars, CGRect(x: x * u, y: (mid - ch / 2) * u, width: cw * u, height: ch * u))
        }
        let barW: CGFloat = 96
        let gap: CGFloat = 50
        let caretW: CGFloat = 64
        let heights: [CGFloat] = [236, 432, 312]
        let caretH: CGFloat = 528
        let caretGap: CGFloat = 68  // a little extra air: sound ends, text begins
        let total = barW * 3 + gap * 2 + caretGap + caretW
        var x = 512 - total / 2
        let cy: CGFloat = 512
        var bars: [CGRect] = []
        for h in heights {
            bars.append(CGRect(x: x, y: cy - h / 2, width: barW, height: h))
            x += barW + gap
        }
        let caret = CGRect(x: x - gap + caretGap, y: cy - caretH / 2, width: caretW, height: caretH)
        return (bars, caret)
    }
}

// MARK: - Rendering

func render(pixelSize: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixelSize, height: pixelSize, bitsPerComponent: 8, bytesPerRow: 0,
        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(pixelSize) / 1024  // shadows are not affected by the CTM: scale them by hand
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: k, y: k)

    let small = pixelSize <= 32
    let body = continuousRect(Design.body, radius: Design.bodyRadius)

    // 1. Drop shadow in the margin (macOS grid style).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: rgb(0x000000, 0.32))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0x1A1F5C))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Background gradient.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([
            (0.00, rgb(0x8A5CFF)),
            (0.45, rgb(0x4F46E5)),
            (1.00, rgb(0x0E7BD8)),
        ]),
        start: CGPoint(x: 230, y: 924), end: CGPoint(x: 800, y: 100), options: [])
    // warm glow top-left
    ctx.drawRadialGradient(
        gradient([(0, rgb(0xFF7AC8, 0.55)), (1, rgb(0xFF7AC8, 0))]),
        startCenter: CGPoint(x: 220, y: 880), startRadius: 0,
        endCenter: CGPoint(x: 220, y: 880), endRadius: 520, options: [])
    // cool glow bottom-right
    ctx.drawRadialGradient(
        gradient([(0, rgb(0x3FE0FF, 0.45)), (1, rgb(0x3FE0FF, 0))]),
        startCenter: CGPoint(x: 860, y: 150), startRadius: 0,
        endCenter: CGPoint(x: 860, y: 150), endRadius: 520, options: [])
    // soft top sheen
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF, 0.16)), (1, rgb(0xFFFFFF, 0))]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // 3. Foreground: glass waveform bars flowing into a caret.
    let (bars, caret) = Design.elements(pixelSize: pixelSize)

    // Contact shadows under all elements (clipped to the outside, so the glass stays clean).
    if !small {
        ctx.saveGState()
        ctx.addRect(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        for r in bars + [caret] { ctx.addPath(capsule(r)) }
        ctx.clip(using: .evenOdd)
        ctx.addPath(body)
        ctx.clip()
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * k), blur: 40 * k, color: rgb(0x14105A, 0.45))
        for r in bars + [caret] { ctx.addPath(capsule(r)) }
        ctx.setFillColor(rgb(0x000000))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Glass bars: increasingly solid left→right — the voice condensing into text.
    let solidity: [CGFloat] = small ? [0.78, 0.86, 0.94] : [0.62, 0.78, 0.92]
    for (i, r) in bars.enumerated() {
        let path = capsule(r)
        let f = solidity[i]
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        // body: light at top, clearer at bottom so the background tint shows through
        ctx.drawLinearGradient(
            gradient([
                (0.0, rgb(0xFFFFFF, f)),
                (1.0, rgb(0xF2F4FF, f * (small ? 0.85 : 0.62))),
            ]),
            start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
        if !small {
            // soft cool refraction tint along the right edge
            ctx.drawLinearGradient(
                gradient([(0, rgb(0xB9D4FF, 0)), (0.6, rgb(0xB9D4FF, 0)), (1, rgb(0x9FC2FF, 0.35))]),
                start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
            // specular highlight: a short vertical streak near the top-left
            let streak = CGRect(x: r.minX + r.width * 0.2, y: r.maxY - r.width * 0.25 - min(r.height * 0.45, 170),
                                width: r.width * 0.16, height: min(r.height * 0.45, 170))
            ctx.addPath(capsule(streak))
            ctx.clip()
            ctx.drawLinearGradient(
                gradient([(0, rgb(0xFFFFFF, 0.9)), (1, rgb(0xFFFFFF, 0))]),
                start: CGPoint(x: streak.midX, y: streak.maxY), end: CGPoint(x: streak.midX, y: streak.minY), options: [])
        }
        ctx.restoreGState()
        if !small {
            // specular rim: bright on top, fading, with a faint bounce at the bottom
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()  // keep only the inner half of the stroke
            ctx.addPath(path)
            ctx.setLineWidth(8)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(
                gradient([(0, rgb(0xFFFFFF, 1)), (0.45, rgb(0xFFFFFF, 0.25)), (1, rgb(0xFFFFFF, 0.55))]),
                start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
            ctx.restoreGState()
        }
    }

    // Caret: solid, luminous — the written word.
    do {
        let path = capsule(caret)
        ctx.saveGState()
        if !small {
            ctx.setShadow(offset: .zero, blur: 50 * k, color: rgb(0xE6F0FF, 0.6))
        }
        ctx.addPath(path)
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()
        if !small {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.drawLinearGradient(
                gradient([(0, rgb(0xFFFFFF)), (0.6, rgb(0xFFFFFF)), (1, rgb(0xDCE8FF))]),
                start: CGPoint(x: caret.midX, y: caret.maxY), end: CGPoint(x: caret.midX, y: caret.minY), options: [])
            ctx.restoreGState()
        }
    }

    // 4. Specular rim on the body (glass edge).
    if !small {
        ctx.saveGState()
        ctx.addPath(body)
        ctx.clip()
        ctx.addPath(body)
        ctx.setLineWidth(8)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, rgb(0xFFFFFF, 0.7)), (0.35, rgb(0xFFFFFF, 0.1)), (0.8, rgb(0xFFFFFF, 0.12)), (1, rgb(0xFFFFFF, 0.35))]),
            start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        ctx.restoreGState()
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "failed to write \(url.path)")
}

// MARK: - Main

try fm.createDirectory(at: iconSetURL, withIntermediateDirectories: true)

writePNG(render(pixelSize: 1024), to: masterURL)
print("master  \(masterURL.path)")

var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pt * scale
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        writePNG(render(pixelSize: px), to: iconSetURL.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
        print("  \(px)px  \(name)")
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSetURL.appendingPathComponent("Contents.json"))
print("Contents.json written")

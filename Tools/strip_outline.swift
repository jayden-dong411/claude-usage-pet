// Removes the white sticker outline around each Claude大小姐 head image.
// Usage: swift strip_outline.swift <input dir> <output dir>
//
// Flood-fills from the transparent outside through near-white pixels; the fill stops
// at the character's dark line art, so whites inside the drawing (eyes, blouse) stay.
// Light anti-aliased pixels left on the new edge are faded out.
import AppKit
import CoreGraphics

func process(_ src: URL, _ dst: URL) -> Bool {
    guard let img = NSImage(contentsOf: src),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
    let w = cg.width, h = cg.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    // Un-premultiplied lightness / saturation helpers.
    @inline(__always) func rgb(_ i: Int) -> (Int, Int, Int, Int) {
        let a = Int(px[i * 4 + 3])
        guard a > 0 else { return (0, 0, 0, 0) }
        let f = { (v: UInt8) in min(255, Int(v) * 255 / a) }
        return (f(px[i * 4]), f(px[i * 4 + 1]), f(px[i * 4 + 2]), a)
    }
    @inline(__always) func whiteish(_ i: Int) -> Bool {
        let (r, g, b, a) = rgb(i)
        if a < 10 { return true }
        let lo = min(r, g, b), hi = max(r, g, b)
        return lo >= 200 && hi - lo <= 40
    }

    var removed = [Bool](repeating: false, count: w * h)
    var queue: [Int] = []
    queue.reserveCapacity(w * h / 4)
    for x in 0..<w { queue.append(x); queue.append((h - 1) * w + x) }
    for y in 0..<h { queue.append(y * w); queue.append(y * w + w - 1) }
    var head = 0
    for i in queue where whiteish(i) { removed[i] = true }
    queue = queue.filter { removed[$0] }
    while head < queue.count {
        let i = queue[head]; head += 1
        let x = i % w, y = i / w
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
            let j = ny * w + nx
            if !removed[j] && whiteish(j) { removed[j] = true; queue.append(j) }
        }
    }
    for i in 0..<(w * h) where removed[i] { px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0 }

    // Two passes of edge softening: fade light, low-saturation pixels next to the cleared area.
    for _ in 0..<2 {
        var fade: [(Int, Int)] = []
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                guard px[i * 4 + 3] > 0 else { continue }
                let touches = [i - 1, i + 1, i - w, i + w].contains { px[$0 * 4 + 3] == 0 }
                guard touches else { continue }
                let (r, g, b, a) = rgb(i)
                let lo = min(r, g, b), hi = max(r, g, b)
                guard lo > 150, hi - lo < 60 else { continue }
                let keep = max(0, min(255, (255 - lo) * 255 / 105))   // lo 150 -> keep all, 255 -> none
                fade.append((i, a * keep / 255))
            }
        }
        for (i, na) in fade {
            let (r, g, b, _) = rgb(i)
            px[i * 4] = UInt8(r * na / 255); px[i * 4 + 1] = UInt8(g * na / 255)
            px[i * 4 + 2] = UInt8(b * na / 255); px[i * 4 + 3] = UInt8(na)
        }
    }

    guard let out = ctx.makeImage() else { return false }
    let rep = NSBitmapImageRep(cgImage: out)
    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: dst)) != nil
}

let args = CommandLine.arguments
let inDir = URL(fileURLWithPath: args[1]), outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let files = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? []
var ok = 0
for f in files where f.pathExtension == "png" {
    if process(f, outDir.appendingPathComponent(f.lastPathComponent)) { ok += 1 } else { print("失败：\(f.lastPathComponent)") }
}
print("  去白边：\(ok) 张")

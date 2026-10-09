//
//  HistogramView.swift
//  RawLight
//
//  A live RGB histogram computed from the actual rendered preview image. It
//  recomputes (off the main thread) whenever the render version changes, so it
//  reflects the real effect of every develop adjustment.
//

import SwiftUI
import CoreGraphics

struct HistogramBins: Equatable, Sendable {
    var r: [Float]
    var g: [Float]
    var b: [Float]
}

struct HistogramView: View {
    let image: CGImage?
    /// Increments on every new render so the view knows to recompute.
    let version: Int

    @State private var bins: HistogramBins?

    private let binCount = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Theme.surface)
            if let bins {
                Canvas { ctx, size in
                    draw(bins.r, color: .red, ctx: &ctx, size: size)
                    draw(bins.g, color: .green, ctx: &ctx, size: size)
                    draw(bins.b, color: .blue, ctx: &ctx, size: size)
                }
                .padding(6)
            } else {
                Text("Histogram")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .task(id: version) {
            guard let image else { return }
            bins = await Self.compute(image, binCount: binCount)
        }
    }

    // MARK: Drawing

    private func draw(_ data: [Float], color: Color, ctx: inout GraphicsContext, size: CGSize) {
        guard data.count > 1 else { return }
        var path = Path()
        let stepX = size.width / CGFloat(data.count - 1)
        path.move(to: CGPoint(x: 0, y: size.height))
        for (i, v) in data.enumerated() {
            let x = CGFloat(i) * stepX
            let y = size.height * (1 - CGFloat(v))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        ctx.fill(path, with: .color(color.opacity(0.5)))
    }

    // MARK: Compute (off main thread)

    nonisolated static func compute(_ cg: CGImage, binCount: Int) async -> HistogramBins {
        await Task.detached(priority: .utility) {
            let w = min(cg.width, 200), h = min(cg.height, 200)
            let cs = CGColorSpaceCreateDeviceRGB()
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(
                data: &pixels, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return HistogramBins(r: [], g: [], b: [])
            }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

            var r = [Float](repeating: 0, count: binCount)
            var g = [Float](repeating: 0, count: binCount)
            var b = [Float](repeating: 0, count: binCount)
            let scale = Float(binCount) / 256.0
            var i = 0
            while i < pixels.count {
                r[min(binCount - 1, Int(Float(pixels[i]) * scale))] += 1
                g[min(binCount - 1, Int(Float(pixels[i + 1]) * scale))] += 1
                b[min(binCount - 1, Int(Float(pixels[i + 2]) * scale))] += 1
                i += 4
            }
            normalize(&r); normalize(&g); normalize(&b)
            return HistogramBins(r: r, g: g, b: b)
        }.value
    }

    private nonisolated static func normalize(_ a: inout [Float]) {
        let maxV = a.max() ?? 1
        guard maxV > 0 else { return }
        for i in a.indices { a[i] = a[i] / maxV }
    }
}

//
//  ToneCurveLUT.swift
//  RawLight
//
//  Turns a set of tone-curve control points into a smooth 1-D lookup table that
//  Core Image's `CIColorCurves` can apply on the GPU.
//
//  Uses monotone cubic Hermite interpolation (Fritsch–Carlson), which passes
//  through every control point and — crucially — never overshoots or creates
//  wiggles between points. That is exactly what a photographic tone curve needs.
//

import Foundation

nonisolated enum ToneCurveLUT {

    /// Evaluates `points` into a `sampleCount`-entry LUT in 0...1.
    static func lut(from points: [CurvePoint], sampleCount: Int = 256) -> [Float] {
        let pts = sanitized(points)
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let slopes = monotoneTangents(xs: xs, ys: ys)

        var out = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let x = Double(i) / Double(sampleCount - 1)
            out[i] = Float(min(1, max(0, evaluate(x, xs: xs, ys: ys, slopes: slopes))))
        }
        return out
    }

    /// Builds an interleaved RGB LUT that applies the master (luminance) curve to
    /// all channels, then each per-channel curve on top: `channel(master(x))`.
    /// Suitable directly for `CIColorCurves.curvesData`.
    static func channelLUT(master: [CurvePoint],
                           red: [CurvePoint], green: [CurvePoint], blue: [CurvePoint],
                           sampleCount: Int = 256) -> [Float] {
        let m = prepared(master)
        let r = prepared(red), g = prepared(green), b = prepared(blue)
        var out = [Float](); out.reserveCapacity(sampleCount * 3)
        for i in 0..<sampleCount {
            let x = Double(i) / Double(sampleCount - 1)
            let mv = eval(x, m)
            out.append(Float(min(1, max(0, eval(mv, r)))))
            out.append(Float(min(1, max(0, eval(mv, g)))))
            out.append(Float(min(1, max(0, eval(mv, b)))))
        }
        return out
    }

    /// Scalar evaluation of the curve at `x` (used by the editor to draw it).
    static func value(at x: Double, points: [CurvePoint]) -> Double {
        let pts = sanitized(points)
        let xs = pts.map(\.x)
        let ys = pts.map(\.y)
        let slopes = monotoneTangents(xs: xs, ys: ys)
        return min(1, max(0, evaluate(x, xs: xs, ys: ys, slopes: slopes)))
    }

    // MARK: Interpolation

    struct Prepared { let xs: [Double]; let ys: [Double]; let slopes: [Double] }

    static func prepared(_ points: [CurvePoint]) -> Prepared {
        let pts = sanitized(points)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return Prepared(xs: xs, ys: ys, slopes: monotoneTangents(xs: xs, ys: ys))
    }

    static func eval(_ x: Double, _ p: Prepared) -> Double {
        min(1, max(0, evaluate(x, xs: p.xs, ys: p.ys, slopes: p.slopes)))
    }

    private static func sanitized(_ points: [CurvePoint]) -> [CurvePoint] {
        var pts = points.sorted { $0.x < $1.x }
        if pts.count < 2 { pts = DevelopSettings.linearCurve }
        // De-duplicate identical x values to keep secants finite.
        var result: [CurvePoint] = []
        for p in pts {
            if let last = result.last, abs(last.x - p.x) < 1e-6 { continue }
            result.append(p)
        }
        return result.count >= 2 ? result : DevelopSettings.linearCurve
    }

    /// Fritsch–Carlson monotone tangents.
    private static func monotoneTangents(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        guard n >= 2 else { return [Double](repeating: 0, count: n) }

        var secants = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            secants[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i])
        }

        var m = [Double](repeating: 0, count: n)
        m[0] = secants[0]
        m[n - 1] = secants[n - 2]
        for i in 1..<(n - 1) {
            if secants[i - 1] * secants[i] <= 0 {
                m[i] = 0
            } else {
                m[i] = (secants[i - 1] + secants[i]) / 2
            }
        }

        // Fritsch–Carlson monotonicity filter: clamp tangents so each cubic
        // segment stays monotone (no overshoot/undershoot between points).
        for i in 0..<(n - 1) {
            let d = secants[i]
            if d == 0 { m[i] = 0; m[i + 1] = 0; continue }
            if m[i] / d < 0 { m[i] = 0 }
            if m[i + 1] / d < 0 { m[i + 1] = 0 }
            let alpha = m[i] / d
            let beta = m[i + 1] / d
            let sumSq = alpha * alpha + beta * beta
            if sumSq > 9 {
                let tau = 3.0 / sumSq.squareRoot()
                m[i] = tau * alpha * d
                m[i + 1] = tau * beta * d
            }
        }
        return m
    }

    private static func evaluate(_ x: Double, xs: [Double], ys: [Double], slopes m: [Double]) -> Double {
        if x <= xs.first! { return ys.first! }
        if x >= xs.last! { return ys.last! }

        var k = 0
        while k < xs.count - 1 && x > xs[k + 1] { k += 1 }

        let h = xs[k + 1] - xs[k]
        let t = (x - xs[k]) / h
        let t2 = t * t
        let t3 = t2 * t

        // Hermite basis.
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2

        return h00 * ys[k] + h10 * h * m[k] + h01 * ys[k + 1] + h11 * h * m[k + 1]
    }
}

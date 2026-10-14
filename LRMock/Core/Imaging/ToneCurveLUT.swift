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

    /// Maps the four foundation tone controls into a bounded, monotone value.
    /// Each control bends only its tonal range and fixes that range's endpoints,
    /// so composing controls cannot introduce reversals or clipped plateaus.
    static func basicToneValue(
        at x: Double,
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0
    ) -> Double {
        var value = unitValue(x)
        value = bend(value, from: 0, to: 0.30, amount: blacks, strength: 0.65)
        value = bend(value, from: 0, to: 0.65, amount: shadows, strength: 0.55)
        value = bend(value, from: 0.35, to: 1, amount: highlights, strength: 0.55)
        value = bend(value, from: 0.70, to: 1, amount: whites, strength: 0.65)
        return unitValue(value)
    }

    /// Lightroom-style parametric regions. Each range is an endpoint-preserving
    /// monotone bend, so adjacent ranges meet continuously at their split.
    static func parametricToneValue(
        at x: Double,
        highlights: Double = 0,
        lights: Double = 0,
        darks: Double = 0,
        shadows: Double = 0,
        splitShadows: Double = 0.25,
        splitMid: Double = 0.5,
        splitHighlights: Double = 0.75
    ) -> Double {
        let splits = orderedSplits(splitShadows, splitMid, splitHighlights)
        var value = unitValue(x)
        value = bend(value, from: 0, to: splits.0, amount: shadows, strength: 0.72)
        value = bend(value, from: splits.0, to: splits.1, amount: darks, strength: 0.72)
        value = bend(value, from: splits.1, to: splits.2, amount: lights, strength: 0.72)
        value = bend(value, from: splits.2, to: 1, amount: highlights, strength: 0.72)
        return unitValue(value)
    }

    static func parametricToneLUT(
        highlights: Double = 0,
        lights: Double = 0,
        darks: Double = 0,
        shadows: Double = 0,
        splitShadows: Double = 0.25,
        splitMid: Double = 0.5,
        splitHighlights: Double = 0.75,
        sampleCount: Int = 256
    ) -> [Float] {
        guard sampleCount > 0 else { return [] }
        if sampleCount == 1 {
            return [Float(parametricToneValue(
                at: 0, highlights: highlights, lights: lights, darks: darks,
                shadows: shadows, splitShadows: splitShadows, splitMid: splitMid,
                splitHighlights: splitHighlights
            ))]
        }
        return (0..<sampleCount).map { index in
            let x = Double(index) / Double(sampleCount - 1)
            return Float(parametricToneValue(
                at: x, highlights: highlights, lights: lights, darks: darks,
                shadows: shadows, splitShadows: splitShadows, splitMid: splitMid,
                splitHighlights: splitHighlights
            ))
        }
    }

    /// Amount mixed toward a saturation-preserving curve result. A cap keeps the
    /// operation photographic when channel curves intentionally alter colour.
    static func saturationPreservationAmount(refine: Double) -> Double {
        let refine = unitValue(refine)
        return (1 - refine) * 0.8
    }

    /// Samples the pure foundation-tone mapping for tests and non-GPU callers.
    static func basicToneLUT(
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        sampleCount: Int = 256
    ) -> [Float] {
        guard sampleCount > 0 else { return [] }
        if sampleCount == 1 {
            return [Float(basicToneValue(
                at: 0, highlights: highlights, shadows: shadows,
                whites: whites, blacks: blacks
            ))]
        }
        return (0..<sampleCount).map { index in
            let x = Double(index) / Double(sampleCount - 1)
            return Float(basicToneValue(
                at: x, highlights: highlights, shadows: shadows,
                whites: whites, blacks: blacks
            ))
        }
    }

    /// Evaluates `points` into a `sampleCount`-entry LUT in 0...1.
    static func lut(from points: [CurvePoint], sampleCount: Int = 256) -> [Float] {
        guard sampleCount > 0 else { return [] }
        if sampleCount == 1 { return [Float(value(at: 0, points: points))] }
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
    /// all channels, then each per-channel curve on top:
    /// `channel(master(basicTone(x)))`.
    /// Suitable directly for `CIColorCurves.curvesData`.
    static func channelLUT(master: [CurvePoint],
                           red: [CurvePoint], green: [CurvePoint], blue: [CurvePoint],
                           sampleCount: Int = 256,
                           highlights: Double = 0, shadows: Double = 0,
                           whites: Double = 0, blacks: Double = 0,
                           curveHighlights: Double = 0, curveLights: Double = 0,
                           curveDarks: Double = 0, curveShadows: Double = 0,
                           splitShadows: Double = 0.25, splitMid: Double = 0.5,
                           splitHighlights: Double = 0.75) -> [Float] {
        guard sampleCount > 0 else { return [] }
        let m = prepared(master)
        let r = prepared(red), g = prepared(green), b = prepared(blue)
        var channels = Array(repeating: [Double](), count: 3)
        for index in channels.indices { channels[index].reserveCapacity(sampleCount) }
        for i in 0..<sampleCount {
            let x = sampleCount == 1 ? 0 : Double(i) / Double(sampleCount - 1)
            let foundation = basicToneValue(
                at: x, highlights: highlights, shadows: shadows,
                whites: whites, blacks: blacks
            )
            let parametric = parametricToneValue(
                at: foundation,
                highlights: curveHighlights,
                lights: curveLights,
                darks: curveDarks,
                shadows: curveShadows,
                splitShadows: splitShadows,
                splitMid: splitMid,
                splitHighlights: splitHighlights
            )
            let mv = eval(parametric, m)
            channels[0].append(unitValue(eval(mv, r)))
            channels[1].append(unitValue(eval(mv, g)))
            channels[2].append(unitValue(eval(mv, b)))
        }

        // Malformed imported point curves can contain descending y values. Keep
        // the final GPU LUT monotone rather than allowing local tone reversals.
        for channel in channels.indices {
            for index in 1..<channels[channel].count {
                channels[channel][index] = max(
                    channels[channel][index], channels[channel][index - 1]
                )
            }
        }

        var out = [Float](); out.reserveCapacity(sampleCount * 3)
        for index in 0..<sampleCount {
            out.append(Float(channels[0][index]))
            out.append(Float(channels[1][index]))
            out.append(Float(channels[2][index]))
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

    /// `t + a*t*(1-t)` has derivative `1 + a*(1-2t)`. Keeping the effective
    /// amount below one therefore guarantees a non-decreasing range mapping.
    private static func bend(
        _ value: Double,
        from lowerBound: Double,
        to upperBound: Double,
        amount: Double,
        strength: Double
    ) -> Double {
        guard value > lowerBound, value < upperBound else { return value }
        let width = upperBound - lowerBound
        let t = (value - lowerBound) / width
        let effectiveAmount = normalizedAmount(amount) * strength
        return lowerBound + width * (t + effectiveAmount * t * (1 - t))
    }

    private static func normalizedAmount(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }

    private static func unitValue(_ value: Double) -> Double {
        guard value.isFinite else { return value.sign == .plus ? 1 : 0 }
        return min(1, max(0, value))
    }

    private static func orderedSplits(
        _ shadow: Double,
        _ mid: Double,
        _ highlight: Double
    ) -> (Double, Double, Double) {
        let values = [shadow, mid, highlight]
            .map(unitValue)
            .sorted()
        let first = min(0.97, max(0.01, values[0]))
        let second = min(0.98, max(first + 0.01, values[1]))
        let third = min(0.99, max(second + 0.01, values[2]))
        return (first, second, third)
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

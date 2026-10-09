//
//  ColorCubeEngine.swift
//  RawLight
//
//  Builds a 3-D colour lookup table (LUT) for Core Image's `CIColorCube`, which
//  applies arbitrary colour transforms on the GPU in a single pass. This is the
//  native, high-performance way to do complex colour work on iOS.
//
//  Currently it implements the 8-band **HSL / Color Mixer** (per-colour Hue /
//  Saturation / Luminance), the tool Lightroom calls the Color Mixer and
//  RawTherapee calls the HSV Equalizer. The same engine will back Color Grading
//  and film-look LUTs later — only the per-cell transform changes.
//
//  The cube is rebuilt on the CPU only when the settings change (a few thousand
//  cheap HSL conversions) and cached; Core Image then samples it for free.
//

import Foundation
import CoreImage

nonisolated enum ColorCubeEngine {

    /// Hue centres (degrees) for the 8 mixer bands:
    /// Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta.
    static let bandCenters: [Double] = [0, 30, 60, 120, 180, 240, 290, 330]

    struct Cube { let dimension: Int; let data: Data }

    // Simple single-entry cache (the inspector edits one image at a time).
    private static var cache: (mix: ColorMix, cube: Cube)?
    private static let lock = NSLock()

    /// Returns a cached/freshly-built HSL cube for `mix`, or nil if identity.
    static func hslCube(for mix: ColorMix, dimension: Int = 16) -> Cube? {
        guard !mix.isIdentity else { return nil }

        lock.lock()
        if let cached = cache, cached.mix == mix {
            lock.unlock()
            return cached.cube
        }
        lock.unlock()

        let cube = build(mix: mix, dimension: dimension)
        lock.lock(); cache = (mix, cube); lock.unlock()
        return cube
    }

    // MARK: Color grading (3-way split toning)

    private static var gradeCache: (grade: ColorGrade, cube: Cube)?

    /// Builds a cube that tints shadows / midtones / highlights by luminance.
    static func gradingCube(for grade: ColorGrade, dimension n: Int = 16) -> Cube? {
        guard !grade.isIdentity else { return nil }
        lock.lock()
        if let cached = gradeCache, cached.grade == grade { lock.unlock(); return cached.cube }
        lock.unlock()

        let shadow = tintOffset(hue: grade.shadowHue, sat: grade.shadowSat)
        let mid = tintOffset(hue: grade.midHue, sat: grade.midSat)
        let high = tintOffset(hue: grade.highHue, sat: grade.highSat)

        var floats = [Float](); floats.reserveCapacity(n * n * n * 4)
        let denom = Double(n - 1)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let r = Double(ri) / denom, g = Double(gi) / denom, b = Double(bi) / denom
            let l = 0.299 * r + 0.587 * g + 0.114 * b
            let wHi = smoothstep(0.3, 0.9, l)
            let wSh = 1 - smoothstep(0.1, 0.7, l)
            let wMid = max(0, 1 - wHi - wSh)
            let t = SIMD3(shadow.x * wSh + mid.x * wMid + high.x * wHi,
                          shadow.y * wSh + mid.y * wMid + high.y * wHi,
                          shadow.z * wSh + mid.z * wMid + high.z * wHi)
            floats.append(Float(clamp01(r + t.x)))
            floats.append(Float(clamp01(g + t.y)))
            floats.append(Float(clamp01(b + t.z)))
            floats.append(1)
        }}}
        let cube = Cube(dimension: n, data: floats.withUnsafeBytes { Data($0) })
        lock.lock(); gradeCache = (grade, cube); lock.unlock()
        return cube
    }

    private static func tintOffset(hue: Double, sat: Double) -> SIMD3<Double> {
        guard sat > 0 else { return SIMD3(0, 0, 0) }
        let c = hsl2rgb(SIMD3(hue, 1, 0.5))
        return SIMD3((c.x - 0.5) * sat * 0.5, (c.y - 0.5) * sat * 0.5, (c.z - 0.5) * sat * 0.5)
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    // MARK: Build

    private static let hueBuckets = 256

    private static func build(mix: ColorMix, dimension n: Int) -> Cube {
        // Precompute the per-hue adjustment ONCE (256 buckets) instead of doing
        // the 8-band cosine weighting for every one of the n³ cube cells. This
        // removes ~33k trig calls per build and is the main cube optimisation.
        var hueShiftTable = [Double](repeating: 0, count: hueBuckets)
        var satTable = [Double](repeating: 0, count: hueBuckets)
        var lumTable = [Double](repeating: 0, count: hueBuckets)
        var weights = [Double](repeating: 0, count: ColorMix.bandCount)
        for bucket in 0..<hueBuckets {
            bandWeights(hueDegrees: Double(bucket) / Double(hueBuckets) * 360, into: &weights)
            var hs = 0.0, sa = 0.0, lu = 0.0
            for b in 0..<ColorMix.bandCount {
                hs += weights[b] * mix.hue[b]
                sa += weights[b] * mix.saturation[b]
                lu += weights[b] * mix.luminance[b]
            }
            hueShiftTable[bucket] = hs * (30.0 / 360.0) // ±30° per unit, in turns
            satTable[bucket] = sa
            lumTable[bucket] = lu
        }

        var floats = [Float](repeating: 0, count: n * n * n * 4)
        let denom = Double(n - 1)
        floats.withUnsafeMutableBufferPointer { buf in
            var o = 0
            for bi in 0..<n {
                let bb = Double(bi) / denom
                for gi in 0..<n {
                    let gg = Double(gi) / denom
                    for ri in 0..<n {
                        var hsl = rgb2hsl(SIMD3(Double(ri) / denom, gg, bb))
                        // Grays (s≈0) are unaffected by a hue mixer — skip.
                        if hsl.y > 0.0001 {
                            let bucket = min(hueBuckets - 1, max(0, Int(hsl.x * Double(hueBuckets))))
                            hsl.x = (hsl.x + hueShiftTable[bucket]).truncatingRemainder(dividingBy: 1)
                            if hsl.x < 0 { hsl.x += 1 }
                            hsl.y = clamp01(hsl.y * (1 + satTable[bucket]))
                            hsl.z = clamp01(hsl.z + lumTable[bucket] * 0.5)
                            let rgb = hsl2rgb(hsl)
                            buf[o] = Float(rgb.x); buf[o + 1] = Float(rgb.y); buf[o + 2] = Float(rgb.z)
                        } else {
                            let v = Float(hsl.z)
                            buf[o] = v; buf[o + 1] = v; buf[o + 2] = v
                        }
                        buf[o + 3] = 1
                        o += 4
                    }
                }
            }
        }
        return Cube(dimension: n, data: floats.withUnsafeBytes { Data($0) })
    }

    /// Normalised influence of each band on a given hue (cosine falloff), written
    /// into a reusable buffer to avoid per-call allocation.
    private static func bandWeights(hueDegrees h: Double, into w: inout [Double]) {
        let influence = 50.0
        var sum = 0.0
        for b in 0..<ColorMix.bandCount {
            let raw = abs(h - bandCenters[b])
            let dist = min(raw, 360 - raw)
            if dist < influence {
                let weight = cos(dist / influence * .pi / 2)
                w[b] = weight
                sum += weight
            } else {
                w[b] = 0
            }
        }
        if sum > 0 { for b in w.indices { w[b] /= sum } }
    }

    // MARK: Colour conversions (h,s,l all 0...1)

    private static func rgb2hsl(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let maxV = max(c.x, max(c.y, c.z))
        let minV = min(c.x, min(c.y, c.z))
        let l = (maxV + minV) / 2
        guard maxV != minV else { return SIMD3(0, 0, l) }

        let d = maxV - minV
        let s = l > 0.5 ? d / (2 - maxV - minV) : d / (maxV + minV)
        var h: Double
        if maxV == c.x {
            h = (c.y - c.z) / d + (c.y < c.z ? 6 : 0)
        } else if maxV == c.y {
            h = (c.z - c.x) / d + 2
        } else {
            h = (c.x - c.y) / d + 4
        }
        h /= 6
        return SIMD3(h, s, l)
    }

    private static func hsl2rgb(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let (h, s, l) = (c.x, c.y, c.z)
        guard s != 0 else { return SIMD3(l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return SIMD3(hue2rgb(p, q, h + 1.0 / 3),
                     hue2rgb(p, q, h),
                     hue2rgb(p, q, h - 1.0 / 3))
    }

    private static func hue2rgb(_ p: Double, _ q: Double, _ tIn: Double) -> Double {
        var t = tIn
        if t < 0 { t += 1 }
        if t > 1 { t -= 1 }
        if t < 1.0 / 6 { return p + (q - p) * 6 * t }
        if t < 1.0 / 2 { return q }
        if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
        return p
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}

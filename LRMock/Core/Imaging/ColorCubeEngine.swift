//
//  ColorCubeEngine.swift
//  RawLight
//
//  Builds a 3-D colour lookup table (LUT) for Core Image's `CIColorCube`, which
//  applies arbitrary colour transforms on the GPU in a single pass. This is the
//  native, high-performance way to do complex colour work on iOS.
//
//  Hue-dependent global colour operations share this cached LUT builder: HSL
//  mixer, Point Color, B&W mixer, grading, calibration, profile and defringe.
//
//  The cube is rebuilt on the CPU only when the settings change (a few thousand
//  cheap HSL conversions) and cached; Core Image then samples it for free.
//

import Foundation
import CoreImage

nonisolated enum ColorCubeEngine {

    /// Hue centres (degrees) for the 8 mixer bands:
    /// Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta.
    static let bandCenters: [Double] = [0, 30, 60, 120, 180, 225, 270, 315]

    struct Cube { let dimension: Int; let data: Data }
    static let maximumCubeDimension = 128

    // Simple single-entry cache (the inspector edits one image at a time).
    private static var cache: (mix: ColorMix, dimension: Int, cube: Cube)?
    private static let lock = NSLock()

    /// Returns a cached/freshly-built HSL cube for `mix`, or nil if identity.
    static func hslCube(for mix: ColorMix, dimension: Int = 16) -> Cube? {
        guard !mix.isIdentity else { return nil }
        let dimension = cubeDimension(dimension)

        lock.lock()
        if let cached = cache, cached.mix == mix, cached.dimension == dimension {
            lock.unlock()
            return cached.cube
        }
        lock.unlock()

        let cube = build(mix: mix, dimension: dimension)
        lock.lock(); cache = (mix, dimension, cube); lock.unlock()
        return cube
    }

    // MARK: Point Color

    struct PointColorReference: Equatable, Sendable {
        let luminance: Double
        let chroma: Double
        let hue: Double
    }

    private static var pointColorCache:
        (adjustments: [PointColorAdjustment], dimension: Int, cube: Cube)?

    /// Builds a selective OkLab/OkLCh cube over extended-linear Display P3.
    /// Selectors use the immutable source colour while edits accumulate in list
    /// order, so one adjustment cannot move a pixel out of a later selection.
    static func pointColorCube(
        for adjustments: [PointColorAdjustment],
        dimension n: Int = 48
    ) -> Cube? {
        let adjustments = Array(adjustments.prefix(PointColorAdjustment.maximumCount))
        guard adjustments.contains(where: { !$0.isIdentity }) else { return nil }
        let n = cubeDimension(n)

        lock.lock()
        if let cached = pointColorCache,
           cached.adjustments == adjustments,
           cached.dimension == n {
            lock.unlock()
            return cached.cube
        }
        lock.unlock()

        let cube = makeCube(dimension: n) {
            pointColorValue($0, adjustments: adjustments)
        }
        lock.lock()
        pointColorCache = (adjustments, n, cube)
        lock.unlock()
        return cube
    }

    static func pointColorReference(
        red: Double,
        green: Double,
        blue: Double
    ) -> PointColorReference {
        let lab = linearDisplayP3ToOkLab(clamped(SIMD3(red, green, blue)))
        let chroma = hypot(lab.y, lab.z)
        let hue = chroma > 0.000_001
            ? wrappedHue(atan2(lab.z, lab.y) / (2 * .pi))
            : 0
        return PointColorReference(
            luminance: clamp01(lab.x),
            chroma: min(0.5, max(0, chroma)),
            hue: hue
        )
    }

    /// Converts a stored OkLCh reference back to extended-linear Display P3 for
    /// UI swatches. The cube and sampler use this same colour domain.
    static func pointColorLinearDisplayP3(
        luminance: Double,
        chroma: Double,
        hue: Double
    ) -> SIMD3<Double> {
        let angle = wrappedHue(hue) * 2 * .pi
        let lab = SIMD3(
            clamp01(luminance),
            min(0.5, max(0, chroma)) * cos(angle),
            min(0.5, max(0, chroma)) * sin(angle)
        )
        return clamped(okLabToLinearDisplayP3(lab))
    }

    static func pointColorValue(
        _ rgb: SIMD3<Double>,
        adjustments: [PointColorAdjustment]
    ) -> SIMD3<Double> {
        let adjustments = adjustments.prefix(PointColorAdjustment.maximumCount)
        guard adjustments.contains(where: { !$0.isIdentity }) else { return rgb }

        var lab = linearDisplayP3ToOkLab(clamped(rgb))
        let sourceLuminance = clamp01(lab.x)
        let sourceChroma = min(0.5, max(0, hypot(lab.y, lab.z)))
        let sourceHue = sourceChroma > 0.000_001
            ? wrappedHue(atan2(lab.z, lab.y) / (2 * .pi))
            : 0
        var luminance = sourceLuminance
        var chroma = sourceChroma
        var hue = sourceHue

        var changed = false
        for adjustment in adjustments where !adjustment.isIdentity {
            let sampleLuminance = clamp01(adjustment.luminance)
            let sampleChroma = min(0.5, max(0, adjustment.chroma))
            let sampleHue = wrappedHue(adjustment.hue)
            let range = clamp01(adjustment.range)
            let rangeScale = 0.35 + range * 1.3
            // The non-zero minima keep the narrowest useful selection sampled
            // by the finite 48³ lattice instead of producing an accidental
            // identity cube for colours that fall between lattice vertices.
            let hueRadius = min(0.5,
                (0.03 + clamp01(adjustment.hueRange) * 0.22) * rangeScale)
            let chromaRadius = min(0.5,
                (0.03 + clamp01(adjustment.chromaRange) * 0.22) * rangeScale)
            let luminanceRadius = min(1,
                (0.035 + clamp01(adjustment.luminanceRange) * 0.465) * rangeScale)

            let hueWeight = selectionWeight(
                distance: circularHueDistance(sourceHue, sampleHue), radius: hueRadius)
            let chromaWeight = selectionWeight(
                distance: abs(sourceChroma - sampleChroma), radius: chromaRadius)
            let luminanceWeight = selectionWeight(
                distance: abs(sourceLuminance - sampleLuminance), radius: luminanceRadius)
            let weight = hueWeight * chromaWeight * luminanceWeight
            guard weight > 0 else { continue }
            changed = true

            let variance = normalizedSigned(adjustment.variance)
            let spread = max(0.25, 1 + variance * 0.75 * weight)
            luminance = sampleLuminance + (luminance - sampleLuminance) * spread
            chroma = sampleChroma + (chroma - sampleChroma) * spread
            let hueDelta = signedCircularHueDistance(hue, sampleHue)
            hue = sampleHue + hueDelta * spread

            hue += normalizedSigned(adjustment.hueShift) * 0.5 * weight
            chroma *= max(0, 1 + normalizedSigned(adjustment.saturationShift) * weight)
            luminance += normalizedSigned(adjustment.luminanceShift) * 0.22 * weight

            luminance = clamp01(luminance)
            chroma = min(0.5, max(0, chroma))
            hue = wrappedHue(hue)
        }

        guard changed else { return rgb }
        let angle = hue * 2 * .pi
        lab = SIMD3(luminance, chroma * cos(angle), chroma * sin(angle))
        return clamped(okLabToLinearDisplayP3(lab))
    }

    private static func selectionWeight(distance: Double, radius: Double) -> Double {
        guard radius > 0, distance < radius else { return 0 }
        return 1 - smoothstep(radius * 0.25, radius, distance)
    }

    private static func circularHueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        abs(signedCircularHueDistance(lhs, rhs))
    }

    private static func signedCircularHueDistance(_ lhs: Double, _ rhs: Double) -> Double {
        var difference = wrappedHue(lhs) - wrappedHue(rhs)
        if difference > 0.5 { difference -= 1 }
        if difference < -0.5 { difference += 1 }
        return difference
    }

    private static func linearDisplayP3ToOkLab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let l = cubeRoot(0.481_379_852_749_954 * rgb.x
            + 0.462_118_371_011_318 * rgb.y + 0.056_501_776_238_728 * rgb.z)
        let m = cubeRoot(0.228_831_941_811_245 * rgb.x
            + 0.653_216_819_383_568 * rgb.y + 0.117_951_238_805_188 * rgb.z)
        let s = cubeRoot(0.083_945_752_322_993 * rgb.x
            + 0.224_165_270_977_567 * rgb.y + 0.691_888_976_699_440 * rgb.z)
        return SIMD3(
            0.210_454_255_3 * l + 0.793_617_785 * m - 0.004_072_046_8 * s,
            1.977_998_495_1 * l - 2.428_592_205 * m + 0.450_593_709_9 * s,
            0.025_904_037_1 * l + 0.782_771_766_2 * m - 0.808_675_766 * s
        )
    }

    private static func okLabToLinearDisplayP3(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let lBase = lab.x + 0.396_337_777_4 * lab.y + 0.215_803_757_3 * lab.z
        let mBase = lab.x - 0.105_561_345_8 * lab.y - 0.063_854_172_8 * lab.z
        let sBase = lab.x - 0.089_484_177_5 * lab.y - 1.291_485_548 * lab.z
        let l = lBase * lBase * lBase
        let m = mBase * mBase * mBase
        let s = sBase * sBase * sBase
        return SIMD3(
            3.127_768_971_361_874 * l - 2.257_135_762_591_638 * m
                + 0.129_366_791_229_765 * s,
            -1.091_009_018_437_797 * l + 2.413_331_710_306_921 * m
                - 0.322_322_691_869_125 * s,
            -0.026_010_801_938_570 * l - 0.508_041_331_704_167 * m
                + 1.534_052_133_642_737 * s
        )
    }

    private static func cubeRoot(_ value: Double) -> Double {
        value < 0 ? -pow(-value, 1.0 / 3.0) : pow(value, 1.0 / 3.0)
    }

    // MARK: Color grading (3-way split toning)

    private static var gradeCache: (grade: ColorGrade, dimension: Int, cube: Cube)?

    /// Builds a cube that tints shadows / midtones / highlights by luminance.
    static func gradingCube(for grade: ColorGrade, dimension n: Int = 16) -> Cube? {
        guard !grade.isIdentity else { return nil }
        let n = cubeDimension(n)
        lock.lock()
        if let cached = gradeCache, cached.grade == grade, cached.dimension == n {
            lock.unlock()
            return cached.cube
        }
        lock.unlock()

        let cube = makeCube(dimension: n) { gradingValue($0, grade: grade) }
        lock.lock(); gradeCache = (grade, n, cube); lock.unlock()
        return cube
    }

    static func gradingValue(_ rgb: SIMD3<Double>, grade: ColorGrade) -> SIMD3<Double> {
        let luminance = luma(rgb)
        let midpoint = 0.5 - normalizedSigned(grade.balance) * 0.25
        let width = 0.15 + clamp01(grade.blending) * 0.5
        let shadowWeight = 1 - smoothstep(midpoint - width, midpoint + width * 0.25, luminance)
        let highlightWeight = smoothstep(midpoint - width * 0.25, midpoint + width, luminance)
        let midWeight = max(0, 1 - shadowWeight - highlightWeight)

        let wheels = [
            (grade.shadowHue, grade.shadowSat, grade.shadowLum, shadowWeight),
            (grade.midHue, grade.midSat, grade.midLum, midWeight),
            (grade.highHue, grade.highSat, grade.highLum, highlightWeight),
            (grade.globalHue, grade.globalSat, grade.globalLum, 1.0),
        ]
        var out = rgb
        for (hue, saturation, luminosity, weight) in wheels where weight > 0 {
            out += tintOffset(hue: hue, sat: saturation) * weight
            out += SIMD3(repeating: normalizedSigned(luminosity) * 0.12 * weight)
        }
        return clamped(out)
    }

    private static func tintOffset(hue: Double, sat: Double) -> SIMD3<Double> {
        let saturation = clamp01(sat)
        guard saturation > 0 else { return SIMD3(repeating: 0) }
        let c = hsl2rgb(SIMD3(wrappedHue(hue), 1, 0.5))
        let neutral = luma(c)
        return (c - SIMD3(repeating: neutral)) * (saturation * 0.16)
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x < a ? 0 : 1 }
        let t = clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    // MARK: Black & white mixer

    private static var bwCache: (mix: [Double], dimension: Int, cube: Cube)?

    static func blackAndWhiteCube(mix values: [Double], dimension n: Int = 16) -> Cube {
        let mix = normalizedBands(values)
        let n = cubeDimension(n)
        lock.lock()
        if let cached = bwCache, cached.mix == mix, cached.dimension == n {
            lock.unlock()
            return cached.cube
        }
        lock.unlock()

        let cube = makeCube(dimension: n) { blackAndWhiteValue($0, mix: mix) }
        lock.lock(); bwCache = (mix, n, cube); lock.unlock()
        return cube
    }

    static func blackAndWhiteValue(_ rgb: SIMD3<Double>, mix values: [Double]) -> SIMD3<Double> {
        let mix = normalizedBands(values)
        let hsl = rgb2hsl(clamped(rgb))
        let base = luma(rgb)
        guard hsl.y > 0.0001 else { return SIMD3(repeating: clamp01(base)) }

        var weights = [Double](repeating: 0, count: ColorMix.bandCount)
        bandWeights(hueDegrees: hsl.x * 360, into: &weights)
        var adjustment = 0.0
        for index in 0..<ColorMix.bandCount {
            adjustment += weights[index] * mix[index]
        }
        let chroma = max(rgb.x, max(rgb.y, rgb.z)) - min(rgb.x, min(rgb.y, rgb.z))
        let value = clamp01(base + adjustment * chroma * 0.3)
        return SIMD3(repeating: value)
    }

    // MARK: Calibration

    private struct CalibrationKey: Equatable {
        let values: [Double]
        let dimension: Int
    }

    private static var calibrationCache: (key: CalibrationKey, cube: Cube)?

    static func calibrationCube(
        shadowsTint: Double,
        redHue: Double, redSat: Double,
        greenHue: Double, greenSat: Double,
        blueHue: Double, blueSat: Double,
        dimension n: Int = 16
    ) -> Cube? {
        let values = [shadowsTint, redHue, redSat, greenHue, greenSat, blueHue, blueSat]
            .map(normalizedSigned)
        guard values.contains(where: { $0 != 0 }) else { return nil }
        let key = CalibrationKey(values: values, dimension: cubeDimension(n))
        lock.lock()
        if let cached = calibrationCache, cached.key == key {
            lock.unlock()
            return cached.cube
        }
        lock.unlock()

        let matrix = calibrationMatrix(
            redHue: values[1], redSat: values[2],
            greenHue: values[3], greenSat: values[4],
            blueHue: values[5], blueSat: values[6]
        )
        let cube = makeCube(dimension: key.dimension) {
            calibrationValue($0, shadowsTint: values[0], matrix: matrix)
        }
        lock.lock(); calibrationCache = (key, cube); lock.unlock()
        return cube
    }

    static func calibrationValue(
        _ rgb: SIMD3<Double>,
        shadowsTint: Double,
        redHue: Double = 0, redSat: Double = 0,
        greenHue: Double = 0, greenSat: Double = 0,
        blueHue: Double = 0, blueSat: Double = 0
    ) -> SIMD3<Double> {
        calibrationValue(
            rgb,
            shadowsTint: normalizedSigned(shadowsTint),
            matrix: calibrationMatrix(
                redHue: normalizedSigned(redHue), redSat: normalizedSigned(redSat),
                greenHue: normalizedSigned(greenHue), greenSat: normalizedSigned(greenSat),
                blueHue: normalizedSigned(blueHue), blueSat: normalizedSigned(blueSat)
            )
        )
    }

    private static func calibrationValue(
        _ rgb: SIMD3<Double>,
        shadowsTint: Double,
        matrix: [SIMD3<Double>]
    ) -> SIMD3<Double> {
        var out = SIMD3(
            matrix[0].x * rgb.x + matrix[0].y * rgb.y + matrix[0].z * rgb.z,
            matrix[1].x * rgb.x + matrix[1].y * rgb.y + matrix[1].z * rgb.z,
            matrix[2].x * rgb.x + matrix[2].y * rgb.y + matrix[2].z * rgb.z
        )
        if shadowsTint != 0 {
            let before = max(0, luma(out))
            let weight = 1 - smoothstep(0.04, 0.55, before)
            out.y *= max(0, 1 - shadowsTint * 0.28 * weight)
            let after = luma(out)
            if after > 0.000_001 { out *= before / after }
        }
        return clamped(out)
    }

    private static func calibrationMatrix(
        redHue: Double, redSat: Double,
        greenHue: Double, greenSat: Double,
        blueHue: Double, blueSat: Double
    ) -> [SIMD3<Double>] {
        let controls = [(0.0, redHue, redSat), (1.0 / 3, greenHue, greenSat), (2.0 / 3, blueHue, blueSat)]
        var columns = [SIMD3<Double>]()
        columns.reserveCapacity(3)
        for (baseHue, hue, saturation) in controls {
            let shifted = hsl2rgb(SIMD3(wrappedHue(baseHue + hue * 30.0 / 360.0), 1, 0.5))
            let y = luma(shifted)
            columns.append(
                SIMD3(repeating: y) + (shifted - SIMD3(repeating: y)) * (1 + saturation * 0.6)
            )
        }

        var rows = [
            SIMD3(columns[0].x, columns[1].x, columns[2].x),
            SIMD3(columns[0].y, columns[1].y, columns[2].y),
            SIMD3(columns[0].z, columns[1].z, columns[2].z),
        ]
        // Row normalization keeps neutral RGB exactly neutral.
        for index in rows.indices {
            let sum = rows[index].x + rows[index].y + rows[index].z
            if abs(sum) > 0.000_001 { rows[index] /= sum }
        }
        return rows
    }

    // MARK: Built-in profile

    private static var profileCache: (amount: Double, dimension: Int, cube: Cube)?

    static func profileCube(amount: Double, dimension n: Int = 16) -> Cube? {
        let amount = min(2, max(0, amount.isFinite ? amount : 1))
        guard abs(amount - 1) > 0.000_001 else { return nil }
        let n = cubeDimension(n)
        lock.lock()
        if let cached = profileCache, cached.amount == amount, cached.dimension == n {
            lock.unlock()
            return cached.cube
        }
        lock.unlock()

        let cube = makeCube(dimension: n) { profileValue($0, amount: amount) }
        lock.lock(); profileCache = (amount, n, cube); lock.unlock()
        return cube
    }

    static func profileValue(_ rgb: SIMD3<Double>, amount: Double) -> SIMD3<Double> {
        let k = min(2, max(0, amount.isFinite ? amount : 1)) - 1
        guard abs(k) > 0.000_001 else { return rgb }
        var hsl = rgb2hsl(clamped(rgb))
        let shoulder = 4 * hsl.z * (1 - hsl.z)
        hsl.z = clamp01(hsl.z + k * 0.04 * (2 * hsl.z - 1) * shoulder)
        hsl.y = clamp01(hsl.y * (1 + k * 0.08))
        var out = hsl2rgb(hsl)
        let warmth = k * 0.006 * shoulder
        out.x += warmth
        out.z -= warmth * 0.6
        return clamped(out)
    }

    // MARK: Defringe

    private struct DefringeKey: Equatable {
        let values: [Double]
        let dimension: Int
    }

    private static var defringeCache: (key: DefringeKey, cube: Cube)?

    static func defringeCube(
        purpleAmount: Double, purpleHueLo: Double, purpleHueHi: Double,
        greenAmount: Double, greenHueLo: Double, greenHueHi: Double,
        dimension n: Int = 16
    ) -> Cube? {
        let values = [
            clamp01(purpleAmount), clamp01(purpleHueLo), clamp01(purpleHueHi),
            clamp01(greenAmount), clamp01(greenHueLo), clamp01(greenHueHi),
        ]
        guard values[0] > 0 || values[3] > 0 else { return nil }
        let key = DefringeKey(values: values, dimension: cubeDimension(n))
        lock.lock()
        if let cached = defringeCache, cached.key == key {
            lock.unlock()
            return cached.cube
        }
        lock.unlock()

        let cube = makeCube(dimension: key.dimension) {
            defringeValue(
                $0,
                purpleAmount: values[0], purpleHueLo: values[1], purpleHueHi: values[2],
                greenAmount: values[3], greenHueLo: values[4], greenHueHi: values[5]
            )
        }
        lock.lock(); defringeCache = (key, cube); lock.unlock()
        return cube
    }

    static func defringeValue(
        _ rgb: SIMD3<Double>,
        purpleAmount: Double, purpleHueLo: Double, purpleHueHi: Double,
        greenAmount: Double, greenHueLo: Double, greenHueHi: Double
    ) -> SIMD3<Double> {
        var hsl = rgb2hsl(clamped(rgb))
        guard hsl.y > 0.0001 else { return rgb }
        let hue = hsl.x * 360
        let purple = hueRange(
            hue, lower: 240 + 120 * clamp01(purpleHueLo),
            upper: 240 + 120 * clamp01(purpleHueHi)
        ) * clamp01(purpleAmount)
        let green = hueRange(
            hue, lower: 90 + 120 * clamp01(greenHueLo),
            upper: 90 + 120 * clamp01(greenHueHi)
        ) * clamp01(greenAmount)
        hsl.y *= 1 - min(1, max(purple, green)) * 0.9
        return clamped(hsl2rgb(hsl))
    }

    private static func hueRange(_ hue: Double, lower: Double, upper: Double) -> Double {
        let lo = min(lower, upper)
        let hi = max(lower, upper)
        let midpoint = (lo + hi) * 0.5
        let halfWidth = max(0.5, (hi - lo) * 0.5)
        var distance = abs(hue - midpoint).truncatingRemainder(dividingBy: 360)
        if distance > 180 { distance = 360 - distance }
        return 1 - smoothstep(halfWidth, halfWidth + 10, distance)
    }

    // MARK: Build

    private static let hueBuckets = 256

    private static func makeCube(
        dimension n: Int,
        transform: (SIMD3<Double>) -> SIMD3<Double>
    ) -> Cube {
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        let denominator = Double(n - 1)
        floats.withUnsafeMutableBufferPointer { buffer in
            var offset = 0
            for blue in 0..<n {
                for green in 0..<n {
                    for red in 0..<n {
                        let value = clamped(transform(SIMD3(
                            Double(red) / denominator,
                            Double(green) / denominator,
                            Double(blue) / denominator
                        )))
                        buffer[offset] = Float(value.x)
                        buffer[offset + 1] = Float(value.y)
                        buffer[offset + 2] = Float(value.z)
                        buffer[offset + 3] = 1
                        offset += 4
                    }
                }
            }
        }
        return Cube(dimension: n, data: floats.withUnsafeBytes { Data($0) })
    }

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

    private static func normalizedBands(_ values: [Double]) -> [Double] {
        var result = values.prefix(ColorMix.bandCount).map(normalizedSigned)
        if result.count < ColorMix.bandCount {
            result.append(contentsOf: repeatElement(0, count: ColorMix.bandCount - result.count))
        }
        return result
    }

    private static func normalizedSigned(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }

    private static func cubeDimension(_ value: Int) -> Int {
        min(maximumCubeDimension, max(2, value))
    }

    private static func wrappedHue(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let wrapped = value.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

    private static func luma(_ value: SIMD3<Double>) -> Double {
        0.2126 * value.x + 0.7152 * value.y + 0.0722 * value.z
    }

    private static func clamped(_ value: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(clamp01(value.x), clamp01(value.y), clamp01(value.z))
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

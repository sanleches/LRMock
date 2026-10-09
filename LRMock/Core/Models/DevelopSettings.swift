//
//  DevelopSettings.swift
//  RawLight
//
//  The non-destructive "recipe" applied to an image at render/export time.
//
//  Backward-compatible persistence: a lenient `init(from:)` `decodeIfPresent ??
//  default`s every field, so adding fields never breaks old sidecars or
//  previously-persisted assets.
//

import Foundation
import CoreGraphics

/// A single control point on a curve, in normalised 0...1 space.
nonisolated struct CurvePoint: Codable, Equatable, Sendable, Identifiable {
    var x: Double
    var y: Double
    var id: Double { x }
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// 8-band HSL / "Color Mixer".
nonisolated struct ColorMix: Codable, Equatable, Sendable {
    var hue: [Double]
    var saturation: [Double]
    var luminance: [Double]
    static let bandCount = 8
    init() {
        hue = Array(repeating: 0, count: Self.bandCount)
        saturation = Array(repeating: 0, count: Self.bandCount)
        luminance = Array(repeating: 0, count: Self.bandCount)
    }

    enum CodingKeys: String, CodingKey { case hue, saturation, luminance }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hue = Self.normalized(try container.decodeIfPresent([Double].self, forKey: .hue) ?? [])
        saturation = Self.normalized(try container.decodeIfPresent([Double].self, forKey: .saturation) ?? [])
        luminance = Self.normalized(try container.decodeIfPresent([Double].self, forKey: .luminance) ?? [])
    }

    private static func normalized(_ values: [Double]) -> [Double] {
        var result = values.prefix(bandCount).map { value in
            value.isFinite ? min(max(value, -1), 1) : 0
        }
        if result.count < bandCount {
            result.append(contentsOf: repeatElement(0, count: bandCount - result.count))
        }
        return result
    }
    var isIdentity: Bool {
        hue.allSatisfy { $0 == 0 } && saturation.allSatisfy { $0 == 0 } && luminance.allSatisfy { $0 == 0 }
    }
}

/// 3-way colour grading (split toning). Hue 0...1, saturation 0...1 per range.
nonisolated struct ColorGrade: Codable, Equatable, Sendable {
    var shadowHue = 0.0, shadowSat = 0.0
    var midHue = 0.0, midSat = 0.0
    var highHue = 0.0, highSat = 0.0
    var isIdentity: Bool { shadowSat == 0 && midSat == 0 && highSat == 0 }
}

nonisolated struct DevelopSettings: Codable, Equatable, Sendable {

    var schemaVersion: Int = DevelopSettings.currentSchemaVersion
    static let currentSchemaVersion = 4

    // White balance
    var temperature = 0.0
    var tint = 0.0

    // Tone
    var exposure = 0.0
    var contrast = 0.0
    var highlights = 0.0
    var shadows = 0.0
    var whites = 0.0
    var blacks = 0.0

    // Presence
    var texture = 0.0
    var clarity = 0.0
    var dehaze = 0.0
    var vibrance = 0.0
    var saturation = 0.0

    // Curves: master (luminance) + per-channel
    var toneCurve: [CurvePoint] = DevelopSettings.linearCurve
    var toneCurveRed: [CurvePoint] = DevelopSettings.linearCurve
    var toneCurveGreen: [CurvePoint] = DevelopSettings.linearCurve
    var toneCurveBlue: [CurvePoint] = DevelopSettings.linearCurve

    // Color mixer (8-band HSL)
    var colorMix = ColorMix()

    // Color grading (3-way)
    var grade = ColorGrade()

    // Black & white
    var blackWhite = false
    var bwRed = 0.0
    var bwGreen = 0.0
    var bwBlue = 0.0

    // Detail
    var sharpness = 0.0          // 0...1
    var sharpenRadius = 0.0      // 0...1
    var noiseReduction = 0.0     // 0...1  (luminance)
    var colorNoiseReduction = 0.0 // 0...1
    var grain = 0.0              // 0...1

    // Effects
    var vignette = 0.0

    // Geometry
    var cropX = 0.0, cropY = 0.0, cropW = 1.0, cropH = 1.0
    var straighten = 0.0         // degrees -45...45
    var flipH = false
    var flipV = false
    var rotationQuarterTurns = 0

    init() {}

    static let linearCurve: [CurvePoint] = [
        CurvePoint(0, 0), CurvePoint(0.25, 0.25), CurvePoint(0.5, 0.5),
        CurvePoint(0.75, 0.75), CurvePoint(1, 1)
    ]

    // MARK: Lenient decoding

    enum CodingKeys: String, CodingKey {
        case schemaVersion, temperature, tint, exposure, contrast, highlights,
             shadows, whites, blacks, texture, clarity, dehaze, vibrance, saturation,
             toneCurve, toneCurveRed, toneCurveGreen, toneCurveBlue,
             colorMix, grade, blackWhite, bwRed, bwGreen, bwBlue,
             sharpness, sharpenRadius, noiseReduction, colorNoiseReduction, grain,
             vignette, cropX, cropY, cropW, cropH, straighten, flipH, flipV,
             rotationQuarterTurns
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func dbl(_ k: CodingKeys, _ f: Double) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil ?? f }
        func bool(_ k: CodingKeys, _ f: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil ?? f }
        func curve(_ k: CodingKeys) -> [CurvePoint] { (try? c.decodeIfPresent([CurvePoint].self, forKey: k)) ?? nil ?? Self.linearCurve }

        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? nil ?? Self.currentSchemaVersion
        temperature = dbl(.temperature, 0); tint = dbl(.tint, 0)
        exposure = dbl(.exposure, 0); contrast = dbl(.contrast, 0)
        highlights = dbl(.highlights, 0); shadows = dbl(.shadows, 0)
        whites = dbl(.whites, 0); blacks = dbl(.blacks, 0)
        texture = dbl(.texture, 0); clarity = dbl(.clarity, 0); dehaze = dbl(.dehaze, 0)
        vibrance = dbl(.vibrance, 0); saturation = dbl(.saturation, 0)
        toneCurve = curve(.toneCurve)
        toneCurveRed = curve(.toneCurveRed); toneCurveGreen = curve(.toneCurveGreen); toneCurveBlue = curve(.toneCurveBlue)
        colorMix = (try? c.decodeIfPresent(ColorMix.self, forKey: .colorMix)) ?? nil ?? ColorMix()
        grade = (try? c.decodeIfPresent(ColorGrade.self, forKey: .grade)) ?? nil ?? ColorGrade()
        blackWhite = bool(.blackWhite, false)
        bwRed = dbl(.bwRed, 0); bwGreen = dbl(.bwGreen, 0); bwBlue = dbl(.bwBlue, 0)
        sharpness = dbl(.sharpness, 0); sharpenRadius = dbl(.sharpenRadius, 0)
        noiseReduction = dbl(.noiseReduction, 0); colorNoiseReduction = dbl(.colorNoiseReduction, 0)
        grain = dbl(.grain, 0)
        vignette = dbl(.vignette, 0)
        cropX = dbl(.cropX, 0); cropY = dbl(.cropY, 0); cropW = dbl(.cropW, 1); cropH = dbl(.cropH, 1)
        straighten = dbl(.straighten, 0)
        flipH = bool(.flipH, false); flipV = bool(.flipV, false)
        rotationQuarterTurns = (try? c.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns)) ?? nil ?? 0
        normalizeDecodedValues()
    }

    private mutating func normalizeDecodedValues() {
        schemaVersion = Self.currentSchemaVersion

        temperature = Self.clampedFinite(temperature, -1...1)
        tint = Self.clampedFinite(tint, -1...1)
        exposure = Self.clampedFinite(exposure, -1...1)
        contrast = Self.clampedFinite(contrast, -1...1)
        highlights = Self.clampedFinite(highlights, -1...1)
        shadows = Self.clampedFinite(shadows, -1...1)
        whites = Self.clampedFinite(whites, -1...1)
        blacks = Self.clampedFinite(blacks, -1...1)
        texture = Self.clampedFinite(texture, -1...1)
        clarity = Self.clampedFinite(clarity, -1...1)
        dehaze = Self.clampedFinite(dehaze, -1...1)
        vibrance = Self.clampedFinite(vibrance, -1...1)
        saturation = Self.clampedFinite(saturation, -1...1)
        bwRed = Self.clampedFinite(bwRed, -1...1)
        bwGreen = Self.clampedFinite(bwGreen, -1...1)
        bwBlue = Self.clampedFinite(bwBlue, -1...1)

        sharpness = Self.clampedFinite(sharpness, 0...1)
        sharpenRadius = Self.clampedFinite(sharpenRadius, 0...1)
        noiseReduction = Self.clampedFinite(noiseReduction, 0...1)
        colorNoiseReduction = Self.clampedFinite(colorNoiseReduction, 0...1)
        grain = Self.clampedFinite(grain, 0...1)
        vignette = Self.clampedFinite(vignette, -1...1)

        grade.shadowHue = Self.clampedFinite(grade.shadowHue, 0...1)
        grade.midHue = Self.clampedFinite(grade.midHue, 0...1)
        grade.highHue = Self.clampedFinite(grade.highHue, 0...1)
        grade.shadowSat = Self.clampedFinite(grade.shadowSat, 0...1)
        grade.midSat = Self.clampedFinite(grade.midSat, 0...1)
        grade.highSat = Self.clampedFinite(grade.highSat, 0...1)

        toneCurve = Self.normalizedCurve(toneCurve)
        toneCurveRed = Self.normalizedCurve(toneCurveRed)
        toneCurveGreen = Self.normalizedCurve(toneCurveGreen)
        toneCurveBlue = Self.normalizedCurve(toneCurveBlue)

        cropW = Self.clampedFinite(cropW, 0.01...1)
        cropH = Self.clampedFinite(cropH, 0.01...1)
        cropX = Self.clampedFinite(cropX, 0...(1 - cropW))
        cropY = Self.clampedFinite(cropY, 0...(1 - cropH))
        straighten = Self.clampedFinite(straighten, -45...45)
        rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
    }

    private static func clampedFinite(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return min(max(0, range.lowerBound), range.upperBound) }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private static func normalizedCurve(_ points: [CurvePoint]) -> [CurvePoint] {
        let sorted = points
            .filter { $0.x.isFinite && $0.y.isFinite }
            .map { CurvePoint(clampedFinite($0.x, 0...1), clampedFinite($0.y, 0...1)) }
            .sorted { $0.x < $1.x }

        var unique: [CurvePoint] = []
        for point in sorted {
            if let last = unique.last, abs(last.x - point.x) < 0.000_001 {
                unique[unique.count - 1] = point
            } else {
                unique.append(point)
            }
        }
        guard unique.count >= 2 else { return linearCurve }
        if unique[0].x > 0 { unique.insert(CurvePoint(0, unique[0].y), at: 0) }
        if unique[unique.count - 1].x < 1 {
            unique.append(CurvePoint(1, unique[unique.count - 1].y))
        }
        return unique
    }
}

nonisolated extension DevelopSettings {

    var isIdentity: Bool {
        var baseline = DevelopSettings()
        baseline.schemaVersion = schemaVersion
        return self == baseline
    }

    func isCurveLinear(_ curve: [CurvePoint]) -> Bool {
        curve.allSatisfy { abs($0.y - $0.x) < 0.001 }
    }

    var isCurveLinear: Bool { isCurveLinear(toneCurve) }

    /// `true` when the crop is the full frame (no geometry crop).
    var isFullFrame: Bool {
        abs(cropX) < 1e-6 && abs(cropY) < 1e-6 && abs(cropW - 1) < 1e-6 && abs(cropH - 1) < 1e-6
    }

    var hasGeometry: Bool {
        !isFullFrame || straighten != 0 || flipH || flipV || rotationQuarterTurns % 4 != 0
    }

    /// The "before" look: tone/colour/detail reset, geometry preserved so the
    /// before/after comparison keeps the same framing.
    var beforeSettings: DevelopSettings {
        var b = DevelopSettings()
        b.cropX = cropX; b.cropY = cropY; b.cropW = cropW; b.cropH = cropH
        b.straighten = straighten; b.flipH = flipH; b.flipV = flipV
        b.rotationQuarterTurns = rotationQuarterTurns
        return b
    }

    mutating func reset() {
        self = DevelopSettings()
    }
}

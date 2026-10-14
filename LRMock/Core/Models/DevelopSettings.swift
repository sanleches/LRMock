//
//  DevelopSettings.swift
//  RawLight
//
//  The non-destructive "recipe" applied to an image at render/export time.
//
//  Backward-compatible persistence: missing fields receive neutral defaults,
//  while malformed selective records are discarded without dropping siblings.
//

import Foundation
import CoreGraphics
import CryptoKit

/// A single control point on a curve, in normalised 0...1 space.
nonisolated struct CurvePoint: Codable, Equatable, Sendable, Identifiable {
    var x: Double
    var y: Double
    var id: Double { x }
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// 8-band HSL / "Color Mixer".
nonisolated struct ColorMix: Codable, Equatable, Sendable {
    var hue: [Double] {
        didSet { hue = Self.normalized(hue) }
    }
    var saturation: [Double] {
        didSet { saturation = Self.normalized(saturation) }
    }
    var luminance: [Double] {
        didSet { luminance = Self.normalized(luminance) }
    }
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
    func normalized() -> ColorMix {
        var result = self
        result.hue = Self.normalized(hue)
        result.saturation = Self.normalized(saturation)
        result.luminance = Self.normalized(luminance)
        return result
    }
    var isIdentity: Bool {
        hue.allSatisfy { $0 == 0 } && saturation.allSatisfy { $0 == 0 } && luminance.allSatisfy { $0 == 0 }
    }
}

/// Colour grading wheels. Hue/saturation are 0...1; luminance and balance are -1...1.
nonisolated struct ColorGrade: Codable, Equatable, Sendable {
    var shadowHue = 0.0, shadowSat = 0.0
    var midHue = 0.0, midSat = 0.0
    var highHue = 0.0, highSat = 0.0
    var shadowLum = 0.0, midLum = 0.0, highLum = 0.0
    var globalHue = 0.0, globalSat = 0.0, globalLum = 0.0
    var blending = 0.5
    var balance = 0.0

    init() {}

    enum CodingKeys: String, CodingKey {
        case shadowHue, shadowSat, midHue, midSat, highHue, highSat
        case shadowLum, midLum, highLum, globalHue, globalSat, globalLum
        case blending, balance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func dbl(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil ?? fallback
        }

        shadowHue = dbl(.shadowHue, 0); shadowSat = dbl(.shadowSat, 0)
        midHue = dbl(.midHue, 0); midSat = dbl(.midSat, 0)
        highHue = dbl(.highHue, 0); highSat = dbl(.highSat, 0)
        shadowLum = dbl(.shadowLum, 0); midLum = dbl(.midLum, 0); highLum = dbl(.highLum, 0)
        globalHue = dbl(.globalHue, 0); globalSat = dbl(.globalSat, 0); globalLum = dbl(.globalLum, 0)
        blending = dbl(.blending, 0.5)
        balance = dbl(.balance, 0)
    }

    var isIdentity: Bool {
        shadowSat == 0 && midSat == 0 && highSat == 0 && globalSat == 0
            && shadowLum == 0 && midLum == 0 && highLum == 0 && globalLum == 0
    }
}

nonisolated struct DevelopSettings: Codable, Equatable, Sendable {

    struct SelectivePathBounds: Equatable, Sendable {
        let masks: [LocalMask]
        let spots: [SpotCorrection]
        let copiedPointCount: Int
        let visitedBrushStrokeCount: Int
        let visitedSpotCount: Int
    }

    var schemaVersion: Int = DevelopSettings.currentSchemaVersion
    static let currentSchemaVersion = 6

    // Profile
    var profileAmount = 1.0

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

    // Parametric curve
    var curveHighlights = 0.0
    var curveLights = 0.0
    var curveDarks = 0.0
    var curveShadows = 0.0
    var curveSplitShadows = 0.25
    var curveSplitMid = 0.5
    var curveSplitHighlights = 0.75
    var curveRefineSaturation = 1.0

    // Point curves: master (luminance) + per-channel
    var toneCurve: [CurvePoint] = DevelopSettings.linearCurve
    var toneCurveRed: [CurvePoint] = DevelopSettings.linearCurve
    var toneCurveGreen: [CurvePoint] = DevelopSettings.linearCurve
    var toneCurveBlue: [CurvePoint] = DevelopSettings.linearCurve

    // Color mixer (8-band HSL)
    var colorMix = ColorMix()

    // Color grading (3-way)
    var grade = ColorGrade()

    // Selective edits
    var pointColors: [PointColorAdjustment] = []
    var masks: [LocalMask] = []
    var spots: [SpotCorrection] = []
    var redEyes: [RedEyeCorrection] = []

    // Black & white
    var blackWhite = false
    var bwRed = 0.0
    var bwOrange = 0.0
    var bwYellow = 0.0
    var bwGreen = 0.0
    var bwAqua = 0.0
    var bwBlue = 0.0
    var bwPurple = 0.0
    var bwMagenta = 0.0

    // Detail
    var sharpness = 0.0          // 0...1
    var sharpenRadius = 0.0      // 0...1
    var sharpenDetail = 0.25     // 0...1
    var sharpenMasking = 0.0     // 0...1
    var noiseReduction = 0.0     // 0...1  (luminance)
    var noiseReductionDetail = 0.5
    var noiseReductionContrast = 0.0
    var colorNoiseReduction = 0.0 // 0...1
    var colorNoiseReductionDetail = 0.5
    var colorNoiseReductionSmoothness = 0.5
    var grain = 0.0              // 0...1
    var grainSize = 0.25          // 0...1
    var grainRoughness = 0.5      // 0...1

    // Effects
    var vignette = 0.0
    var vignetteMidpoint = 0.5
    var vignetteRoundness = 0.0
    var vignetteFeather = 0.5
    var vignetteHighlights = 0.0

    // Optics
    var opticsDistortion = 0.0
    var opticsVignetting = 0.0
    var opticsVignettingMidpoint = 0.5
    var opticsProfileDistortion = 1.0
    var opticsProfileVignetting = 1.0
    var opticsDefringePurple = 0.0
    var opticsDefringePurpleHueLo = 0.3
    var opticsDefringePurpleHueHi = 0.7
    var opticsDefringeGreen = 0.0
    var opticsDefringeGreenHueLo = 0.4
    var opticsDefringeGreenHueHi = 0.6
    var opticsCARed = 0.0
    var opticsCABlue = 0.0

    // Geometry
    var cropX = 0.0, cropY = 0.0, cropW = 1.0, cropH = 1.0
    var straighten = 0.0         // degrees -45...45
    var geometryVertical = 0.0
    var geometryHorizontal = 0.0
    var geometryAspect = 0.0
    var geometryScale = 1.0
    var geometryOffsetX = 0.0
    var geometryOffsetY = 0.0
    var flipH = false
    var flipV = false
    var rotationQuarterTurns = 0

    // Calibration
    var calibrationShadowsTint = 0.0
    var calibrationRedHue = 0.0
    var calibrationRedSat = 0.0
    var calibrationGreenHue = 0.0
    var calibrationGreenSat = 0.0
    var calibrationBlueHue = 0.0
    var calibrationBlueSat = 0.0

    init() {}

    static let linearCurve: [CurvePoint] = [
        CurvePoint(0, 0), CurvePoint(0.25, 0.25), CurvePoint(0.5, 0.5),
        CurvePoint(0.75, 0.75), CurvePoint(1, 1)
    ]
    static let maximumToneCurvePointCount = 256

    // MARK: Lenient decoding

    enum CodingKeys: String, CodingKey {
        case schemaVersion, profileAmount, temperature, tint, exposure, contrast, highlights,
             shadows, whites, blacks, texture, clarity, dehaze, vibrance, saturation,
             curveHighlights, curveLights, curveDarks, curveShadows,
             curveSplitShadows, curveSplitMid, curveSplitHighlights, curveRefineSaturation,
             toneCurve, toneCurveRed, toneCurveGreen, toneCurveBlue,
             colorMix, grade, pointColors, masks, spots, redEyes,
             blackWhite, bwRed, bwOrange, bwYellow, bwGreen, bwAqua,
             bwBlue, bwPurple, bwMagenta,
             sharpness, sharpenRadius, sharpenDetail, sharpenMasking,
             noiseReduction, noiseReductionDetail, noiseReductionContrast,
             colorNoiseReduction, colorNoiseReductionDetail, colorNoiseReductionSmoothness,
             grain, grainSize, grainRoughness,
             vignette, vignetteMidpoint, vignetteRoundness, vignetteFeather, vignetteHighlights,
             opticsDistortion, opticsVignetting, opticsVignettingMidpoint,
             opticsProfileDistortion, opticsProfileVignetting,
             opticsDefringePurple, opticsDefringePurpleHueLo, opticsDefringePurpleHueHi,
             opticsDefringeGreen, opticsDefringeGreenHueLo, opticsDefringeGreenHueHi,
             opticsCARed, opticsCABlue,
             cropX, cropY, cropW, cropH, straighten,
             geometryVertical, geometryHorizontal, geometryAspect, geometryScale,
             geometryOffsetX, geometryOffsetY, flipH, flipV, rotationQuarterTurns,
             calibrationShadowsTint, calibrationRedHue, calibrationRedSat,
             calibrationGreenHue, calibrationGreenSat, calibrationBlueHue, calibrationBlueSat
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func dbl(_ k: CodingKeys, _ f: Double) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil ?? f }
        func bool(_ k: CodingKeys, _ f: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil ?? f }
        func curve(_ k: CodingKeys) -> [CurvePoint] { (try? c.decodeIfPresent([CurvePoint].self, forKey: k)) ?? nil ?? Self.linearCurve }

        let sourceSchemaVersion = c.contains(.schemaVersion)
            ? try c.decode(Int.self, forKey: .schemaVersion)
            : 1
        guard (1...Self.currentSchemaVersion).contains(sourceSchemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: c,
                debugDescription: "Unsupported DevelopSettings schema version \(sourceSchemaVersion); maximum supported version is \(Self.currentSchemaVersion)."
            )
        }

        let defaults = Self()
        schemaVersion = sourceSchemaVersion
        // Missing keys, including all v5/v6 keys in older sidecars, migrate from neutral defaults.
        profileAmount = dbl(.profileAmount, defaults.profileAmount)
        temperature = dbl(.temperature, 0); tint = dbl(.tint, 0)
        exposure = dbl(.exposure, 0); contrast = dbl(.contrast, 0)
        highlights = dbl(.highlights, 0); shadows = dbl(.shadows, 0)
        whites = dbl(.whites, 0); blacks = dbl(.blacks, 0)
        texture = dbl(.texture, 0); clarity = dbl(.clarity, 0); dehaze = dbl(.dehaze, 0)
        vibrance = dbl(.vibrance, 0); saturation = dbl(.saturation, 0)
        curveHighlights = dbl(.curveHighlights, defaults.curveHighlights)
        curveLights = dbl(.curveLights, defaults.curveLights)
        curveDarks = dbl(.curveDarks, defaults.curveDarks)
        curveShadows = dbl(.curveShadows, defaults.curveShadows)
        curveSplitShadows = dbl(.curveSplitShadows, defaults.curveSplitShadows)
        curveSplitMid = dbl(.curveSplitMid, defaults.curveSplitMid)
        curveSplitHighlights = dbl(.curveSplitHighlights, defaults.curveSplitHighlights)
        curveRefineSaturation = dbl(.curveRefineSaturation, defaults.curveRefineSaturation)
        toneCurve = curve(.toneCurve)
        toneCurveRed = curve(.toneCurveRed); toneCurveGreen = curve(.toneCurveGreen); toneCurveBlue = curve(.toneCurveBlue)
        colorMix = (try? c.decodeIfPresent(ColorMix.self, forKey: .colorMix)) ?? nil ?? ColorMix()
        grade = (try? c.decodeIfPresent(ColorGrade.self, forKey: .grade)) ?? nil ?? ColorGrade()
        pointColors = SelectiveDevelopNormalization.boundedLossyArray(
            PointColorAdjustment.self,
            forKey: .pointColors,
            from: c,
            decoder: decoder,
            maximumCount: PointColorAdjustment.maximumCount
        )
        masks = SelectiveDevelopNormalization.boundedLossyArray(
            LocalMask.self,
            forKey: .masks,
            from: c,
            decoder: decoder,
            maximumCount: LocalMask.maximumCount
        )
        spots = SelectiveDevelopNormalization.boundedLossyArray(
            SpotCorrection.self,
            forKey: .spots,
            from: c,
            decoder: decoder,
            maximumCount: SpotCorrection.maximumCount
        )
        redEyes = SelectiveDevelopNormalization.boundedLossyArray(
            RedEyeCorrection.self,
            forKey: .redEyes,
            from: c,
            decoder: decoder,
            maximumCount: RedEyeCorrection.maximumCount
        )
        blackWhite = bool(.blackWhite, false)
        bwRed = dbl(.bwRed, 0); bwOrange = dbl(.bwOrange, 0); bwYellow = dbl(.bwYellow, 0)
        bwGreen = dbl(.bwGreen, 0); bwAqua = dbl(.bwAqua, 0); bwBlue = dbl(.bwBlue, 0)
        bwPurple = dbl(.bwPurple, 0); bwMagenta = dbl(.bwMagenta, 0)
        sharpness = dbl(.sharpness, 0); sharpenRadius = dbl(.sharpenRadius, 0)
        sharpenDetail = dbl(.sharpenDetail, defaults.sharpenDetail)
        sharpenMasking = dbl(.sharpenMasking, defaults.sharpenMasking)
        noiseReduction = dbl(.noiseReduction, 0)
        noiseReductionDetail = dbl(.noiseReductionDetail, defaults.noiseReductionDetail)
        noiseReductionContrast = dbl(.noiseReductionContrast, defaults.noiseReductionContrast)
        colorNoiseReduction = dbl(.colorNoiseReduction, 0)
        colorNoiseReductionDetail = dbl(.colorNoiseReductionDetail, defaults.colorNoiseReductionDetail)
        colorNoiseReductionSmoothness = dbl(.colorNoiseReductionSmoothness, defaults.colorNoiseReductionSmoothness)
        grain = dbl(.grain, 0)
        grainSize = dbl(.grainSize, defaults.grainSize)
        grainRoughness = dbl(.grainRoughness, defaults.grainRoughness)
        vignette = dbl(.vignette, 0)
        vignetteMidpoint = dbl(.vignetteMidpoint, defaults.vignetteMidpoint)
        vignetteRoundness = dbl(.vignetteRoundness, defaults.vignetteRoundness)
        vignetteFeather = dbl(.vignetteFeather, defaults.vignetteFeather)
        vignetteHighlights = dbl(.vignetteHighlights, defaults.vignetteHighlights)
        opticsDistortion = dbl(.opticsDistortion, defaults.opticsDistortion)
        opticsVignetting = dbl(.opticsVignetting, defaults.opticsVignetting)
        opticsVignettingMidpoint = dbl(.opticsVignettingMidpoint, defaults.opticsVignettingMidpoint)
        opticsProfileDistortion = dbl(.opticsProfileDistortion, defaults.opticsProfileDistortion)
        opticsProfileVignetting = dbl(.opticsProfileVignetting, defaults.opticsProfileVignetting)
        opticsDefringePurple = dbl(.opticsDefringePurple, defaults.opticsDefringePurple)
        opticsDefringePurpleHueLo = dbl(.opticsDefringePurpleHueLo, defaults.opticsDefringePurpleHueLo)
        opticsDefringePurpleHueHi = dbl(.opticsDefringePurpleHueHi, defaults.opticsDefringePurpleHueHi)
        opticsDefringeGreen = dbl(.opticsDefringeGreen, defaults.opticsDefringeGreen)
        opticsDefringeGreenHueLo = dbl(.opticsDefringeGreenHueLo, defaults.opticsDefringeGreenHueLo)
        opticsDefringeGreenHueHi = dbl(.opticsDefringeGreenHueHi, defaults.opticsDefringeGreenHueHi)
        opticsCARed = dbl(.opticsCARed, defaults.opticsCARed)
        opticsCABlue = dbl(.opticsCABlue, defaults.opticsCABlue)
        cropX = dbl(.cropX, 0); cropY = dbl(.cropY, 0); cropW = dbl(.cropW, 1); cropH = dbl(.cropH, 1)
        straighten = dbl(.straighten, 0)
        geometryVertical = dbl(.geometryVertical, defaults.geometryVertical)
        geometryHorizontal = dbl(.geometryHorizontal, defaults.geometryHorizontal)
        geometryAspect = dbl(.geometryAspect, defaults.geometryAspect)
        geometryScale = dbl(.geometryScale, defaults.geometryScale)
        geometryOffsetX = dbl(.geometryOffsetX, defaults.geometryOffsetX)
        geometryOffsetY = dbl(.geometryOffsetY, defaults.geometryOffsetY)
        flipH = bool(.flipH, false); flipV = bool(.flipV, false)
        rotationQuarterTurns = (try? c.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns)) ?? nil ?? 0
        calibrationShadowsTint = dbl(.calibrationShadowsTint, defaults.calibrationShadowsTint)
        calibrationRedHue = dbl(.calibrationRedHue, defaults.calibrationRedHue)
        calibrationRedSat = dbl(.calibrationRedSat, defaults.calibrationRedSat)
        calibrationGreenHue = dbl(.calibrationGreenHue, defaults.calibrationGreenHue)
        calibrationGreenSat = dbl(.calibrationGreenSat, defaults.calibrationGreenSat)
        calibrationBlueHue = dbl(.calibrationBlueHue, defaults.calibrationBlueHue)
        calibrationBlueSat = dbl(.calibrationBlueSat, defaults.calibrationBlueSat)
        normalizeDecodedValues()
    }

    private mutating func normalizeDecodedValues() {
        profileAmount = Self.clampedFinite(profileAmount, 0...2, defaultValue: 1)
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

        curveHighlights = Self.clampedFinite(curveHighlights, -1...1)
        curveLights = Self.clampedFinite(curveLights, -1...1)
        curveDarks = Self.clampedFinite(curveDarks, -1...1)
        curveShadows = Self.clampedFinite(curveShadows, -1...1)
        curveSplitShadows = Self.clampedFinite(curveSplitShadows, 0...1, defaultValue: 0.25)
        curveSplitMid = Self.clampedFinite(curveSplitMid, 0...1, defaultValue: 0.5)
        curveSplitHighlights = Self.clampedFinite(curveSplitHighlights, 0...1, defaultValue: 0.75)
        curveRefineSaturation = Self.clampedFinite(curveRefineSaturation, 0...1, defaultValue: 1)
        colorMix = colorMix.normalized()

        bwRed = Self.clampedFinite(bwRed, -1...1)
        bwOrange = Self.clampedFinite(bwOrange, -1...1)
        bwYellow = Self.clampedFinite(bwYellow, -1...1)
        bwGreen = Self.clampedFinite(bwGreen, -1...1)
        bwAqua = Self.clampedFinite(bwAqua, -1...1)
        bwBlue = Self.clampedFinite(bwBlue, -1...1)
        bwPurple = Self.clampedFinite(bwPurple, -1...1)
        bwMagenta = Self.clampedFinite(bwMagenta, -1...1)

        sharpness = Self.clampedFinite(sharpness, 0...1)
        sharpenRadius = Self.clampedFinite(sharpenRadius, 0...1)
        sharpenDetail = Self.clampedFinite(sharpenDetail, 0...1, defaultValue: 0.25)
        sharpenMasking = Self.clampedFinite(sharpenMasking, 0...1)
        noiseReduction = Self.clampedFinite(noiseReduction, 0...1)
        noiseReductionDetail = Self.clampedFinite(noiseReductionDetail, 0...1, defaultValue: 0.5)
        noiseReductionContrast = Self.clampedFinite(noiseReductionContrast, 0...1)
        colorNoiseReduction = Self.clampedFinite(colorNoiseReduction, 0...1)
        colorNoiseReductionDetail = Self.clampedFinite(colorNoiseReductionDetail, 0...1, defaultValue: 0.5)
        colorNoiseReductionSmoothness = Self.clampedFinite(colorNoiseReductionSmoothness, 0...1, defaultValue: 0.5)
        grain = Self.clampedFinite(grain, 0...1)
        grainSize = Self.clampedFinite(grainSize, 0...1, defaultValue: 0.25)
        grainRoughness = Self.clampedFinite(grainRoughness, 0...1, defaultValue: 0.5)
        vignette = Self.clampedFinite(vignette, -1...1)
        vignetteMidpoint = Self.clampedFinite(vignetteMidpoint, 0...1, defaultValue: 0.5)
        vignetteRoundness = Self.clampedFinite(vignetteRoundness, -1...1)
        vignetteFeather = Self.clampedFinite(vignetteFeather, 0...1, defaultValue: 0.5)
        vignetteHighlights = Self.clampedFinite(vignetteHighlights, 0...1)

        grade.shadowHue = Self.clampedFinite(grade.shadowHue, 0...1)
        grade.midHue = Self.clampedFinite(grade.midHue, 0...1)
        grade.highHue = Self.clampedFinite(grade.highHue, 0...1)
        grade.globalHue = Self.clampedFinite(grade.globalHue, 0...1)
        grade.shadowSat = Self.clampedFinite(grade.shadowSat, 0...1)
        grade.midSat = Self.clampedFinite(grade.midSat, 0...1)
        grade.highSat = Self.clampedFinite(grade.highSat, 0...1)
        grade.globalSat = Self.clampedFinite(grade.globalSat, 0...1)
        grade.shadowLum = Self.clampedFinite(grade.shadowLum, -1...1)
        grade.midLum = Self.clampedFinite(grade.midLum, -1...1)
        grade.highLum = Self.clampedFinite(grade.highLum, -1...1)
        grade.globalLum = Self.clampedFinite(grade.globalLum, -1...1)
        grade.blending = Self.clampedFinite(grade.blending, 0...1, defaultValue: 0.5)
        grade.balance = Self.clampedFinite(grade.balance, -1...1)

        pointColors = pointColors.prefix(PointColorAdjustment.maximumCount).map { $0.normalized() }
        let selectivePaths = Self.boundedSelectivePaths(masks: masks, spots: spots)
        masks = selectivePaths.masks
        spots = selectivePaths.spots
        redEyes = redEyes.prefix(RedEyeCorrection.maximumCount).map { $0.normalized() }
        repairSelectiveIDs()

        toneCurve = Self.normalizedCurve(toneCurve)
        toneCurveRed = Self.normalizedCurve(toneCurveRed)
        toneCurveGreen = Self.normalizedCurve(toneCurveGreen)
        toneCurveBlue = Self.normalizedCurve(toneCurveBlue)

        cropW = Self.clampedFinite(cropW, 0.01...1)
        cropH = Self.clampedFinite(cropH, 0.01...1)
        cropX = Self.clampedFinite(cropX, 0...(1 - cropW))
        cropY = Self.clampedFinite(cropY, 0...(1 - cropH))
        straighten = Self.clampedFinite(straighten, -45...45)
        geometryVertical = Self.clampedFinite(geometryVertical, -1...1)
        geometryHorizontal = Self.clampedFinite(geometryHorizontal, -1...1)
        geometryAspect = Self.clampedFinite(geometryAspect, -1...1)
        geometryScale = Self.clampedFinite(geometryScale, 0.5...1.5, defaultValue: 1)
        geometryOffsetX = Self.clampedFinite(geometryOffsetX, -1...1)
        geometryOffsetY = Self.clampedFinite(geometryOffsetY, -1...1)
        rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4

        opticsDistortion = Self.clampedFinite(opticsDistortion, -1...1)
        opticsVignetting = Self.clampedFinite(opticsVignetting, -1...1)
        opticsVignettingMidpoint = Self.clampedFinite(opticsVignettingMidpoint, 0...1, defaultValue: 0.5)
        opticsProfileDistortion = Self.clampedFinite(opticsProfileDistortion, 0...2, defaultValue: 1)
        opticsProfileVignetting = Self.clampedFinite(opticsProfileVignetting, 0...2, defaultValue: 1)
        opticsDefringePurple = Self.clampedFinite(opticsDefringePurple, 0...1)
        opticsDefringePurpleHueLo = Self.clampedFinite(opticsDefringePurpleHueLo, 0...1, defaultValue: 0.3)
        opticsDefringePurpleHueHi = Self.clampedFinite(opticsDefringePurpleHueHi, 0...1, defaultValue: 0.7)
        opticsDefringeGreen = Self.clampedFinite(opticsDefringeGreen, 0...1)
        opticsDefringeGreenHueLo = Self.clampedFinite(opticsDefringeGreenHueLo, 0...1, defaultValue: 0.4)
        opticsDefringeGreenHueHi = Self.clampedFinite(opticsDefringeGreenHueHi, 0...1, defaultValue: 0.6)
        opticsCARed = Self.clampedFinite(opticsCARed, -1...1)
        opticsCABlue = Self.clampedFinite(opticsCABlue, -1...1)

        calibrationShadowsTint = Self.clampedFinite(calibrationShadowsTint, -1...1)
        calibrationRedHue = Self.clampedFinite(calibrationRedHue, -1...1)
        calibrationRedSat = Self.clampedFinite(calibrationRedSat, -1...1)
        calibrationGreenHue = Self.clampedFinite(calibrationGreenHue, -1...1)
        calibrationGreenSat = Self.clampedFinite(calibrationGreenSat, -1...1)
        calibrationBlueHue = Self.clampedFinite(calibrationBlueHue, -1...1)
        calibrationBlueSat = Self.clampedFinite(calibrationBlueSat, -1...1)

        schemaVersion = Self.currentSchemaVersion
    }

    func normalizedForPersistence() -> DevelopSettings {
        var normalized = self
        normalized.normalizeDecodedValues()
        return normalized
    }

    private mutating func repairSelectiveIDs() {
        let reservedEntityIDs = Set(
            (pointColors.map(\.id) + masks.map(\.id) + spots.map(\.id) + redEyes.map(\.id))
                .filter { $0 != SelectiveDevelopNormalization.malformedUUID }
        )
        var entityIDs = Set<UUID>()
        for index in pointColors.indices {
            pointColors[index].id = Self.uniqueID(
                pointColors[index].id,
                reserving: reservedEntityIDs,
                in: &entityIDs
            )
        }
        for index in masks.indices {
            masks[index].id = Self.uniqueID(
                masks[index].id,
                reserving: reservedEntityIDs,
                in: &entityIDs
            )
        }
        for index in spots.indices {
            spots[index].id = Self.uniqueID(
                spots[index].id,
                reserving: reservedEntityIDs,
                in: &entityIDs
            )
        }
        for index in redEyes.indices {
            redEyes[index].id = Self.uniqueID(
                redEyes[index].id,
                reserving: reservedEntityIDs,
                in: &entityIDs
            )
        }

        let reservedComponentIDs = Set(
            masks.flatMap { $0.components.map(\.id) }
                .filter { $0 != SelectiveDevelopNormalization.malformedUUID }
        )
        var componentIDs = Set<UUID>()
        for maskIndex in masks.indices {
            for componentIndex in masks[maskIndex].components.indices {
                let id = masks[maskIndex].components[componentIndex].id
                masks[maskIndex].components[componentIndex].id = Self.uniqueID(
                    id,
                    reserving: reservedComponentIDs,
                    in: &componentIDs
                )
            }
        }
    }

    /// Bounds source traversal and copying before nested selective records are
    /// normalized. Masks retain document priority, matching persistence order.
    static func boundedSelectivePaths(
        masks: [LocalMask],
        spots: [SpotCorrection]
    ) -> SelectivePathBounds {
        var remaining = SelectiveDevelopLimits.maximumTotalPathPoints
        var copiedPointCount = 0
        var visitedBrushStrokeCount = 0
        var visitedSpotCount = 0
        var boundedMasks: [LocalMask] = []
        boundedMasks.reserveCapacity(min(masks.count, LocalMask.maximumCount))

        for mask in masks.prefix(LocalMask.maximumCount) {
            var boundedComponents: [MaskComponent] = []
            boundedComponents.reserveCapacity(min(
                mask.components.count,
                LocalMask.maximumComponentCount
            ))
            for component in mask.components.prefix(LocalMask.maximumComponentCount) {
                guard case let .brush(strokes) = component.shape else {
                    boundedComponents.append(component.normalized())
                    continue
                }

                var boundedStrokes: [BrushStroke] = []
                boundedStrokes.reserveCapacity(min(
                    strokes.count,
                    MaskShape.maximumStrokeCount
                ))
                for stroke in strokes.prefix(MaskShape.maximumStrokeCount) {
                    guard remaining > 0 else { break }
                    visitedBrushStrokeCount += 1
                    let pointLimit = min(remaining, BrushStroke.maximumPointCount)
                    let points = Array(stroke.points.prefix(pointLimit))
                    guard !points.isEmpty else { continue }
                    boundedStrokes.append(BrushStroke(
                        points: points,
                        size: stroke.size,
                        feather: stroke.feather,
                        flow: stroke.flow,
                        density: stroke.density,
                        erase: stroke.erase
                    ))
                    remaining -= points.count
                    copiedPointCount += points.count
                }
                boundedComponents.append(MaskComponent(
                    id: component.id,
                    operation: component.operation,
                    inverted: component.inverted,
                    shape: .brush(strokes: boundedStrokes)
                ))
            }
            boundedMasks.append(LocalMask(
                id: mask.id,
                name: mask.name,
                enabled: mask.enabled,
                inverted: mask.inverted,
                components: boundedComponents,
                adjustments: mask.adjustments
            ))
        }

        var boundedSpots: [SpotCorrection] = []
        boundedSpots.reserveCapacity(min(spots.count, SpotCorrection.maximumCount))
        for spot in spots.prefix(SpotCorrection.maximumCount) {
            guard remaining > 0 else { break }
            visitedSpotCount += 1
            let pointLimit = min(remaining, SpotCorrection.maximumPointCount)
            let points = Array(spot.points.prefix(pointLimit))
            guard !points.isEmpty else { continue }
            boundedSpots.append(SpotCorrection(
                id: spot.id,
                mode: spot.mode,
                points: points,
                size: spot.size,
                feather: spot.feather,
                opacity: spot.opacity,
                sourceOffset: spot.sourceOffset
            ))
            remaining -= points.count
            copiedPointCount += points.count
        }
        return SelectivePathBounds(
            masks: boundedMasks,
            spots: boundedSpots,
            copiedPointCount: copiedPointCount,
            visitedBrushStrokeCount: visitedBrushStrokeCount,
            visitedSpotCount: visitedSpotCount
        )
    }

    private static func uniqueID(
        _ id: UUID,
        reserving reserved: Set<UUID>,
        in used: inout Set<UUID>
    ) -> UUID {
        if id != SelectiveDevelopNormalization.malformedUUID,
           used.insert(id).inserted {
            return id
        }

        var attempt = 0
        while true {
            attempt += 1
            let replacement = deterministicReplacementID(for: id, attempt: attempt)
            if !reserved.contains(replacement), used.insert(replacement).inserted {
                return replacement
            }
        }
    }

    private static func deterministicReplacementID(for id: UUID, attempt: Int) -> UUID {
        let input = Data("RawLight selective ID:\(id.uuidString):\(attempt)".utf8)
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func clampedFinite(
        _ value: Double,
        _ range: ClosedRange<Double>,
        defaultValue: Double = 0
    ) -> Double {
        guard value.isFinite else { return min(max(defaultValue, range.lowerBound), range.upperBound) }
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
        guard unique.count > maximumToneCurvePointCount else { return unique }

        let lastIndex = unique.count - 1
        let sampleLastIndex = maximumToneCurvePointCount - 1
        // Even index sampling keeps both endpoints and the full source range.
        return (0..<maximumToneCurvePointCount).map { index in
            let position = Double(index) * Double(lastIndex) / Double(sampleLastIndex)
            return unique[Int(position.rounded())]
        }
    }
}

nonisolated extension DevelopSettings {

    var currentPathPointCount: Int {
        var count = 0
        for mask in masks.prefix(LocalMask.maximumCount) {
            for component in mask.components.prefix(LocalMask.maximumComponentCount) {
                if case let .brush(strokes) = component.shape {
                    for stroke in strokes.prefix(MaskShape.maximumStrokeCount) {
                        count += min(
                            stroke.points.count,
                            SelectiveDevelopLimits.maximumTotalPathPoints - count
                        )
                        if count == SelectiveDevelopLimits.maximumTotalPathPoints { return count }
                    }
                }
            }
        }
        for spot in spots.prefix(SpotCorrection.maximumCount) {
            count += min(
                spot.points.count,
                SelectiveDevelopLimits.maximumTotalPathPoints - count
            )
            if count == SelectiveDevelopLimits.maximumTotalPathPoints { return count }
        }
        return count
    }

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
        !isFullFrame || straighten != 0 || geometryVertical != 0 || geometryHorizontal != 0
            || geometryAspect != 0 || geometryScale != 1 || geometryOffsetX != 0 || geometryOffsetY != 0
            || flipH || flipV || rotationQuarterTurns % 4 != 0
    }

    /// The "before" look: tone/colour/detail reset, geometry preserved so the
    /// before/after comparison keeps the same framing.
    var beforeSettings: DevelopSettings {
        var b = DevelopSettings()
        b.cropX = cropX; b.cropY = cropY; b.cropW = cropW; b.cropH = cropH
        b.straighten = straighten; b.flipH = flipH; b.flipV = flipV
        b.geometryVertical = geometryVertical; b.geometryHorizontal = geometryHorizontal
        b.geometryAspect = geometryAspect; b.geometryScale = geometryScale
        b.geometryOffsetX = geometryOffsetX; b.geometryOffsetY = geometryOffsetY
        b.rotationQuarterTurns = rotationQuarterTurns
        return b
    }

    mutating func reset() {
        self = DevelopSettings()
    }
}

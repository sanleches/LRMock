//
//  ImagingAlgorithmTests.swift
//  LRMockTests
//
//  Unit tests for the pure imaging math: tone-curve LUT (monotone cubic),
//  colour-cube engine (HSL mixer + grading), content digest, and fingerprint.
//

import Testing
import Foundation
import CoreGraphics
import CoreImage
@testable import LRMock

struct ToneCurveLUTTests {

    @Test func identityCurveIsApproximatelyLinear() {
        let lut = ToneCurveLUT.lut(from: DevelopSettings.linearCurve, sampleCount: 256)
        #expect(lut.count == 256)
        #expect(abs(lut[0]) < 0.01)
        #expect(abs(lut[255] - 1) < 0.01)
        #expect(abs(lut[128] - 0.5) < 0.03)
    }

    @Test func curvePassesThroughControlPoints() {
        let points = [CurvePoint(0, 0), CurvePoint(0.5, 0.8), CurvePoint(1, 1)]
        #expect(abs(ToneCurveLUT.value(at: 0, points: points) - 0) < 0.001)
        #expect(abs(ToneCurveLUT.value(at: 0.5, points: points) - 0.8) < 0.01)
        #expect(abs(ToneCurveLUT.value(at: 1, points: points) - 1) < 0.001)
    }

    @Test func monotoneCurveNeverOvershoots() {
        // A steep S-curve must stay within [0,1] and not wiggle.
        let points = [CurvePoint(0, 0), CurvePoint(0.25, 0.05),
                      CurvePoint(0.5, 0.5), CurvePoint(0.75, 0.95), CurvePoint(1, 1)]
        let lut = ToneCurveLUT.lut(from: points, sampleCount: 256)
        for v in lut { #expect(v >= 0 && v <= 1) }
        // Non-decreasing (monotone).
        for i in 1..<lut.count { #expect(lut[i] >= lut[i - 1] - 0.0001) }
    }

    @Test func channelLUTComposesMasterThenChannel() {
        // Master lifts everything; red channel identity → result == master on R.
        var master = DevelopSettings.linearCurve
        master[2].y = 0.7 // brighten midtones
        let lut = ToneCurveLUT.channelLUT(
            master: master, red: DevelopSettings.linearCurve,
            green: DevelopSettings.linearCurve, blue: DevelopSettings.linearCurve)
        #expect(lut.count == 256 * 3)
        // Midpoint R should reflect the lifted master curve.
        let midR = lut[128 * 3]
        #expect(midR > 0.5)
    }

    @Test func basicToneControlsHaveUsefulEffectsInBothDirections() {
        let blackInput = 0.10
        let blackDown = ToneCurveLUT.basicToneValue(at: blackInput, blacks: -0.75)
        let blackUp = ToneCurveLUT.basicToneValue(at: blackInput, blacks: 0.75)
        #expect(blackDown < blackInput - 0.01)
        #expect(blackUp > blackInput + 0.01)

        let shadowInput = 0.40
        let shadowDown = ToneCurveLUT.basicToneValue(at: shadowInput, shadows: -0.75)
        let shadowUp = ToneCurveLUT.basicToneValue(at: shadowInput, shadows: 0.75)
        #expect(shadowDown < shadowInput - 0.01)
        #expect(shadowUp > shadowInput + 0.01)

        let highlightInput = 0.60
        let highlightDown = ToneCurveLUT.basicToneValue(at: highlightInput, highlights: -0.75)
        let highlightUp = ToneCurveLUT.basicToneValue(at: highlightInput, highlights: 0.75)
        #expect(highlightDown < highlightInput - 0.01)
        #expect(highlightUp > highlightInput + 0.01)

        let whiteInput = 0.90
        let whiteDown = ToneCurveLUT.basicToneValue(at: whiteInput, whites: -0.75)
        let whiteUp = ToneCurveLUT.basicToneValue(at: whiteInput, whites: 0.75)
        #expect(whiteDown < whiteInput - 0.01)
        #expect(whiteUp > whiteInput + 0.01)
    }

    @Test func basicToneLUTStaysBoundedAndMonotone() {
        let combinations = [
            (1.0, 1.0, 1.0, 1.0),
            (-1.0, -1.0, -1.0, -1.0),
            (1.0, -1.0, 1.0, -1.0),
            (-1.0, 1.0, -1.0, 1.0),
        ]

        for (highlights, shadows, whites, blacks) in combinations {
            let lut = ToneCurveLUT.basicToneLUT(
                highlights: highlights, shadows: shadows,
                whites: whites, blacks: blacks, sampleCount: 1_025)
            #expect(abs(lut[0]) < 0.0001)
            #expect(abs(lut[lut.count - 1] - 1) < 0.0001)
            #expect(lut.allSatisfy { $0 >= 0 && $0 <= 1 })
            for index in 1..<lut.count {
                #expect(lut[index] >= lut[index - 1] - 0.000001)
            }
        }
    }

    @Test func channelLUTComposesFoundationToneInTheSamePass() {
        let sampleCount = 256
        let index = 204
        let x = Double(index) / Double(sampleCount - 1)
        let expected = ToneCurveLUT.basicToneValue(
            at: x, highlights: 0.6, shadows: -0.4,
            whites: 0.5, blacks: -0.3)
        let lut = ToneCurveLUT.channelLUT(
            master: DevelopSettings.linearCurve,
            red: DevelopSettings.linearCurve,
            green: DevelopSettings.linearCurve,
            blue: DevelopSettings.linearCurve,
            sampleCount: sampleCount,
            highlights: 0.6, shadows: -0.4,
            whites: 0.5, blacks: -0.3)

        #expect(abs(Double(lut[index * 3]) - expected) < 0.0001)
        #expect(abs(Double(lut[index * 3 + 1]) - expected) < 0.0001)
        #expect(abs(Double(lut[index * 3 + 2]) - expected) < 0.0001)
    }

    @Test func parametricRegionsAndSplitsAreBoundedMonotoneAndDirectional() {
        let controls = [
            (1.0, 0.0, 0.0, 0.0),
            (0.0, 1.0, 0.0, 0.0),
            (0.0, 0.0, -1.0, 0.0),
            (0.0, 0.0, 0.0, -1.0),
            (1.0, -1.0, 1.0, -1.0),
        ]
        for (highlights, lights, darks, shadows) in controls {
            let lut = ToneCurveLUT.parametricToneLUT(
                highlights: highlights, lights: lights,
                darks: darks, shadows: shadows,
                splitShadows: 0.2, splitMid: 0.55,
                splitHighlights: 0.82, sampleCount: 1_025
            )
            #expect(lut.allSatisfy { $0 >= 0 && $0 <= 1 })
            for index in 1..<lut.count {
                #expect(lut[index] >= lut[index - 1] - 0.000_001)
            }
        }

        #expect(ToneCurveLUT.parametricToneValue(at: 0.1, shadows: 0.8) > 0.1)
        #expect(ToneCurveLUT.parametricToneValue(at: 0.38, darks: -0.8) < 0.38)
        #expect(ToneCurveLUT.parametricToneValue(at: 0.62, lights: 0.8) > 0.62)
        #expect(ToneCurveLUT.parametricToneValue(at: 0.9, highlights: -0.8) < 0.9)

        let early = ToneCurveLUT.parametricToneValue(
            at: 0.3, darks: 0.8, splitShadows: 0.2, splitMid: 0.4)
        let late = ToneCurveLUT.parametricToneValue(
            at: 0.3, darks: 0.8, splitShadows: 0.35, splitMid: 0.65)
        #expect(abs(early - late) > 0.005)
    }

    @Test func channelLUTIncludesParametricCurveAndSanitizesDescendingPoints() {
        let descending = [CurvePoint(0, 0), CurvePoint(0.5, 0.8), CurvePoint(1, 0.2)]
        let lut = ToneCurveLUT.channelLUT(
            master: descending,
            red: DevelopSettings.linearCurve,
            green: DevelopSettings.linearCurve,
            blue: DevelopSettings.linearCurve,
            sampleCount: 513,
            curveLights: 0.7,
            splitShadows: 0.2,
            splitMid: 0.45,
            splitHighlights: 0.8
        )
        for channel in 0..<3 {
            for index in 1..<513 {
                #expect(lut[index * 3 + channel] >= lut[(index - 1) * 3 + channel] - 0.000_001)
            }
        }
        #expect(ToneCurveLUT.saturationPreservationAmount(refine: 1) == 0)
        #expect(ToneCurveLUT.saturationPreservationAmount(refine: 0) == 0.8)
    }
}

struct WhiteBalanceMappingTests {

    @Test func rawAndRenderedBaselinesUseTheSameNormalizedDeltas() {
        let rawBaseline = WhiteBalanceMapping.Neutral(kelvin: 5_200, tint: 12)
        let renderedBaseline = WhiteBalanceMapping.renderedBaseline
        let raw = WhiteBalanceMapping.adjustedNeutral(
            baseline: rawBaseline, temperature: 0.4, tint: -0.6)
        let rendered = WhiteBalanceMapping.adjustedNeutral(
            baseline: renderedBaseline, temperature: 0.4, tint: -0.6)

        let expectedKelvinDelta = 0.4 * WhiteBalanceMapping.kelvinDeltaPerUnit
        let expectedTintDelta = -0.6 * WhiteBalanceMapping.tintDeltaPerUnit
        #expect(abs((raw.kelvin - rawBaseline.kelvin) - expectedKelvinDelta) < 0.001)
        #expect(abs((rendered.kelvin - renderedBaseline.kelvin) - expectedKelvinDelta) < 0.001)
        #expect(abs((raw.tint - rawBaseline.tint) - expectedTintDelta) < 0.001)
        #expect(abs((rendered.tint - renderedBaseline.tint) - expectedTintDelta) < 0.001)
    }

    @Test func whiteBalanceSignsMoveAroundTheirBaseline() {
        let baseline = WhiteBalanceMapping.renderedBaseline
        let negative = WhiteBalanceMapping.adjustedNeutral(
            baseline: baseline, temperature: -1, tint: -1)
        let positive = WhiteBalanceMapping.adjustedNeutral(
            baseline: baseline, temperature: 1, tint: 1)

        #expect(negative.kelvin < baseline.kelvin)
        #expect(positive.kelvin > baseline.kelvin)
        #expect(negative.tint < baseline.tint)
        #expect(positive.tint > baseline.tint)
    }
}

struct ColorCubeEngineTests {

    @Test func identityMixReturnsNilCube() {
        #expect(ColorCubeEngine.hslCube(for: ColorMix()) == nil)
    }

    @Test func nonIdentityMixProducesCorrectlySizedCube() {
        var mix = ColorMix()
        mix.saturation[0] = -1 // desaturate reds
        let cube = ColorCubeEngine.hslCube(for: mix, dimension: 16)
        #expect(cube != nil)
        // RGBA float cube: 16^3 * 4 * 4 bytes.
        #expect(cube?.data.count == 16 * 16 * 16 * 4 * MemoryLayout<Float>.size)
        #expect(cube?.dimension == 16)
    }

    @Test func gradingIdentityReturnsNil() {
        #expect(ColorCubeEngine.gradingCube(for: ColorGrade()) == nil)
    }

    @Test func gradingCubeBuildsForNonIdentity() {
        var grade = ColorGrade()
        grade.shadowHue = 0.6; grade.shadowSat = 0.5
        #expect(ColorCubeEngine.gradingCube(for: grade) != nil)
    }

    @Test func cubeIsCachedByValue() {
        var mix = ColorMix(); mix.hue[3] = 0.5
        let a = ColorCubeEngine.hslCube(for: mix)
        let b = ColorCubeEngine.hslCube(for: mix)
        // Same input → identical cached data.
        #expect(a?.data == b?.data)
    }

    @Test func blackAndWhiteMixerUsesEveryHueBand() {
        let colors = [
            SIMD3(1.0, 0.0, 0.0),
            SIMD3(1.0, 0.5, 0.0),
            SIMD3(1.0, 1.0, 0.0),
            SIMD3(0.0, 1.0, 0.0),
            SIMD3(0.0, 1.0, 1.0),
            SIMD3(0.0, 0.25, 1.0),
            SIMD3(0.5, 0.0, 1.0),
            SIMD3(1.0, 0.0, 0.75),
        ]
        for index in 0..<8 {
            var mix = [Double](repeating: 0, count: 8)
            let color = colors[index] * 0.6
            let baseline = ColorCubeEngine.blackAndWhiteValue(color, mix: mix).x
            mix[index] = 1
            let raised = ColorCubeEngine.blackAndWhiteValue(color, mix: mix)
            #expect(raised.x > baseline + 0.08)
            #expect(abs(raised.x - raised.y) < 0.000_001)
            #expect(abs(raised.y - raised.z) < 0.000_001)
        }
    }

    @Test func gradingUsesRangeLuminanceGlobalBlendingAndBalance() {
        var grade = ColorGrade()
        grade.shadowHue = 0.62
        grade.shadowSat = 0.8
        grade.shadowLum = 0.5
        grade.highHue = 0.1
        grade.highSat = 0.7
        grade.highLum = -0.4
        grade.globalHue = 0.33
        grade.globalSat = 0.2
        grade.globalLum = 0.15

        let dark = SIMD3<Double>(repeating: 0.12)
        let bright = SIMD3<Double>(repeating: 0.85)
        let darkOut = ColorCubeEngine.gradingValue(dark, grade: grade)
        let brightOut = ColorCubeEngine.gradingValue(bright, grade: grade)
        #expect(darkOut != dark)
        #expect(brightOut != bright)

        var balanced = grade
        balanced.balance = 0.9
        let balanceOut = ColorCubeEngine.gradingValue(SIMD3(repeating: 0.45), grade: balanced)
        let neutralBalanceOut = ColorCubeEngine.gradingValue(SIMD3(repeating: 0.45), grade: grade)
        #expect(balanceOut != neutralBalanceOut)

        balanced.blending = 0
        let narrow = ColorCubeEngine.gradingValue(SIMD3(repeating: 0.45), grade: balanced)
        balanced.blending = 1
        let wide = ColorCubeEngine.gradingValue(SIMD3(repeating: 0.45), grade: balanced)
        #expect(narrow != wide)
    }

    @Test func calibrationIsCachedBoundedAndTargetsShadowsAndPrimaries() {
        #expect(ColorCubeEngine.calibrationCube(
            shadowsTint: 0,
            redHue: 0, redSat: 0,
            greenHue: 0, greenSat: 0,
            blueHue: 0, blueSat: 0
        ) == nil)

        let sample = SIMD3(0.62, 0.31, 0.18)
        let red = ColorCubeEngine.calibrationValue(sample, shadowsTint: 0, redHue: 0.8)
        let green = ColorCubeEngine.calibrationValue(sample, shadowsTint: 0, greenSat: -0.8)
        let blue = ColorCubeEngine.calibrationValue(sample, shadowsTint: 0, blueHue: -0.8)
        #expect(red != sample)
        #expect(green != sample)
        #expect(blue != sample)
        for value in [red, green, blue] {
            #expect(value.x >= 0 && value.x <= 1)
            #expect(value.y >= 0 && value.y <= 1)
            #expect(value.z >= 0 && value.z <= 1)
        }

        let dark = ColorCubeEngine.calibrationValue(
            SIMD3(repeating: 0.12), shadowsTint: 0.8)
        let bright = ColorCubeEngine.calibrationValue(
            SIMD3(repeating: 0.85), shadowsTint: 0.8)
        #expect(dark.y < dark.x)
        #expect(abs(bright.y - bright.x) < abs(dark.y - dark.x))
    }

    @Test func profileHasExactNeutralAndSubtleBidirectionalStrength() {
        #expect(ColorCubeEngine.profileCube(amount: 1) == nil)
        let input = SIMD3(0.7, 0.4, 0.2)
        #expect(ColorCubeEngine.profileValue(input, amount: 1) == input)
        let weak = ColorCubeEngine.profileValue(input, amount: 0)
        let strong = ColorCubeEngine.profileValue(input, amount: 2)
        #expect(weak != input)
        #expect(strong != input)
        #expect(strong.x - strong.z > weak.x - weak.z)
    }

    @Test func defringeHonorsPurpleAndGreenRanges() {
        let purple = SIMD3(0.8, 0.1, 0.8)
        let changed = ColorCubeEngine.defringeValue(
            purple,
            purpleAmount: 1, purpleHueLo: 0, purpleHueHi: 1,
            greenAmount: 0, greenHueLo: 0.4, greenHueHi: 0.6
        )
        let excluded = ColorCubeEngine.defringeValue(
            purple,
            purpleAmount: 1, purpleHueLo: 0, purpleHueHi: 0.05,
            greenAmount: 0, greenHueLo: 0.4, greenHueHi: 0.6
        )
        #expect(abs(changed.x - changed.y) < abs(purple.x - purple.y))
        let excludedDelta = excluded - purple
        #expect(abs(excludedDelta.x) + abs(excludedDelta.y) + abs(excludedDelta.z) < 1e-12)
    }

    @Test func pointColorIdentityIsExactAndActiveValuesStayBounded() {
        let input = SIMD3(0.72, 0.23, 0.11)
        let identity = PointColorAdjustment()
        #expect(ColorCubeEngine.pointColorCube(for: [identity]) == nil)
        #expect(ColorCubeEngine.pointColorValue(input, adjustments: [identity]) == input)

        let reference = ColorCubeEngine.pointColorReference(
            red: input.x, green: input.y, blue: input.z)
        let adjustment = PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: reference.hue,
            hueShift: 1,
            saturationShift: 1,
            luminanceShift: 1,
            variance: 1,
            range: 1,
            hueRange: 1,
            chromaRange: 1,
            luminanceRange: 1
        )
        let output = ColorCubeEngine.pointColorValue(input, adjustments: [adjustment])
        #expect(output.x.isFinite && output.y.isFinite && output.z.isFinite)
        #expect(output.x >= 0 && output.x <= 1)
        #expect(output.y >= 0 && output.y <= 1)
        #expect(output.z >= 0 && output.z <= 1)
        #expect(output != input)
        #expect(ColorCubeEngine.pointColorCube(for: [adjustment], dimension: 8)?.data.count
            == 8 * 8 * 8 * 4 * MemoryLayout<Float>.size)
    }

    @Test func pointColorCubeUsesRedFastestRGBAIndexingAndBoundedDimensions() throws {
        let adjustment = PointColorAdjustment(
            luminance: 0.6,
            chroma: 0.2,
            hue: 0.08,
            hueShift: 0.3,
            range: 1,
            hueRange: 1,
            chromaRange: 1,
            luminanceRange: 1
        )
        let dimension = 3
        let cube = try #require(ColorCubeEngine.pointColorCube(
            for: [adjustment], dimension: dimension))
        let values = cube.data.withUnsafeBytes {
            Array($0.bindMemory(to: Float.self))
        }

        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let denominator = Double(dimension - 1)
                    let expected = ColorCubeEngine.pointColorValue(
                        SIMD3(
                            Double(red) / denominator,
                            Double(green) / denominator,
                            Double(blue) / denominator
                        ),
                        adjustments: [adjustment]
                    )
                    let offset = ((blue * dimension + green) * dimension + red) * 4
                    #expect(abs(Double(values[offset]) - expected.x) < 0.000_001)
                    #expect(abs(Double(values[offset + 1]) - expected.y) < 0.000_001)
                    #expect(abs(Double(values[offset + 2]) - expected.z) < 0.000_001)
                    #expect(values[offset + 3] == 1)
                }
            }
        }

        let minimum = try #require(ColorCubeEngine.pointColorCube(
            for: [adjustment], dimension: Int.min))
        #expect(minimum.dimension == 2)
        #expect(minimum.data.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
        #expect(ColorCubeEngine.maximumCubeDimension == 128)
    }

    @Test func pointColorSelectsNearbyColorsAndWrapsHue() {
        let wrappedNeighbor = SIMD3(0.85, 0.03, 0.08)
        let distant = SIMD3(0.05, 0.75, 0.18)
        let neighborReference = ColorCubeEngine.pointColorReference(
            red: wrappedNeighbor.x, green: wrappedNeighbor.y, blue: wrappedNeighbor.z)
        #expect(neighborReference.hue < 0.1)

        let adjustment = PointColorAdjustment(
            luminance: neighborReference.luminance,
            chroma: neighborReference.chroma,
            hue: 0.99,
            hueShift: 0.45,
            saturationShift: -0.5,
            luminanceShift: 0.45,
            range: 0.5,
            hueRange: 0.35,
            chromaRange: 0.5,
            luminanceRange: 0.5
        )
        let nearOutput = ColorCubeEngine.pointColorValue(
            wrappedNeighbor, adjustments: [adjustment])
        let farOutput = ColorCubeEngine.pointColorValue(distant, adjustments: [adjustment])
        let nearDelta = abs(nearOutput.x - wrappedNeighbor.x)
            + abs(nearOutput.y - wrappedNeighbor.y)
            + abs(nearOutput.z - wrappedNeighbor.z)
        let farDelta = abs(farOutput.x - distant.x)
            + abs(farOutput.y - distant.y)
            + abs(farOutput.z - distant.z)
        #expect(nearDelta > 0.05)
        #expect(nearDelta > farDelta + 0.03)
    }

    @Test func pointColorRangeVarianceOrderAndLimitAreDeterministic() {
        let input = SIMD3(0.64, 0.22, 0.09)
        let reference = ColorCubeEngine.pointColorReference(
            red: input.x, green: input.y, blue: input.z)

        let shiftedSampleHue = (reference.hue + 0.06)
            .truncatingRemainder(dividingBy: 1)
        let narrow = PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: shiftedSampleHue,
            hueShift: 0.45,
            range: 0
        )
        let broad = PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: shiftedSampleHue,
            hueShift: 0.45,
            range: 1
        )
        func delta(_ output: SIMD3<Double>) -> Double {
            abs(output.x - input.x) + abs(output.y - input.y) + abs(output.z - input.z)
        }
        #expect(delta(ColorCubeEngine.pointColorValue(input, adjustments: [broad]))
            > delta(ColorCubeEngine.pointColorValue(input, adjustments: [narrow])) + 0.01)

        let compressed = PointColorAdjustment(
            luminance: max(0, reference.luminance - 0.04),
            chroma: reference.chroma,
            hue: reference.hue,
            variance: -1,
            range: 1,
            hueRange: 1,
            chromaRange: 1,
            luminanceRange: 1
        )
        let expanded = PointColorAdjustment(
            luminance: max(0, reference.luminance - 0.04),
            chroma: reference.chroma,
            hue: reference.hue,
            variance: 1,
            range: 1,
            hueRange: 1,
            chromaRange: 1,
            luminanceRange: 1
        )
        let compressedOutput = ColorCubeEngine.pointColorValue(
            input, adjustments: [compressed])
        let expandedOutput = ColorCubeEngine.pointColorValue(
            input, adjustments: [expanded])
        let compressedReference = ColorCubeEngine.pointColorReference(
            red: compressedOutput.x, green: compressedOutput.y, blue: compressedOutput.z)
        let expandedReference = ColorCubeEngine.pointColorReference(
            red: expandedOutput.x, green: expandedOutput.y, blue: expandedOutput.z)
        #expect(compressedReference.luminance < reference.luminance)
        #expect(expandedReference.luminance > reference.luminance)

        let first = PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: reference.hue,
            hueShift: 0.45,
            range: 0,
            hueRange: 0,
            chromaRange: 0,
            luminanceRange: 0
        )
        let afterFirst = ColorCubeEngine.pointColorValue(input, adjustments: [first])
        let second = PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: reference.hue,
            luminanceShift: 0.4,
            variance: -0.8,
            range: 0,
            hueRange: 0,
            chromaRange: 0,
            luminanceRange: 0
        )
        let combined = ColorCubeEngine.pointColorValue(input, adjustments: [first, second])
        let chained = ColorCubeEngine.pointColorValue(afterFirst, adjustments: [second])
        let combinedReference = ColorCubeEngine.pointColorReference(
            red: combined.x, green: combined.y, blue: combined.z)
        let firstReference = ColorCubeEngine.pointColorReference(
            red: afterFirst.x, green: afterFirst.y, blue: afterFirst.z)
        #expect(combinedReference.luminance > firstReference.luminance + 0.02)
        #expect(abs(combined.x - chained.x) + abs(combined.y - chained.y)
            + abs(combined.z - chained.z) > 0.01)
        let reversed = ColorCubeEngine.pointColorValue(input, adjustments: [second, first])
        #expect(abs(combined.x - reversed.x) + abs(combined.y - reversed.y)
            + abs(combined.z - reversed.z) > 0.01)

        let ignoredNinth = Array(repeating: PointColorAdjustment(), count: 8) + [first]
        #expect(ColorCubeEngine.pointColorValue(input, adjustments: ignoredNinth) == input)
    }
}

struct SelectiveAlgorithmTests {

    @Test func normalizedCoordinatesFlipTopLeftYAndScaleVectorsAndRadius() throws {
        let space = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 10, y: 20, width: 200, height: 100)))
        let point = space.point(NormalizedPoint(x: 0.25, y: 0.2))
        #expect(abs(point.x - 60) < 0.000_001)
        #expect(abs(point.y - 100) < 0.000_001)

        let vector = space.vector(NormalizedVector(dx: 0.1, dy: 0.2))
        #expect(abs(vector.dx - 20) < 0.000_001)
        #expect(abs(vector.dy + 20) < 0.000_001)
        #expect(abs(space.longEdgeRadius(0.25) - 50) < 0.000_001)

        let large = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 0, y: 0, width: 4_000, height: 2_000)))
        #expect(large.rasterSize() == ImageCoordinateSpace.RasterSize(
            width: 2_048, height: 1_024))
        #expect(large.rasterSize(
            maxLongEdge: .max,
            maximumPixelCount: 1
        ) == ImageCoordinateSpace.RasterSize(width: 1, height: 1))
    }

    @Test func maskRasterWorkIsBoundedAndEmptyBrushComponentsAreSkipped() throws {
        let extent = CGRect(x: 0, y: 0, width: 8_000, height: 8_000)
        #expect(MaskRasterizer.maskBaseWorkUnitCount == 4)
        #expect(MaskRasterizer.scalarComponentWorkUnitCount == 3)
        #expect(MaskRasterizer.brushComponentWorkUnitCount == 2)
        #expect(MaskRasterizer.brushStrokeWorkUnitCount == 2)
        #expect(MaskRasterizer.componentInversionWorkUnitCount == 1)
        #expect(MaskRasterizer.pathMaskWorkUnitCount == 5)
        #expect(MaskRasterizer.ellipseMaskWorkUnitCount == 4)

        let linear = MaskComponent(shape: .linear(
            start: NormalizedPoint(x: 0, y: 0),
            end: NormalizedPoint(x: 1, y: 1)
        ))
        let simpleMask = LocalMask(components: [linear])
        let simple = try #require(MaskRasterizer.rasterPlan(
            for: simpleMask, extent: extent))
        #expect(simple.size.width < MaskRasterizer.maximumLongEdge)
        #expect(simple.size.height < MaskRasterizer.maximumLongEdge)
        #expect(simple.workUnitCount == 7)
        #expect(simple.brushStrokeCount == 0)
        #expect(simple.scalarPixelWork
            == simple.size.width * simple.size.height * simple.workUnitCount)
        #expect(simple.scalarPixelWork <= MaskRasterizer.maximumStageScalarPixelWork)

        let inverted = try #require(MaskRasterizer.rasterPlan(
            for: LocalMask(components: [MaskComponent(
                inverted: true,
                shape: linear.shape
            )]),
            extent: extent
        ))
        #expect(inverted.workUnitCount == simple.workUnitCount + 1)

        let components = Array(repeating: linear, count: LocalMask.maximumComponentCount)
        let compoundMask = LocalMask(components: components)
        let compound = try #require(MaskRasterizer.rasterPlan(
            for: compoundMask, extent: extent))
        #expect(compound.workUnitCount == MaskRasterizer.maskBaseWorkUnitCount
            + LocalMask.maximumComponentCount
                * MaskRasterizer.scalarComponentWorkUnitCount)
        #expect(compound.size.width < simple.size.width)
        #expect(compound.scalarPixelWork <= MaskRasterizer.maximumStageScalarPixelWork)

        let strokes = (0..<MaskShape.maximumStrokeCount).map { index in
            BrushStroke(points: [NormalizedPoint(
                x: Double(index % 16) / 16,
                y: Double(index / 16) / 8
            )])
        }
        let brush = try #require(MaskRasterizer.rasterPlan(
            for: LocalMask(components: [MaskComponent(shape: .brush(strokes: strokes))]),
            extent: extent
        ))
        #expect(brush.workUnitCount == MaskRasterizer.maskBaseWorkUnitCount
            + MaskRasterizer.brushComponentWorkUnitCount
            + MaskShape.maximumStrokeCount * MaskRasterizer.brushStrokeWorkUnitCount)
        #expect(brush.brushStrokeCount == MaskShape.maximumStrokeCount)
        #expect(brush.scalarPixelWork <= MaskRasterizer.maximumStageScalarPixelWork)
        #expect(brush.size.width < compound.size.width)

        let spotPlan = try #require(MaskRasterizer.stageRasterPlan(
            workUnitCounts: Array(
                repeating: MaskRasterizer.pathMaskWorkUnitCount,
                count: SpotCorrection.maximumCount
            )
        ))
        #expect(spotPlan.workUnitCount
            == SpotCorrection.maximumCount * MaskRasterizer.pathMaskWorkUnitCount)
        #expect(spotPlan.plannedScalarPixelWork
            <= MaskRasterizer.maximumStageScalarPixelWork)
        let spotBudget = try #require(spotPlan.scalarPixelBudget(
            for: MaskRasterizer.pathMaskWorkUnitCount
        ))
        let spotRaster = try #require(MaskRasterizer.scalarRasterPlan(
            extent: extent,
            workUnitCount: MaskRasterizer.pathMaskWorkUnitCount,
            maximumScalarPixelWork: spotBudget
        ))
        #expect(spotRaster.scalarPixelWork * SpotCorrection.maximumCount
            <= MaskRasterizer.maximumStageScalarPixelWork)

        let redEyePlan = try #require(MaskRasterizer.stageRasterPlan(
            workUnitCounts: Array(
                repeating: MaskRasterizer.ellipseMaskWorkUnitCount * 2,
                count: RedEyeCorrection.maximumCount
            )
        ))
        #expect(redEyePlan.workUnitCount
            == RedEyeCorrection.maximumCount * MaskRasterizer.ellipseMaskWorkUnitCount * 2)
        #expect(redEyePlan.plannedScalarPixelWork
            <= MaskRasterizer.maximumStageScalarPixelWork)
        let ellipseBudget = try #require(redEyePlan.scalarPixelBudget(
            for: MaskRasterizer.ellipseMaskWorkUnitCount
        ))
        let ellipseRaster = try #require(MaskRasterizer.scalarRasterPlan(
            extent: extent,
            workUnitCount: MaskRasterizer.ellipseMaskWorkUnitCount,
            maximumScalarPixelWork: ellipseBudget
        ))
        #expect(ellipseRaster.scalarPixelWork * RedEyeCorrection.maximumCount * 2
            <= MaskRasterizer.maximumStageScalarPixelWork)

        let localWork = Array(
            repeating: compound.workUnitCount,
            count: LocalMask.maximumCount
        )
        let localPlan = try #require(MaskRasterizer.stageRasterPlan(
            workUnitCounts: localWork
        ))
        var aggregateLocalWork = 0
        for workUnitCount in localWork {
            let budget = try #require(localPlan.scalarPixelBudget(for: workUnitCount))
            let item = try #require(MaskRasterizer.rasterPlan(
                for: compoundMask,
                extent: extent,
                maximumScalarPixelWork: budget
            ))
            aggregateLocalWork += item.scalarPixelWork
        }
        #expect(aggregateLocalWork <= MaskRasterizer.maximumStageScalarPixelWork)
        #expect(MaskRasterizer.stageRasterPlan(workUnitCounts: [Int.max, 1]) == nil)

        let empty = LocalMask(
            inverted: true,
            components: [MaskComponent(shape: .brush(strokes: [BrushStroke()]))],
            adjustments: LocalAdjustments(exposure: 1)
        )
        #expect(MaskRasterizer.rasterPlan(for: empty, extent: extent) == nil)
        #expect(MaskRasterizer.mask(for: empty, extent: extent) == nil)
    }

    @Test func brushPixelVisitsAreBoundedAcrossWholeStages() throws {
        let extent = CGRect(x: 0, y: 0, width: 8_000, height: 8_000)
        #expect(MaskRasterizer.maximumStageBrushPixelVisits == 16_777_216)

        let pointsPerSpot = SelectiveDevelopLimits.maximumTotalPathPoints
            / SpotCorrection.maximumCount
        #expect(pointsPerSpot * SpotCorrection.maximumCount
            == SelectiveDevelopLimits.maximumTotalPathPoints)
        let spotPath = (0..<pointsPerSpot).map { index in
            index.isMultiple(of: 2)
                ? NormalizedPoint(x: 0, y: 0)
                : NormalizedPoint(x: 1, y: 1)
        }
        let spotScalarStage = try #require(MaskRasterizer.stageRasterPlan(
            workUnitCounts: Array(
                repeating: MaskRasterizer.pathMaskWorkUnitCount,
                count: SpotCorrection.maximumCount
            )
        ))
        let spotScalarBudget = try #require(spotScalarStage.scalarPixelBudget(
            for: MaskRasterizer.pathMaskWorkUnitCount
        ))
        let spotRaster = try #require(MaskRasterizer.scalarRasterPlan(
            extent: extent,
            workUnitCount: MaskRasterizer.pathMaskWorkUnitCount,
            maximumScalarPixelWork: spotScalarBudget
        ))
        let spotBrushStage = try #require(MaskRasterizer.stageBrushPlan(
            pathCounts: Array(repeating: 1, count: SpotCorrection.maximumCount)
        ))
        #expect(spotBrushStage.pathCount == SpotCorrection.maximumCount)
        #expect(spotBrushStage.maximumPixelVisitsPerPath == 65_536)
        #expect(spotBrushStage.plannedPixelVisits
            == MaskRasterizer.maximumStageBrushPixelVisits)

        let spotPixelPath = spotPath.map {
            CGPoint(
                x: $0.x * Double(spotRaster.size.width),
                y: $0.y * Double(spotRaster.size.height)
            )
        }
        let spotRadius = 0.25 * Double(max(
            spotRaster.size.width,
            spotRaster.size.height
        ))
        var aggregateSpotVisits = 0
        var independentlyCappedSpotVisits = 0
        for _ in 0..<SpotCorrection.maximumCount {
            let stagePlan = try #require(MaskMath.brushDabPlan(
                points: spotPixelPath,
                radius: spotRadius,
                width: spotRaster.size.width,
                height: spotRaster.size.height,
                maximumPixelVisits: spotBrushStage.maximumPixelVisitsPerPath
            ))
            aggregateSpotVisits += stagePlan.pixelVisitCount
            let independentPlan = try #require(MaskMath.brushDabPlan(
                points: spotPixelPath,
                radius: spotRadius,
                width: spotRaster.size.width,
                height: spotRaster.size.height,
                maximumPixelVisits: MaskMath.maximumBrushPixelVisitCount
            ))
            independentlyCappedSpotVisits += independentPlan.pixelVisitCount
        }
        #expect(aggregateSpotVisits <= MaskRasterizer.maximumStageBrushPixelVisits)
        #expect(independentlyCappedSpotVisits
            > MaskRasterizer.maximumStageBrushPixelVisits)

        let pointsPerStroke = SelectiveDevelopLimits.maximumTotalPathPoints
            / MaskShape.maximumStrokeCount
        #expect(pointsPerStroke * MaskShape.maximumStrokeCount
            == SelectiveDevelopLimits.maximumTotalPathPoints)
        let strokePath = (0..<pointsPerStroke).map { index in
            index.isMultiple(of: 2)
                ? NormalizedPoint(x: 0, y: 0)
                : NormalizedPoint(x: 1, y: 1)
        }
        let strokes = Array(
            repeating: BrushStroke(points: strokePath, size: 0.25),
            count: MaskShape.maximumStrokeCount
        )
        let localMask = LocalMask(components: [MaskComponent(shape: .brush(strokes: strokes))])
        let localWorkUnitCount = try #require(MaskRasterizer.workUnitCount(for: localMask))
        let localStrokeCount = try #require(MaskRasterizer.brushStrokeCount(for: localMask))
        #expect(localStrokeCount == MaskShape.maximumStrokeCount)
        let localScalarStage = try #require(MaskRasterizer.stageRasterPlan(
            workUnitCounts: [localWorkUnitCount]
        ))
        let localScalarBudget = try #require(localScalarStage.scalarPixelBudget(
            for: localWorkUnitCount
        ))
        let localRaster = try #require(MaskRasterizer.rasterPlan(
            for: localMask,
            extent: extent,
            maximumScalarPixelWork: localScalarBudget
        ))
        let localBrushStage = try #require(MaskRasterizer.stageBrushPlan(
            pathCounts: [localStrokeCount]
        ))
        #expect(localBrushStage.maximumPixelVisitsPerPath == 131_072)
        #expect(localBrushStage.plannedPixelVisits
            == MaskRasterizer.maximumStageBrushPixelVisits)

        let strokePixelPath = strokePath.map {
            CGPoint(
                x: $0.x * Double(localRaster.size.width),
                y: $0.y * Double(localRaster.size.height)
            )
        }
        let strokeRadius = 0.25 * Double(max(
            localRaster.size.width,
            localRaster.size.height
        ))
        var aggregateLocalVisits = 0
        var independentlyCappedLocalVisits = 0
        for _ in strokes {
            let stagePlan = try #require(MaskMath.brushDabPlan(
                points: strokePixelPath,
                radius: strokeRadius,
                width: localRaster.size.width,
                height: localRaster.size.height,
                maximumPixelVisits: localBrushStage.maximumPixelVisitsPerPath
            ))
            aggregateLocalVisits += stagePlan.pixelVisitCount
            let independentPlan = try #require(MaskMath.brushDabPlan(
                points: strokePixelPath,
                radius: strokeRadius,
                width: localRaster.size.width,
                height: localRaster.size.height,
                maximumPixelVisits: MaskMath.maximumBrushPixelVisitCount
            ))
            independentlyCappedLocalVisits += independentPlan.pixelVisitCount
        }
        #expect(aggregateLocalVisits <= MaskRasterizer.maximumStageBrushPixelVisits)
        #expect(independentlyCappedLocalVisits
            > MaskRasterizer.maximumStageBrushPixelVisits)
    }

    @Test func maskRasterStoresLinearScalarAlpha() throws {
        let extent = CGRect(x: 0, y: 0, width: 255, height: 1)
        let localMask = LocalMask(components: [MaskComponent(shape: .linear(
            start: NormalizedPoint(x: 0, y: 0.5),
            end: NormalizedPoint(x: 1, y: 0.5)
        ))])
        let mask = try #require(MaskRasterizer.mask(for: localMask, extent: extent))
        #expect(mask.colorSpace?.name == CGColorSpace.linearGray)
        let linearRGB = try #require(CGColorSpace(name: CGColorSpace.linearSRGB))
        var samples = [UInt8](repeating: 0, count: 255 * 4)
        samples.withUnsafeMutableBytes { bytes in
            CIContext(options: [.useSoftwareRenderer: true]).render(
                mask,
                toBitmap: bytes.baseAddress!,
                rowBytes: 255 * 4,
                bounds: extent,
                format: .RGBA8,
                colorSpace: linearRGB
            )
        }
        #expect(abs(Int(samples[63 * 4]) - 40) <= 2)
        #expect(abs(Int(samples[127 * 4]) - 128) <= 1)
        #expect(abs(Int(samples[191 * 4]) - 216) <= 2)
    }

    @Test func maskComponentsUseDocumentedAddSubtractAndIntersectMath() {
        #expect(MaskMath.combine(0.3, with: 0.7, operation: .add) == 0.7)
        #expect(abs(MaskMath.combine(0.8, with: 0.25, operation: .subtract) - 0.6)
            < 0.000_001)
        #expect(abs(MaskMath.combine(0.8, with: 0.25, operation: .intersect) - 0.2)
            < 0.000_001)
        #expect(MaskMath.invertedAlpha(0.2, inverted: true) == 0.8)
    }

    @Test func linearAndRadialMasksHaveStableDirectionFeatherAndInversion() {
        let start = NormalizedPoint(x: 0, y: 0.5)
        let end = NormalizedPoint(x: 1, y: 0.5)
        #expect(MaskMath.linearAlpha(at: start, start: start, end: end) == 0)
        #expect(MaskMath.linearAlpha(at: end, start: start, end: end) == 1)
        #expect(MaskMath.linearAlpha(
            at: NormalizedPoint(x: 0.5, y: 0.5), start: start, end: end) == 0.5)

        let top = NormalizedPoint(x: 0.5, y: 0)
        let bottom = NormalizedPoint(x: 0.5, y: 1)
        #expect(MaskMath.linearAlpha(at: top, start: top, end: bottom) == 0)
        #expect(MaskMath.linearAlpha(at: bottom, start: top, end: bottom) == 1)
        #expect(MaskMath.linearAlpha(
            at: NormalizedPoint(x: 0.5, y: 0.75), start: top, end: bottom) > 0.8)

        let center = NormalizedPoint(x: 0.5, y: 0.5)
        let centerAlpha = MaskMath.radialAlpha(
            at: center, center: center,
            radiusX: 0.25, radiusY: 0.2, feather: 0.5)
        let edgeAlpha = MaskMath.radialAlpha(
            at: NormalizedPoint(x: 0.75, y: 0.5), center: center,
            radiusX: 0.25, radiusY: 0.2, feather: 0.5)
        #expect(centerAlpha == 1)
        #expect(edgeAlpha == 0)
        #expect(MaskMath.radialAlpha(
            at: center, center: center,
            radiusX: 0.25, radiusY: 0.2, feather: 0.5, inverted: true) == 0)

        let downRight = MaskMath.radialAlpha(
            at: NormalizedPoint(x: 0.65, y: 0.65), center: center,
            radiusX: 0.3, radiusY: 0.08, angleDegrees: 45, feather: 0.2)
        let upRight = MaskMath.radialAlpha(
            at: NormalizedPoint(x: 0.65, y: 0.35), center: center,
            radiusX: 0.3, radiusY: 0.08, angleDegrees: 45, feather: 0.2)
        #expect(downRight > 0.9)
        #expect(upRight == 0)
    }

    @Test func localAmountScalesEveryParameterAndKeepsNeutralAdjustmentsNeutral() {
        let keyPaths: [WritableKeyPath<LocalAdjustments, Double>] = [
            \LocalAdjustments.temperature, \LocalAdjustments.tint,
            \LocalAdjustments.exposure, \LocalAdjustments.contrast,
            \LocalAdjustments.highlights, \LocalAdjustments.shadows,
            \LocalAdjustments.whites, \LocalAdjustments.blacks,
            \LocalAdjustments.texture, \LocalAdjustments.clarity,
            \LocalAdjustments.dehaze, \LocalAdjustments.hue,
            \LocalAdjustments.saturation, \LocalAdjustments.sharpness,
            \LocalAdjustments.noiseReduction,
        ]
        for keyPath in keyPaths {
            var adjustment = LocalAdjustments(amount: 0.5)
            adjustment[keyPath: keyPath] = 0.4
            let effective = SelectiveAdjustments.effectiveLocalAdjustments(adjustment)
            #expect(abs(effective[keyPath: keyPath] - 0.2) < 0.000_001)
            #expect(effective.amount == 1)

            adjustment.amount = 0
            #expect(SelectiveAdjustments.effectiveLocalAdjustments(adjustment).isIdentity)

            adjustment.amount = 2
            adjustment[keyPath: keyPath] = 0.75
            #expect(SelectiveAdjustments.effectiveLocalAdjustments(adjustment)[keyPath: keyPath]
                == 1)
            adjustment[keyPath: keyPath] = -0.75
            #expect(SelectiveAdjustments.effectiveLocalAdjustments(adjustment)[keyPath: keyPath]
                == -1)
        }

        var neutral = LocalAdjustments()
        neutral.amount = 2
        #expect(SelectiveAdjustments.effectiveLocalAdjustments(neutral).isIdentity)
    }

    @Test func brushDabsRespectSpacingFlowDensityAndErase() throws {
        let centers = MaskMath.brushDabCenters(
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            radius: 20
        )
        #expect(centers.count >= 21)
        for index in 1..<centers.count {
            #expect(hypot(
                Double(centers[index].x - centers[index - 1].x),
                Double(centers[index].y - centers[index - 1].y)
            ) <= 5.000_001)
        }

        let hostilePath = (0...MaskMath.maximumBrushSegmentCount).map { index in
            index.isMultiple(of: 2)
                ? CGPoint(x: 0, y: 0)
                : CGPoint(x: 2_048, y: 2_048)
        }
        let hostilePlan = try #require(MaskMath.brushDabPlan(
            points: hostilePath,
            radius: 2.048,
            width: 2_048,
            height: 2_048
        ))
        #expect(hostilePlan.segmentCount == MaskMath.maximumBrushSegmentCount)
        #expect(hostilePlan.candidateDabCount == MaskMath.maximumBrushDabCount)
        #expect(hostilePlan.dabCount == hostilePlan.candidateDabCount)
        #expect(hostilePlan.pixelVisitCount <= MaskMath.maximumBrushPixelVisitCount)
        var hostileVisits = 0
        var hostileFirstDab: CGPoint?
        var hostileFinalDab: CGPoint?
        let streamedPlan = MaskMath.forEachBrushDabCenter(
            points: hostilePath,
            radius: 2.048,
            width: 2_048,
            height: 2_048
        ) { center in
            hostileFirstDab = hostileFirstDab ?? center
            hostileFinalDab = center
            hostileVisits += MaskMath.brushDabBounds(
                center: center,
                radius: 2.048,
                width: 2_048,
                height: 2_048
            )?.pixelVisitCount ?? 0
        }
        #expect(streamedPlan == hostilePlan)
        #expect(hostileVisits == hostilePlan.pixelVisitCount)
        #expect(hostileFirstDab == hostilePath.first)
        #expect(hostileFinalDab == hostilePath.last)

        let largeRadiusPlan = try #require(MaskMath.brushDabPlan(
            points: hostilePath,
            radius: 512,
            width: 2_048,
            height: 2_048
        ))
        #expect(largeRadiusPlan.dabCount < largeRadiusPlan.candidateDabCount)
        #expect(largeRadiusPlan.pixelVisitCount <= MaskMath.maximumBrushPixelVisitCount)
        var largeRadiusVisits = 0
        var largeRadiusFirstDab: CGPoint?
        var largeRadiusFinalDab: CGPoint?
        let streamedLargeRadiusPlan = MaskMath.forEachBrushDabCenter(
            points: hostilePath,
            radius: 512,
            width: 2_048,
            height: 2_048
        ) { center in
            largeRadiusFirstDab = largeRadiusFirstDab ?? center
            largeRadiusFinalDab = center
            largeRadiusVisits += MaskMath.brushDabBounds(
                center: center,
                radius: 512,
                width: 2_048,
                height: 2_048
            )?.pixelVisitCount ?? 0
        }
        #expect(streamedLargeRadiusPlan == largeRadiusPlan)
        #expect(largeRadiusVisits == largeRadiusPlan.pixelVisitCount)
        #expect(largeRadiusFirstDab == hostilePath.first)
        #expect(largeRadiusFinalDab == hostilePath.last)

        let clippedPath = [CGPoint(x: 0, y: 0), CGPoint(x: 320, y: 80)]
        let clippedPlan = try #require(MaskMath.brushDabPlan(
            points: clippedPath,
            radius: 20,
            width: 320,
            height: 80,
            maximumPixelVisits: 841
        ))
        #expect(MaskMath.brushDabBounds(
            center: clippedPath[0], radius: 20, width: 320, height: 80
        )?.pixelVisitCount == 441)
        #expect(MaskMath.brushDabBounds(
            center: clippedPath[1], radius: 20, width: 320, height: 80
        )?.pixelVisitCount == 400)
        #expect(clippedPlan.dabCount == 2)
        #expect(clippedPlan.pixelVisitCount == clippedPlan.pixelVisitBudget)
        var clippedCenters: [CGPoint] = []
        let streamedClippedPlan = MaskMath.forEachBrushDabCenter(
            points: clippedPath,
            radius: 20,
            width: 320,
            height: 80,
            maximumPixelVisits: 841
        ) { clippedCenters.append($0) }
        #expect(streamedClippedPlan == clippedPlan)
        #expect(clippedCenters == clippedPath)

        let dab = MaskMath.brushDabAlpha(
            distance: 0, radius: 10, feather: 0.5, flow: 0.5, density: 0.4)
        #expect(abs(dab - 0.2) < 0.000_001)
        #expect(abs(MaskMath.accumulateBrushAlpha(0.3, dabAlpha: dab, erase: false) - 0.44)
            < 0.000_001)
        #expect(abs(MaskMath.accumulateBrushAlpha(0.3, dabAlpha: dab, erase: true) - 0.24)
            < 0.000_001)

        let repeated = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)]
        #expect(abs(MaskMath.brushPathAlpha(
            at: CGPoint(x: 5, y: 5), dabCenters: repeated,
            radius: 10, feather: 0.5, flow: 0.5, density: 0.4
        ) - 0.3) < 0.000_001)
        #expect(abs(MaskMath.brushPathAlpha(
            at: CGPoint(x: 5, y: 5), dabCenters: repeated,
            radius: 10, feather: 0.5, flow: 0.5, density: 0.4,
            initialAlpha: 0.8, erase: true
        ) - 0.56) < 0.000_001)

        let manyOverlaps = Array(repeating: CGPoint(x: 5, y: 5), count: 100)
        let capped = MaskMath.brushPathAlpha(
            at: CGPoint(x: 5, y: 5),
            dabCenters: manyOverlaps,
            radius: 10,
            feather: 0.5,
            flow: 0.5,
            density: 0.4
        )
        #expect(capped <= 0.4)
        #expect(capped > 0.39)
    }

    @Test func spotSourceOffsetTranslatesSourceOntoTargetAndPathAlphaIsFeathered() throws {
        let space = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let translation = SpotMath.sourceTranslation(
            sourceOffset: NormalizedVector(dx: 0.1, dy: 0.2),
            in: space
        )
        #expect(abs(translation.dx + 20) < 0.000_001)
        #expect(abs(translation.dy - 20) < 0.000_001)

        let path = [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10)]
        let center = SpotMath.pathAlpha(
            at: CGPoint(x: 20, y: 10), path: path,
            radius: 8, feather: 0.5, opacity: 0.75)
        let outside = SpotMath.pathAlpha(
            at: CGPoint(x: 20, y: 30), path: path,
            radius: 8, feather: 0.5, opacity: 0.75)
        #expect(center > 0.7)
        #expect(center <= 0.75)
        #expect(outside == 0)
        let overlappingSpot = SpotMath.pathAlpha(
            at: CGPoint(x: 10, y: 10),
            path: Array(repeating: CGPoint(x: 10, y: 10), count: 20),
            radius: 8,
            feather: 0.5,
            opacity: 0.35
        )
        #expect(abs(overlappingSpot - 0.35) < 0.000_001)

        let widePath = [
            NormalizedPoint(x: 0.2, y: 0.5),
            NormalizedPoint(x: 0.8, y: 0.5),
        ]
        let fallback = try #require(SpotMath.defaultSourceOffset(
            points: widePath, normalizedRadius: 0.1, in: space))
        let radiusX = 0.1
        let radiusY = 0.2
        for point in widePath {
            #expect(point.x + fallback.dx - radiusX >= -0.000_001)
            #expect(point.x + fallback.dx + radiusX <= 1.000_001)
            #expect(point.y + fallback.dy - radiusY >= -0.000_001)
            #expect(point.y + fallback.dy + radiusY <= 1.000_001)
        }

        let boundedPoint = [NormalizedPoint(x: 0.2, y: 0.2)]
        #expect(SpotMath.sourceSamplesAreInBounds(
            points: boundedPoint,
            sourceOffset: NormalizedVector(dx: -0.1, dy: 0),
            normalizedRadius: 0.05,
            in: space
        ))
        #expect(!SpotMath.sourceSamplesAreInBounds(
            points: boundedPoint,
            sourceOffset: NormalizedVector(dx: -0.2, dy: 0),
            normalizedRadius: 0.05,
            in: space
        ))
        var invalidPoint = NormalizedPoint(x: 0.5, y: 0.5)
        invalidPoint.x = .nan
        #expect(!SpotMath.hasValidTargetPath([invalidPoint]))
    }

    @Test func defaultSpotSourceOffsetHandlesImageEdges() throws {
        let space = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let cases: [(point: NormalizedPoint, expected: NormalizedVector)] = [
            (NormalizedPoint(x: 0.02, y: 0.5), NormalizedVector(dx: 0.25, dy: 0)),
            (NormalizedPoint(x: 0.98, y: 0.5), NormalizedVector(dx: -0.25, dy: 0)),
            (NormalizedPoint(x: 0.5, y: 0.05), NormalizedVector(dx: 0, dy: 0.5)),
            (NormalizedPoint(x: 0.5, y: 0.95), NormalizedVector(dx: 0, dy: -0.5)),
        ]

        for item in cases {
            let points = [item.point]
            let offset = try #require(SpotMath.defaultSourceOffset(
                points: points,
                normalizedRadius: 0.1,
                in: space
            ))
            #expect(abs(offset.dx - item.expected.dx) < 0.000_001)
            #expect(abs(offset.dy - item.expected.dy) < 0.000_001)
            #expect(SpotMath.sourceSamplesAreInBounds(
                points: points,
                sourceOffset: offset,
                normalizedRadius: 0.1,
                in: space
            ))
        }
    }

    @Test func defaultSpotSourceOffsetUsesDeterministicCornerDiagonals() throws {
        let space = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let cases: [(point: NormalizedPoint, expected: NormalizedVector)] = [
            (NormalizedPoint(x: 0.02, y: 0.05), NormalizedVector(dx: 0.25, dy: 0.5)),
            (NormalizedPoint(x: 0.98, y: 0.95), NormalizedVector(dx: -0.25, dy: -0.5)),
        ]

        for item in cases {
            let points = [item.point]
            let offset = try #require(SpotMath.defaultSourceOffset(
                points: points,
                normalizedRadius: 0.1,
                in: space
            ))
            #expect(abs(offset.dx - item.expected.dx) < 0.000_001)
            #expect(abs(offset.dy - item.expected.dy) < 0.000_001)
            #expect(SpotMath.sourceSamplesAreInBounds(
                points: points,
                sourceOffset: offset,
                normalizedRadius: 0.1,
                in: space
            ))
        }
    }

    @Test func defaultSpotSourceOffsetUsesShortDiagonalInNarrowImages() throws {
        let narrow = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 0, y: 0, width: 40, height: 200)))
        let points = [NormalizedPoint(x: 0.1, y: 0.05)]
        let offset = try #require(SpotMath.defaultSourceOffset(
            points: points,
            normalizedRadius: 0.1,
            in: narrow
        ))
        #expect(abs(offset.dx - 0.4) < 0.000_001)
        #expect(abs(offset.dy - 0.25) < 0.000_001)
        #expect(SpotMath.sourceSamplesAreInBounds(
            points: points,
            sourceOffset: offset,
            normalizedRadius: 0.1,
            in: narrow
        ))

        let tooNarrow = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 0, y: 0, width: 39, height: 200)))
        #expect(SpotMath.defaultSourceOffset(
            points: points,
            normalizedRadius: 0.1,
            in: tooNarrow
        ) == nil)
    }

    @Test func defaultSpotSourceOffsetSkipsZeroFallbackForShortVerticalMove() throws {
        let space = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 0, y: 0, width: 200, height: 100)))
        let horizontalPath = [
            NormalizedPoint(x: 0.125, y: 0.375),
            NormalizedPoint(x: 0.875, y: 0.375),
        ]
        let offset = try #require(SpotMath.defaultSourceOffset(
            points: horizontalPath,
            normalizedRadius: 0.125,
            in: space
        ))
        #expect(offset.dx == 0)
        #expect(offset.dy == 0.375)
        #expect(SpotMath.sourceSamplesAreInBounds(
            points: horizontalPath,
            sourceOffset: offset,
            normalizedRadius: 0.125,
            in: space
        ))

        let noMovementPossible = [
            NormalizedPoint(x: 0.125, y: 0.25),
            NormalizedPoint(x: 0.875, y: 0.75),
        ]
        #expect(SpotMath.defaultSourceOffset(
            points: noMovementPossible,
            normalizedRadius: 0.125,
            in: space
        ) == nil)
    }

    @Test func redDominanceRejectsNeutralAndNonRedPixels() {
        #expect(RedEyeMath.redDominance(red: 0.9, green: 0.2, blue: 0.15) > 0.9)
        #expect(RedEyeMath.redDominance(red: 0.5, green: 0.5, blue: 0.5) == 0)
        #expect(RedEyeMath.redDominance(red: 0.2, green: 0.7, blue: 0.1) == 0)
    }

    @Test func redEyeGeometryUsesTopLeftNormalizedAxesAndPixelRoundCatchlights() throws {
        let space = try #require(ImageCoordinateSpace(
            extent: CGRect(x: 10, y: 20, width: 400, height: 200)))
        let correction = RedEyeCorrection(
            center: NormalizedPoint(x: 0.4, y: 0.3),
            radiusX: 0.1,
            radiusY: 0.2,
            pupilSize: 1,
            darken: 0.8,
            petEye: true,
            catchlight: NormalizedVector(dx: 0.04, dy: 0.08)
        )
        let pupil = try #require(RedEyeMath.pupilEllipse(for: correction, in: space))
        let catchlight = try #require(RedEyeMath.catchlightEllipse(
            for: correction, pupil: pupil, in: space))
        #expect(abs(catchlight.center.x - 0.44) < 0.000_001)
        #expect(abs(catchlight.center.y - 0.38) < 0.000_001)
        #expect(RedEyeMath.contains(catchlight.center, in: pupil))
        #expect(abs(catchlight.radiusX * 400 - catchlight.radiusY * 200) < 0.000_001)
        let pixelCenter = space.point(catchlight.center)
        #expect(abs(pixelCenter.x - 186) < 0.000_001)
        #expect(abs(pixelCenter.y - 144) < 0.000_001)

        var outside = correction
        outside.catchlight = NormalizedVector(dx: 0.11, dy: 0)
        #expect(RedEyeMath.catchlightEllipse(for: outside, pupil: pupil, in: space) == nil)
        outside.center.y = 2
        #expect(RedEyeMath.pupilEllipse(for: outside, in: space) == nil)
    }

    @Test func rgbReplacementPreservesReferenceAlpha() throws {
        let extent = CGRect(x: 0, y: 0, width: 1, height: 1)
        let replacement = CIImage(color: CIColor(
            red: 1, green: 1, blue: 1, alpha: 1
        )).cropped(to: extent)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.linearSRGB))
        let context = CIContext(options: [.useSoftwareRenderer: true])

        for alpha in [0.0, 0.25, 1.0] {
            let original = CIImage(color: CIColor(
                red: 0.1, green: 0.2, blue: 0.3, alpha: alpha
            )).cropped(to: extent)
            let result = SelectiveAdjustments.replacingRGB(
                replacement,
                preservingAlphaOf: original,
                extent: extent
            )
            var sample = [UInt8](repeating: 0, count: 4)
            sample.withUnsafeMutableBytes { bytes in
                context.render(
                    result,
                    toBitmap: bytes.baseAddress!,
                    rowBytes: 4,
                    bounds: extent,
                    format: .RGBA8,
                    colorSpace: colorSpace
                )
            }
            #expect(abs(Int(sample[3]) - Int((alpha * 255).rounded())) <= 1)
        }
    }

    @Test func healRemoveAndCatchlightsDoNotCreateOpaqueIslands() throws {
        let extent = CGRect(x: 0, y: 0, width: 32, height: 16)
        let transparent = CIImage(color: CIColor(
            red: 0.2, green: 0.3, blue: 0.4, alpha: 0
        )).cropped(to: extent)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.linearSRGB))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        func maximumAlpha(_ image: CIImage) -> UInt8 {
            var samples = [UInt8](repeating: 0, count: 32 * 16 * 4)
            samples.withUnsafeMutableBytes { bytes in
                context.render(
                    image,
                    toBitmap: bytes.baseAddress!,
                    rowBytes: 32 * 4,
                    bounds: extent,
                    format: .RGBA8,
                    colorSpace: colorSpace
                )
            }
            return stride(from: 3, to: samples.count, by: 4).map { samples[$0] }.max() ?? 0
        }

        func alpha(_ image: CIImage, at point: CGPoint) -> UInt8 {
            var sample = [UInt8](repeating: 0, count: 4)
            sample.withUnsafeMutableBytes { bytes in
                context.render(
                    image,
                    toBitmap: bytes.baseAddress!,
                    rowBytes: 4,
                    bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: colorSpace
                )
            }
            return sample[3]
        }

        for mode in [SpotMode.heal, .remove] {
            let spot = SpotCorrection(
                mode: mode,
                points: [NormalizedPoint(x: 0.5, y: 0.5)],
                size: 0.05,
                sourceOffset: NormalizedVector(dx: 0.2, dy: 0)
            )
            #expect(maximumAlpha(SelectiveAdjustments.applySpots([spot], to: transparent)) == 0)
        }

        let opaqueSource = CIImage(color: CIColor(
            red: 0.9, green: 0.1, blue: 0.1, alpha: 1
        )).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
            .composited(over: transparent)
        let clone = SpotCorrection(
            mode: .clone,
            points: [NormalizedPoint(x: 0.75, y: 0.5)],
            size: 0.1,
            sourceOffset: NormalizedVector(dx: -0.5, dy: 0)
        )
        let cloned = SelectiveAdjustments.applySpots([clone], to: opaqueSource)
        #expect(alpha(cloned, at: CGPoint(x: 24, y: 8)) == 0)

        let petEye = RedEyeCorrection(
            center: NormalizedPoint(x: 0.5, y: 0.5),
            radiusX: 0.2,
            radiusY: 0.2,
            pupilSize: 1,
            petEye: true,
            catchlight: NormalizedVector(dx: 0, dy: 0)
        )
        #expect(maximumAlpha(SelectiveAdjustments.applyRedEyes([petEye], to: transparent)) == 0)
    }
}

struct ImagingControlMappingTests {

    @Test func rawDetailMappingUsesDetailContrastAndColorControls() {
        var low = DevelopSettings()
        low.sharpness = 0.8
        low.noiseReduction = 0.7
        low.colorNoiseReduction = 0.7
        low.sharpenDetail = 0
        low.noiseReductionDetail = 0
        low.colorNoiseReductionDetail = 0
        low.colorNoiseReductionSmoothness = 0

        var high = low
        high.sharpenDetail = 1
        high.noiseReductionDetail = 1
        high.noiseReductionContrast = 1
        high.colorNoiseReductionDetail = 1
        high.colorNoiseReductionSmoothness = 1

        let a = RawDetailMapping.values(for: low)
        let b = RawDetailMapping.values(for: high)
        #expect(b.detail > a.detail)
        #expect(b.contrast > a.contrast)
        #expect(b.luminanceNoise < a.luminanceNoise)
        #expect(b.colorNoise != a.colorNoise)
    }

    @Test func opticsProfilesMultiplyManualCorrectionsAndCASigns() {
        var settings = DevelopSettings()
        settings.opticsDistortion = 0.8
        settings.opticsVignetting = -0.6
        settings.opticsCARed = 1
        settings.opticsCABlue = -1
        let full = CoreImageAdjustments.opticsParameters(for: settings)
        #expect(full.distortionScale < 0)
        #expect(full.vignetteIntensity > 0)
        #expect(full.redChannelScale < 1)
        #expect(full.blueChannelScale > 1)

        settings.opticsProfileDistortion = 0
        settings.opticsProfileVignetting = 0
        let disabled = CoreImageAdjustments.opticsParameters(for: settings)
        #expect(disabled.distortionScale == 0)
        #expect(disabled.vignetteIntensity == 0)
    }

    @Test func grainVignetteAndGeometryShapeControlsMapMaterially() {
        let fine = CoreImageAdjustments.grainParameters(amount: 0.8, size: 0, roughness: 0)
        let coarse = CoreImageAdjustments.grainParameters(amount: 0.8, size: 1, roughness: 1)
        #expect(coarse.coarseScale > fine.coarseScale)
        #expect(coarse.fineMix > fine.fineMix)

        let extent = CGRect(x: 0, y: 0, width: 600, height: 400)
        let square = CoreImageAdjustments.vignetteGeometry(
            extent: extent, midpoint: 0, roundness: -1, feather: 0)
        let round = CoreImageAdjustments.vignetteGeometry(
            extent: extent, midpoint: 1, roundness: 1, feather: 1)
        #expect(round.innerRect.width > square.innerRect.width)
        #expect(round.cornerRadius > square.cornerRadius)
        #expect(round.blurRadius > square.blurRadius)

        let corners = CoreImageAdjustments.geometryPerspectiveCorners(
            extent: extent, vertical: 0.8, horizontal: -0.6)
        #expect(corners.topLeft.x > extent.minX)
        #expect(corners.bottomLeft.x < extent.minX)
        #expect(corners.topLeft.y > extent.maxY)
        #expect(corners.topRight.y < extent.maxY)
    }
}

struct ContentDigestTests {

    @Test func digestOfKnownFileIsStableAndHex() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("digest-\(UUID().uuidString).bin")
        try Data("RawLight".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let d1 = try ContentDigest.sha256(of: url)
        let d2 = try ContentDigest.sha256(of: url)
        #expect(d1 == d2)
        #expect(d1.hasPrefix("sha256:"))
        // "RawLight" has a known SHA-256.
        #expect(d1 == "sha256:" + "RawLight".data(using: .utf8)!.sha256HexForTest)
    }

    @Test func digestOfMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.bin")
        #expect(throws: (any Error).self) {
            try ContentDigest.sha256(of: url)
        }
    }
}

struct ImageFingerprintTests {

    @Test func exactHeaderHashMatchIsExact() {
        let a = ImageFingerprint(filename: "a.raf", fileSizeBytes: 100, captureDate: nil, headerHash: "abc")
        let b = ImageFingerprint(filename: "b.raf", fileSizeBytes: 100, captureDate: nil, headerHash: "abc")
        #expect(a.match(b) == .exact)
    }

    @Test func sameNameSizeDateIsStrong() {
        let date = Date(timeIntervalSince1970: 1000)
        let a = ImageFingerprint(filename: "x.raf", fileSizeBytes: 100, captureDate: date)
        let b = ImageFingerprint(filename: "x.raf", fileSizeBytes: 100, captureDate: date)
        #expect(a.match(b) == .strong)
    }

    @Test func sameNameAndSizeWithoutCaptureDateIsOnlyWeak() {
        let a = ImageFingerprint(filename: "x.raf", fileSizeBytes: 100)
        let b = ImageFingerprint(filename: "x.raf", fileSizeBytes: 100)
        #expect(a.match(b) == .weak)
    }

    @Test func unrelatedIsNoMatch() {
        let a = ImageFingerprint(filename: "x.raf", fileSizeBytes: 100, captureDate: Date(timeIntervalSince1970: 1))
        let b = ImageFingerprint(filename: "y.raf", fileSizeBytes: 200, captureDate: Date(timeIntervalSince1970: 2))
        #expect(a.match(b) == .none)
    }
}

// Small helper mirroring ContentDigest for the known-answer test.
import CryptoKit
extension Data {
    var sha256HexForTest: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

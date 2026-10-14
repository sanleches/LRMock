//
//  DevelopSettingsTests.swift
//  LRMockTests
//
//  Unit tests for the develop recipe value type: identity/reset semantics,
//  Codable round-trips, and — critically — the lenient backward-compatible
//  decoder that lets old sidecars keep decoding after new fields are added.
//

import Testing
import Foundation
@testable import LRMock

struct DevelopSettingsTests {

    @Test func defaultIsIdentity() {
        let s = DevelopSettings()
        #expect(s.schemaVersion == 6)
        #expect(s.isIdentity)
        #expect(s.isCurveLinear)
        #expect(s.isFullFrame)
        #expect(!s.hasGeometry)
        #expect(s.grade.isIdentity)
        #expect(s.profileAmount == 1)
        #expect(s.curveSplitShadows == 0.25)
        #expect(s.curveSplitMid == 0.5)
        #expect(s.curveSplitHighlights == 0.75)
        #expect(s.curveRefineSaturation == 1)
        #expect(s.geometryScale == 1)
        #expect(s.pointColors.isEmpty)
        #expect(s.masks.isEmpty)
        #expect(s.spots.isEmpty)
        #expect(s.redEyes.isEmpty)
    }

    @Test func editedIsNotIdentity() {
        var s = DevelopSettings()
        s.curveLights = 0.3
        #expect(!s.isIdentity)

        s.reset()
        s.grade.globalLum = 0.2
        #expect(!s.isIdentity)
        #expect(!s.grade.isIdentity)

        s.reset()
        s.opticsDistortion = -0.2
        #expect(!s.isIdentity)

        s.reset()
        s.pointColors = [PointColorAdjustment()]
        #expect(s.pointColors[0].isIdentity)
        #expect(!s.isIdentity)
    }

    @Test func resetRestoresIdentityButKeepsSchema() {
        var s = DevelopSettings()
        s.profileAmount = 1.5; s.curveHighlights = 0.4; s.bwOrange = -0.3
        s.grade.globalSat = 0.6; s.vignetteFeather = 0.2; s.grainSize = 0.8
        s.sharpenDetail = 0.7; s.opticsDistortion = 0.4; s.calibrationBlueHue = -0.2
        s.toneCurveRed[1].y = 0.1; s.cropW = 0.5; s.geometryVertical = 0.3
        s.pointColors = [PointColorAdjustment(hueShift: 0.2)]
        s.masks = [LocalMask(name: "Subject", adjustments: LocalAdjustments(exposure: 0.4))]
        s.spots = [SpotCorrection(points: [NormalizedPoint(x: 0.2, y: 0.3)])]
        s.redEyes = [RedEyeCorrection(center: NormalizedPoint(x: 0.4, y: 0.5))]
        s.reset()
        #expect(s.isIdentity)
        #expect(s == DevelopSettings())
        #expect(s.schemaVersion == DevelopSettings.currentSchemaVersion)
    }

    @Test func beforeSettingsResetsLookKeepsGeometry() {
        var s = DevelopSettings()
        s.exposure = 0.4; s.saturation = 0.5; s.profileAmount = 1.4
        s.curveDarks = -0.3; s.bwAqua = 0.2; s.grade.globalLum = -0.2
        s.sharpenMasking = 0.7; s.vignetteRoundness = 0.4
        s.opticsVignetting = -0.3; s.calibrationRedSat = 0.2
        s.cropX = 0.1; s.cropY = 0.05; s.cropW = 0.8; s.cropH = 0.9
        s.straighten = 5; s.rotationQuarterTurns = 1; s.flipH = true; s.flipV = true
        s.geometryVertical = 0.2; s.geometryHorizontal = -0.3; s.geometryAspect = 0.4
        s.geometryScale = 1.2; s.geometryOffsetX = -0.1; s.geometryOffsetY = 0.15
        s.pointColors = [PointColorAdjustment(saturationShift: 0.3)]
        s.masks = [LocalMask(name: "Sky", adjustments: LocalAdjustments(dehaze: 0.4))]
        s.spots = [SpotCorrection(points: [NormalizedPoint(x: 0.2, y: 0.3)])]
        s.redEyes = [RedEyeCorrection(center: NormalizedPoint(x: 0.4, y: 0.5))]

        let before = s.beforeSettings
        var expected = DevelopSettings()
        expected.cropX = 0.1; expected.cropY = 0.05; expected.cropW = 0.8; expected.cropH = 0.9
        expected.straighten = 5; expected.rotationQuarterTurns = 1
        expected.flipH = true; expected.flipV = true
        expected.geometryVertical = 0.2; expected.geometryHorizontal = -0.3
        expected.geometryAspect = 0.4; expected.geometryScale = 1.2
        expected.geometryOffsetX = -0.1; expected.geometryOffsetY = 0.15

        #expect(before == expected)
        #expect(before.hasGeometry)
        #expect(before.pointColors.isEmpty && before.masks.isEmpty)
        #expect(before.spots.isEmpty && before.redEyes.isEmpty)
    }

    @Test func codableRoundTrip() throws {
        var s = DevelopSettings()
        s.profileAmount = 1.2
        s.exposure = 0.25; s.contrast = -0.4; s.temperature = 0.3
        s.curveHighlights = 0.1; s.curveLights = 0.2
        s.curveDarks = -0.3; s.curveShadows = -0.4
        s.curveSplitShadows = 0.2; s.curveSplitMid = 0.45
        s.curveSplitHighlights = 0.8; s.curveRefineSaturation = 0.7
        s.colorMix.saturation[5] = -0.7
        s.grade.shadowHue = 0.6; s.grade.shadowSat = 0.5; s.grade.shadowLum = -0.4
        s.grade.midHue = 0.4; s.grade.midSat = 0.3; s.grade.midLum = 0.2
        s.grade.highHue = 0.2; s.grade.highSat = 0.1; s.grade.highLum = 0.3
        s.grade.globalHue = 0.7; s.grade.globalSat = 0.2; s.grade.globalLum = -0.1
        s.grade.blending = 0.6; s.grade.balance = -0.2
        s.toneCurve[2].y = 0.6
        s.blackWhite = true
        s.bwRed = 0.1; s.bwOrange = 0.2; s.bwYellow = 0.3; s.bwGreen = 0.4
        s.bwAqua = -0.1; s.bwBlue = -0.2; s.bwPurple = -0.3; s.bwMagenta = -0.4
        s.sharpness = 0.3; s.sharpenRadius = 0.4
        s.sharpenDetail = 0.6; s.sharpenMasking = 0.7
        s.noiseReduction = 0.2; s.noiseReductionDetail = 0.3; s.noiseReductionContrast = 0.4
        s.colorNoiseReduction = 0.5; s.colorNoiseReductionDetail = 0.6
        s.colorNoiseReductionSmoothness = 0.7
        s.vignette = -0.3; s.vignetteMidpoint = 0.4; s.vignetteRoundness = -0.2
        s.vignetteFeather = 0.7; s.vignetteHighlights = 0.3
        s.grain = 0.4; s.grainSize = 0.6; s.grainRoughness = 0.8
        s.opticsDistortion = -0.2; s.opticsVignetting = 0.3; s.opticsVignettingMidpoint = 0.6
        s.opticsProfileDistortion = 1.3; s.opticsProfileVignetting = 0.8
        s.opticsDefringePurple = 0.2; s.opticsDefringePurpleHueLo = 0.25; s.opticsDefringePurpleHueHi = 0.75
        s.opticsDefringeGreen = 0.3; s.opticsDefringeGreenHueLo = 0.35; s.opticsDefringeGreenHueHi = 0.65
        s.opticsCARed = -0.4; s.opticsCABlue = 0.5
        s.cropX = 0.05; s.cropY = 0.05; s.cropW = 0.9; s.cropH = 0.9; s.straighten = -3
        s.geometryVertical = 0.2; s.geometryHorizontal = -0.3; s.geometryAspect = 0.4
        s.geometryScale = 1.1; s.geometryOffsetX = -0.2; s.geometryOffsetY = 0.3
        s.calibrationShadowsTint = -0.2
        s.calibrationRedHue = 0.1; s.calibrationRedSat = 0.2
        s.calibrationGreenHue = -0.3; s.calibrationGreenSat = 0.4
        s.calibrationBlueHue = -0.5; s.calibrationBlueSat = 0.6

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: data)
        #expect(decoded == s)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let existingKeys = [
            "schemaVersion", "temperature", "tint", "exposure", "contrast", "highlights",
            "shadows", "whites", "blacks", "texture", "clarity", "dehaze", "vibrance",
            "saturation", "toneCurve", "toneCurveRed", "toneCurveGreen", "toneCurveBlue",
            "colorMix", "grade", "blackWhite", "bwRed", "bwGreen", "bwBlue", "sharpness",
            "sharpenRadius", "noiseReduction", "colorNoiseReduction", "grain", "vignette",
            "cropX", "cropY", "cropW", "cropH", "straighten", "flipH", "flipV",
            "rotationQuarterTurns", "pointColors", "masks", "spots", "redEyes"
        ]
        #expect(existingKeys.allSatisfy { object[$0] != nil })
    }

    @Test func selectiveEditsRoundTripWithStableShapeKinds() throws {
        var settings = DevelopSettings()
        settings.pointColors = [
            PointColorAdjustment(
                id: UUID(),
                luminance: 0.4,
                chroma: 0.2,
                hue: 0.75,
                hueShift: -0.2,
                saturationShift: 0.3,
                luminanceShift: 0.1,
                variance: -0.4,
                range: 0.6,
                hueRange: 0.7,
                chromaRange: 0.8,
                luminanceRange: 0.9,
                location: NormalizedPoint(x: 0.35, y: 0.65)
            )
        ]

        let brush = MaskComponent(
            operation: .subtract,
            inverted: true,
            shape: .brush(strokes: [
                BrushStroke(
                    points: [NormalizedPoint(x: 0.1, y: 0.2), NormalizedPoint(x: 0.3, y: 0.4)],
                    size: 0.04,
                    feather: 0.6,
                    flow: 0.7,
                    density: 0.8,
                    erase: true
                )
            ])
        )
        let linear = MaskComponent(
            operation: .intersect,
            shape: .linear(
                start: NormalizedPoint(x: 0.2, y: 0.3),
                end: NormalizedPoint(x: 0.8, y: 0.7)
            )
        )
        let radial = MaskComponent(
            shape: .radial(
                center: NormalizedPoint(x: 0.5, y: 0.4),
                radiusX: 0.3,
                radiusY: 0.2,
                angle: -45,
                feather: 0.65,
                inverted: true
            )
        )
        settings.masks = [
            LocalMask(
                name: "Portrait",
                enabled: true,
                inverted: true,
                components: [brush, linear, radial],
                adjustments: LocalAdjustments(
                    temperature: 0.1,
                    tint: -0.2,
                    exposure: 0.3,
                    contrast: -0.4,
                    highlights: 0.5,
                    shadows: -0.6,
                    whites: 0.7,
                    blacks: -0.8,
                    texture: 0.2,
                    clarity: 0.3,
                    dehaze: -0.2,
                    hue: 0.1,
                    saturation: 0.4,
                    sharpness: 0.5,
                    noiseReduction: 0.6,
                    amount: 1.2
                )
            )
        ]
        settings.spots = [
            SpotCorrection(
                mode: .clone,
                points: [NormalizedPoint(x: 0.2, y: 0.25), NormalizedPoint(x: 0.22, y: 0.27)],
                size: 0.03,
                feather: 0.4,
                opacity: 0.9,
                sourceOffset: NormalizedVector(dx: -0.2, dy: 0.3)
            )
        ]
        settings.redEyes = [
            RedEyeCorrection(
                center: NormalizedPoint(x: 0.45, y: 0.35),
                radiusX: 0.03,
                radiusY: 0.02,
                pupilSize: 0.6,
                darken: 0.7,
                petEye: true,
                catchlight: NormalizedVector(dx: 0.1, dy: -0.15)
            )
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: data)
        #expect(decoded == settings)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedMasks = try #require(object["masks"] as? [[String: Any]])
        let encodedMask = try #require(encodedMasks.first)
        let encodedComponents = try #require(encodedMask["components"] as? [[String: Any]])
        let kinds = encodedComponents.compactMap { component in
            (component["shape"] as? [String: Any])?["kind"] as? String
        }
        #expect(kinds == ["brush", "linear", "radial"])
    }

    @Test func pointColorLocationRoundTripsAndDefaultsLeniently() throws {
        let adjustment = PointColorAdjustment(
            hueShift: 0.2,
            location: NormalizedPoint(x: 0.25, y: 0.75)
        )
        let data = try JSONEncoder().encode(adjustment)
        let decoded = try JSONDecoder().decode(PointColorAdjustment.self, from: data)
        #expect(decoded == adjustment)
        #expect(decoded.location == NormalizedPoint(x: 0.25, y: 0.75))

        let missing = try JSONDecoder().decode(
            PointColorAdjustment.self,
            from: Data(#"{ "hueShift": 0.1 }"#.utf8)
        )
        #expect(missing.location == nil)

        let malformed = try JSONDecoder().decode(
            PointColorAdjustment.self,
            from: Data(#"{ "location": "bad" }"#.utf8)
        )
        #expect(malformed.location == nil)

        let clamped = try JSONDecoder().decode(
            PointColorAdjustment.self,
            from: Data(#"{ "location": { "x": -2, "y": 3 } }"#.utf8)
        )
        #expect(clamped.location == NormalizedPoint(x: 0, y: 1))
    }

    @Test func v5MigrationDefaultsSelectiveEdits() throws {
        let json = """
        { "schemaVersion": 5, "exposure": 0.25 }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: json)
        #expect(decoded.schemaVersion == 6)
        #expect(decoded.exposure == 0.25)
        #expect(decoded.pointColors.isEmpty)
        #expect(decoded.masks.isEmpty)
        #expect(decoded.spots.isEmpty)
        #expect(decoded.redEyes.isEmpty)
    }

    /// A v4 sidecar must retain its values while all v5 fields receive neutral defaults.
    @Test func lenientDecodeOfOldSidecar() throws {
        let json = """
        {
          "schemaVersion": 4,
          "exposure": 0.5,
          "contrast": 0.2,
          "bwRed": 0.3,
          "grade": {
            "shadowHue": 0.6,
            "shadowSat": 0.4,
            "midHue": 0.2,
            "midSat": 0.1,
            "highHue": 0.8,
            "highSat": 0.3
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: json)
        #expect(decoded.schemaVersion == DevelopSettings.currentSchemaVersion)
        #expect(decoded.exposure == 0.5)
        #expect(decoded.contrast == 0.2)
        #expect(decoded.bwRed == 0.3)
        #expect(decoded.grade.shadowHue == 0.6)
        #expect(decoded.grade.shadowSat == 0.4)
        #expect(decoded.grade.highSat == 0.3)

        #expect(decoded.profileAmount == 1)
        #expect([decoded.curveHighlights, decoded.curveLights, decoded.curveDarks, decoded.curveShadows] == [0, 0, 0, 0])
        #expect([decoded.curveSplitShadows, decoded.curveSplitMid, decoded.curveSplitHighlights] == [0.25, 0.5, 0.75])
        #expect(decoded.curveRefineSaturation == 1)
        #expect([decoded.bwOrange, decoded.bwYellow, decoded.bwAqua, decoded.bwPurple, decoded.bwMagenta] == [0, 0, 0, 0, 0])
        #expect(decoded.grade.shadowLum == 0)
        #expect(decoded.grade.globalSat == 0)
        #expect(decoded.grade.blending == 0.5)
        #expect(decoded.grade.balance == 0)
        #expect(decoded.vignetteMidpoint == 0.5)
        #expect(decoded.vignetteFeather == 0.5)
        #expect(decoded.grainSize == 0.25)
        #expect(decoded.grainRoughness == 0.5)
        #expect(decoded.sharpenDetail == 0.25)
        #expect(decoded.noiseReductionDetail == 0.5)
        #expect(decoded.colorNoiseReductionSmoothness == 0.5)
        #expect(decoded.opticsProfileDistortion == 1)
        #expect(decoded.opticsProfileVignetting == 1)
        #expect(decoded.opticsDefringePurpleHueLo == 0.3)
        #expect(decoded.opticsDefringeGreenHueHi == 0.6)
        #expect(decoded.geometryScale == 1)
        #expect(decoded.calibrationShadowsTint == 0)
        #expect(decoded.grain == 0)
        #expect(decoded.colorMix.isIdentity)
        #expect(decoded.toneCurveRed == DevelopSettings.linearCurve)
        #expect(!decoded.blackWhite)
    }

    @Test func emptyJSONDecodesToIdentity() throws {
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: "{}".data(using: .utf8)!)
        #expect(decoded.isIdentity)
        #expect(decoded.schemaVersion == DevelopSettings.currentSchemaVersion)
    }

    @Test func decodeSanitizesUntrustedValues() throws {
        let json = """
        {
          "schemaVersion": 1,
          "exposure": 8,
          "sharpness": -3,
          "cropX": 0.9,
          "cropY": -1,
          "cropW": 0.5,
          "cropH": 2,
          "straighten": 90,
          "rotationQuarterTurns": -1,
          "toneCurve": [
            { "x": 1.2, "y": -2 },
            { "x": -0.2, "y": 2 }
          ],
          "colorMix": {
            "hue": [2, -2],
            "saturation": [3],
            "luminance": []
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: json)
        #expect(decoded.schemaVersion == DevelopSettings.currentSchemaVersion)
        #expect(decoded.exposure == 1)
        #expect(decoded.sharpness == 0)
        #expect(decoded.cropX == 0.5)
        #expect(decoded.cropY == 0)
        #expect(decoded.cropW == 0.5)
        #expect(decoded.cropH == 1)
        #expect(decoded.straighten == 45)
        #expect(decoded.rotationQuarterTurns == 3)
        #expect(decoded.toneCurve == [CurvePoint(0, 1), CurvePoint(1, 0)])
        #expect(decoded.colorMix.hue == [1, -1, 0, 0, 0, 0, 0, 0])
        #expect(decoded.colorMix.saturation == [1, 0, 0, 0, 0, 0, 0, 0])
        #expect(decoded.colorMix.luminance == Array(repeating: 0, count: 8))
    }

    @Test func colorMixCanonicalizesShortOversizedAndNonfiniteArrays() throws {
        var settings = DevelopSettings()
        settings.colorMix.hue = [Double.nan, 2]
        settings.colorMix.saturation = [-2, -0.5, 0, 0.5, 2, 3, 4, 5, 6, 7]
        settings.colorMix.luminance = [Double.infinity, -Double.infinity]

        #expect(settings.colorMix.hue == [0, 1, 0, 0, 0, 0, 0, 0])
        #expect(settings.colorMix.saturation == [-1, -0.5, 0, 0.5, 1, 1, 1, 1])
        #expect(settings.colorMix.luminance == Array(repeating: 0, count: ColorMix.bandCount))

        let normalized = settings.normalizedForPersistence()
        #expect(normalized.colorMix.hue.count == ColorMix.bandCount)
        #expect(normalized.colorMix.saturation.count == ColorMix.bandCount)
        #expect(normalized.colorMix.luminance.count == ColorMix.bandCount)
        #expect(
            [normalized.colorMix.hue, normalized.colorMix.saturation, normalized.colorMix.luminance]
                .flatMap { $0 }
                .allSatisfy { $0.isFinite && (-1...1).contains($0) }
        )

        let roundTrip = try JSONDecoder().decode(
            DevelopSettings.self,
            from: JSONEncoder().encode(normalized)
        )
        #expect(roundTrip.colorMix == normalized.colorMix)
    }

    @Test func selectiveDecodeSanitizesBoundsAndCountLimits() throws {
        let rawPoints: [[String: Any]] = (0..<2_050).map { index in
            index == 0 ? ["x": -2.0, "y": 2.0] : ["x": 0.5, "y": 0.5]
        }

        var strokes: [[String: Any]] = [[
            "points": rawPoints,
            "size": -2,
            "feather": 3,
            "flow": "bad",
            "density": -1,
            "erase": true
        ]]
        strokes.append(contentsOf: Array(repeating: [
            "points": [["x": 0.5, "y": 0.5]]
        ], count: 256))

        let brushComponent: [String: Any] = [
            "shape": ["kind": "brush", "strokes": strokes]
        ]
        let radialComponent: [String: Any] = [
            "operation": "subtract",
            "shape": [
                "kind": "radial",
                "center": ["x": 2, "y": -2],
                "radiusX": -2,
                "radiusY": 2,
                "angle": 540,
                "feather": -2,
                "inverted": true
            ]
        ]
        let linearComponent: [String: Any] = ["shape": ["kind": "linear"]]
        var components = [brushComponent, radialComponent]
        components.append(contentsOf: Array(repeating: linearComponent, count: 31))

        let firstMask: [String: Any] = [
            "name": String(repeating: "x", count: 200),
            "components": components,
            "adjustments": ["temperature": 9, "amount": 9]
        ]
        let extraMask: [String: Any] = ["name": "Extra"]
        var masks = [firstMask]
        masks.append(contentsOf: Array(repeating: extraMask, count: 64))

        let firstPointColor: [String: Any] = [
            "luminance": 3,
            "chroma": -2,
            "hue": -1.25,
            "hueShift": 2,
            "saturationShift": -2,
            "luminanceShift": 3,
            "variance": -3,
            "range": -2,
            "hueRange": "bad",
            "chromaRange": 2,
            "luminanceRange": -1
        ]
        var pointColors = [firstPointColor]
        pointColors.append(contentsOf: Array(repeating: [String: Any](), count: 8))

        let emptySpot: [String: Any] = ["points": []]
        let populatedSpot: [String: Any] = [
            "points": rawPoints,
            "size": 2,
            "feather": -2,
            "opacity": 2,
            "sourceOffset": ["dx": 2, "dy": -2]
        ]

        let humanEye: [String: Any] = [
            "center": ["x": -2, "y": 2],
            "radiusX": -2,
            "radiusY": 2,
            "pupilSize": 2,
            "darken": -2,
            "petEye": false,
            "catchlight": ["dx": 1, "dy": 1]
        ]
        let petEye: [String: Any] = [
            "petEye": true,
            "catchlight": ["dx": 2, "dy": -2]
        ]
        var redEyes = [humanEye, petEye]
        redEyes.append(contentsOf: Array(repeating: [String: Any](), count: 63))

        let object: [String: Any] = [
            "schemaVersion": 6,
            "pointColors": pointColors,
            "masks": masks,
            "spots": [emptySpot, populatedSpot],
            "redEyes": redEyes
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: data)

        #expect(decoded.pointColors.count == 8)
        let pointColor = try #require(decoded.pointColors.first)
        #expect(pointColor.luminance == 1)
        #expect(pointColor.chroma == 0)
        #expect(pointColor.hue == 0.75)
        #expect(pointColor.hueShift == 1)
        #expect(pointColor.saturationShift == -1)
        #expect(pointColor.luminanceShift == 1)
        #expect(pointColor.variance == -1)
        #expect(pointColor.range == 0)
        #expect(pointColor.hueRange == 0.5)
        #expect(pointColor.chromaRange == 1)
        #expect(pointColor.luminanceRange == 0)

        #expect(decoded.masks.count == 32)
        let mask = try #require(decoded.masks.first)
        #expect(mask.name.unicodeScalars.count == SelectiveDevelopNormalization.maximumNameScalarCount)
        #expect(mask.components.count == 16)
        #expect(mask.adjustments.temperature == 1)
        #expect(mask.adjustments.amount == 2)
        #expect(mask.components[0].operation == .add)

        if case let .brush(decodedStrokes) = mask.components[0].shape {
            #expect(decodedStrokes.count == 128)
            let stroke = try #require(decodedStrokes.first)
            #expect(stroke.points.count == 2_048)
            #expect(stroke.points.first == NormalizedPoint(x: 0, y: 1))
            #expect(stroke.size == 0.001)
            #expect(stroke.feather == 1)
            #expect(stroke.flow == 1)
            #expect(stroke.density == 0)
            #expect(stroke.erase)
        } else {
            #expect(Bool(false), "Expected a brush mask shape")
        }

        if case let .radial(center, radiusX, radiusY, angle, feather, inverted) = mask.components[1].shape {
            #expect(center == NormalizedPoint(x: 1, y: 0))
            #expect(radiusX == 0.0001)
            #expect(radiusY == 1)
            #expect(angle == -180)
            #expect(feather == 0)
            #expect(inverted)
        } else {
            #expect(Bool(false), "Expected a radial mask shape")
        }

        #expect(decoded.spots.count == 1)
        let spot = try #require(decoded.spots.first)
        #expect(spot.mode == .remove)
        #expect(spot.points.count == 2_048)
        #expect(spot.size == 0.25)
        #expect(spot.feather == 0)
        #expect(spot.opacity == 1)
        #expect(spot.sourceOffset == NormalizedVector(dx: 1, dy: -1))

        #expect(decoded.redEyes.count == 64)
        #expect(decoded.redEyes[0].center == NormalizedPoint(x: 0, y: 1))
        #expect(decoded.redEyes[0].radiusX == 0.0001)
        #expect(decoded.redEyes[0].radiusY == 0.5)
        #expect(decoded.redEyes[0].pupilSize == 1)
        #expect(decoded.redEyes[0].darken == 0)
        #expect(decoded.redEyes[0].catchlight == nil)
        #expect(decoded.redEyes[1].catchlight == NormalizedVector(dx: 1, dy: -1))
    }

    @Test func malformedSelectiveElementsAreSkippedWithoutDroppingSiblings() throws {
        let componentJSON = """
        { "shape": { "kind": "future-shape" } }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MaskComponent.self, from: componentJSON)
        }

        let settingsJSON = """
        {
          "schemaVersion": 6,
          "exposure": 0.25,
          "pointColors": [
            { "hueShift": 0.1 },
            "bad",
            { "hueShift": 0.2 }
          ],
          "masks": [
            { "name": "Before", "components": [{ "shape": { "kind": "linear" } }] },
            { "components": [{ "shape": { "kind": "future-shape" } }] },
            { "name": "After", "components": [{ "shape": { "kind": "radial" } }] }
          ],
          "spots": [
            { "points": [{ "x": 0.1, "y": 0.2 }] },
            false,
            { "points": [{ "x": 0.3, "y": 0.4 }] }
          ],
          "redEyes": [
            { "center": { "x": 0.2, "y": 0.3 } },
            [],
            { "center": { "x": 0.6, "y": 0.7 } }
          ]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: settingsJSON)
        #expect(decoded.exposure == 0.25)
        #expect(decoded.pointColors.map(\.hueShift) == [0.1, 0.2])
        #expect(decoded.masks.map(\.name) == ["Before", "After"])
        #expect(decoded.spots.map { $0.points[0] } == [
            NormalizedPoint(x: 0.1, y: 0.2),
            NormalizedPoint(x: 0.3, y: 0.4),
        ])
        #expect(decoded.redEyes.map(\.center) == [
            NormalizedPoint(x: 0.2, y: 0.3),
            NormalizedPoint(x: 0.6, y: 0.7),
        ])
    }

    @Test func malformedSelectiveElementsDoNotConsumeResultCapacity() throws {
        let maximumCount = PointColorAdjustment.maximumCount
        let ids = (0..<maximumCount).map { _ in UUID() }
        var pointColors: [Any] = Array(repeating: "malformed", count: maximumCount)
        pointColors.append(contentsOf: ids.enumerated().map { index, id in
            [
                "id": id.uuidString,
                "hueShift": Double(index + 1) / Double(maximumCount),
            ] as [String: Any]
        })

        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": DevelopSettings.currentSchemaVersion,
            "pointColors": pointColors,
        ])
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: data)

        #expect(decoded.pointColors.count == maximumCount)
        #expect(decoded.pointColors.map(\.id) == ids)
    }

    @Test func malformedSelectiveElementScanningHasFiniteLimit() throws {
        var pointColors: [Any] = Array(repeating: "malformed", count: 10_000)
        pointColors.append(["hueShift": 0.5])
        let data = try JSONSerialization.data(withJSONObject: ["pointColors": pointColors])

        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: data)
        #expect(decoded.pointColors.isEmpty)
    }

    @Test func normalizationBoundsMaskNamesByScalarsAndUTF8Bytes() {
        let hostileName = "a" + String(repeating: "\u{0301}", count: 10_000)
        var settings = DevelopSettings()
        settings.masks = [LocalMask(name: hostileName)]

        let normalized = settings.normalizedForPersistence()
        let name = normalized.masks[0].name

        #expect(name.unicodeScalars.count == SelectiveDevelopNormalization.maximumNameScalarCount)
        #expect(name.utf8.count <= SelectiveDevelopNormalization.maximumNameUTF8ByteCount)
        #expect(name.utf8.count < hostileName.utf8.count)
        #expect(normalized.normalizedForPersistence() == normalized)
    }

    @Test func normalizationBoundsToneCurvePointsWhilePreservingDistribution() {
        let sourcePointCount = 100_000
        var settings = DevelopSettings()
        settings.toneCurve = (0..<sourcePointCount).reversed().map { index in
            let x = Double(index) / Double(sourcePointCount - 1)
            return CurvePoint(x, x * x)
        }

        let normalized = settings.normalizedForPersistence()
        #expect(normalized.toneCurve.count == DevelopSettings.maximumToneCurvePointCount)
        #expect(normalized.toneCurve.first == CurvePoint(0, 0))
        #expect(normalized.toneCurve.last == CurvePoint(1, 1))

        for index in [64, 128, 192] {
            let expectedX = Double(index) / Double(DevelopSettings.maximumToneCurvePointCount - 1)
            #expect(abs(normalized.toneCurve[index].x - expectedX) < 0.001)
        }
    }

    @Test func explicitUnknownSelectiveValuesAreSkippedButAbsentFieldsDefault() throws {
        let settingsJSON = """
        {
          "schemaVersion": 6,
          "masks": [
            { "name": "Default", "components": [{ "shape": { "kind": "linear" } }] },
            { "name": "Unknown", "components": [{
              "operation": "future-operation",
              "shape": { "kind": "linear" }
            }] },
            { "name": "Known", "components": [{
              "operation": "subtract",
              "shape": { "kind": "linear" }
            }] }
          ],
          "spots": [
            { "points": [{ "x": 0.1, "y": 0.2 }] },
            { "mode": "future-mode", "points": [{ "x": 0.3, "y": 0.4 }] },
            { "mode": "heal", "points": [{ "x": 0.5, "y": 0.6 }] }
          ],
          "redEyes": [
            { "petEye": false },
            { "center": { "x": "malformed", "y": 0.4 } },
            { "center": { "x": 0.7, "y": 0.8 } }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: settingsJSON)
        #expect(decoded.masks.map(\.name) == ["Default", "Known"])
        #expect(decoded.masks.map { $0.components[0].operation } == [.add, .subtract])
        #expect(decoded.spots.map(\.mode) == [.remove, .heal])
        #expect(decoded.redEyes.map(\.center) == [
            NormalizedPoint(x: 0.5, y: 0.5),
            NormalizedPoint(x: 0.7, y: 0.8),
        ])
    }

    @Test func normalizationEnforcesSelectiveCollectionLimits() throws {
        let point = NormalizedPoint(x: 0.5, y: 0.5)
        var brush = MaskComponent()
        brush.shape = .brush(strokes: Array(
            repeating: BrushStroke(points: [point]),
            count: MaskShape.maximumStrokeCount + 1
        ))
        var mask = LocalMask()
        mask.components = [brush] + Array(
            repeating: MaskComponent(shape: .linear(start: point, end: point)),
            count: LocalMask.maximumComponentCount
        )

        var settings = DevelopSettings()
        settings.masks = [mask] + Array(
            repeating: LocalMask(),
            count: LocalMask.maximumCount
        )
        settings.spots = Array(
            repeating: SpotCorrection(points: [point]),
            count: SpotCorrection.maximumCount + 1
        )

        let normalized = settings.normalizedForPersistence()
        #expect(normalized.masks.count == LocalMask.maximumCount)
        #expect(normalized.masks[0].components.count == LocalMask.maximumComponentCount)
        if case let .brush(strokes) = normalized.masks[0].components[0].shape {
            #expect(strokes.count == MaskShape.maximumStrokeCount)
        } else {
            Issue.record("Expected a brush mask shape")
        }
        #expect(normalized.spots.count == SpotCorrection.maximumCount)
    }

    @Test func normalizationEnforcesAggregatePathPointBudgetInDocumentOrder() throws {
        let point = NormalizedPoint(x: 0.5, y: 0.5)
        var remainingMaskPoints = SelectiveDevelopLimits.maximumTotalPathPoints - 2
        var strokes = [BrushStroke()]
        while remainingMaskPoints > 0 {
            let pointCount = min(remainingMaskPoints, BrushStroke.maximumPointCount)
            strokes.append(BrushStroke(points: Array(repeating: point, count: pointCount)))
            remainingMaskPoints -= pointCount
        }
        var component = MaskComponent()
        component.shape = .brush(strokes: strokes)

        let spotPoints = [
            NormalizedPoint(x: 0.1, y: 0.1),
            NormalizedPoint(x: 0.2, y: 0.2),
            NormalizedPoint(x: 0.3, y: 0.3),
        ]
        var settings = DevelopSettings()
        settings.masks = [LocalMask(components: [component])]
        settings.spots = [
            SpotCorrection(),
            SpotCorrection(points: spotPoints),
            SpotCorrection(points: [point]),
        ]

        let normalized = settings.normalizedForPersistence()
        #expect(normalized.currentPathPointCount == SelectiveDevelopLimits.maximumTotalPathPoints)
        if case let .brush(strokes) = normalized.masks[0].components[0].shape {
            let expectedStrokeCount = Int(ceil(
                Double(SelectiveDevelopLimits.maximumTotalPathPoints - 2)
                    / Double(BrushStroke.maximumPointCount)
            ))
            #expect(strokes.count == expectedStrokeCount)
            #expect(strokes.allSatisfy { !$0.points.isEmpty })
        } else {
            Issue.record("Expected a brush mask shape")
        }
        #expect(normalized.spots.count == 1)
        #expect(normalized.spots[0].points == Array(spotPoints.prefix(2)))
    }

    @Test func hostileInMemoryPathsAreBoundedBeforeNestedNormalization() throws {
        let points = Array(
            repeating: NormalizedPoint(x: 0.25, y: 0.75),
            count: BrushStroke.maximumPointCount
        )
        let stroke = BrushStroke(points: points)
        var component = MaskComponent()
        component.shape = .brush(strokes: Array(
            repeating: stroke,
            count: MaskShape.maximumStrokeCount
        ))
        var mask = LocalMask()
        mask.components = Array(
            repeating: component,
            count: LocalMask.maximumComponentCount
        )
        var spot = SpotCorrection()
        spot.points = points

        var settings = DevelopSettings()
        settings.masks = Array(repeating: mask, count: LocalMask.maximumCount)
        settings.spots = Array(repeating: spot, count: SpotCorrection.maximumCount)

        let bounded = DevelopSettings.boundedSelectivePaths(
            masks: settings.masks,
            spots: settings.spots
        )
        #expect(bounded.copiedPointCount == SelectiveDevelopLimits.maximumTotalPathPoints)
        #expect(bounded.visitedBrushStrokeCount
            == SelectiveDevelopLimits.maximumTotalPathPoints / BrushStroke.maximumPointCount)
        #expect(bounded.visitedSpotCount == 0)
        #expect(bounded.masks.count == LocalMask.maximumCount)
        #expect(bounded.spots.isEmpty)

        let normalized = settings.normalizedForPersistence()
        #expect(normalized.currentPathPointCount
            == SelectiveDevelopLimits.maximumTotalPathPoints)
        if case let .brush(strokes) = normalized.masks[0].components[0].shape {
            #expect(strokes.count == bounded.visitedBrushStrokeCount)
        } else {
            Issue.record("Expected bounded brush strokes")
        }
    }

    @Test func normalizationRepairsDuplicateAndMalformedSelectiveIDs() throws {
        let duplicate = UUID()
        let componentDuplicate = UUID()
        let json = """
        {
          "schemaVersion": 6,
          "pointColors": [
            { "id": "\(duplicate.uuidString)" },
            { "id": "\(duplicate.uuidString)" },
            { "id": "malformed" }
          ],
          "masks": [{
            "id": "\(duplicate.uuidString)",
            "components": [
              { "id": "\(componentDuplicate.uuidString)" },
              { "id": "\(componentDuplicate.uuidString)" },
              { "id": "malformed" }
            ]
          }],
          "spots": [{
            "id": "\(duplicate.uuidString)",
            "points": [{ "x": 0.2, "y": 0.3 }]
          }],
          "redEyes": [{ "id": "\(duplicate.uuidString)" }]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: json)
        let decodedAgain = try JSONDecoder().decode(DevelopSettings.self, from: json)
        let entityIDs = decoded.pointColors.map(\.id)
            + decoded.masks.map(\.id)
            + decoded.spots.map(\.id)
            + decoded.redEyes.map(\.id)
        #expect(Set(entityIDs).count == entityIDs.count)
        #expect(entityIDs.first == duplicate)

        let componentIDs = try #require(decoded.masks.first).components.map(\.id)
        #expect(Set(componentIDs).count == componentIDs.count)
        #expect(componentIDs.first == componentDuplicate)
        #expect(decodedAgain == decoded)
    }

    @Test func normalizationPrunesPathsBeforeDuplicateIDRepair() {
        let duplicate = UUID()
        var settings = DevelopSettings()
        settings.spots = [
            SpotCorrection(id: duplicate),
            SpotCorrection(
                id: duplicate,
                points: [NormalizedPoint(x: 0.25, y: 0.75)]
            ),
        ]

        let normalized = settings.normalizedForPersistence()
        #expect(normalized.spots.count == 1)
        #expect(normalized.spots[0].id == duplicate)
        #expect(settings.normalizedForPersistence() == normalized)
        #expect(normalized.normalizedForPersistence() == normalized)
    }

    @Test func decodeClampsExpandedUntrustedValues() throws {
        let json = """
        {
          "schemaVersion": 5,
          "profileAmount": 9,
          "curveHighlights": 9,
          "curveLights": -9,
          "curveDarks": 9,
          "curveShadows": -9,
          "curveSplitShadows": -9,
          "curveSplitMid": 9,
          "curveSplitHighlights": -9,
          "curveRefineSaturation": 9,
          "bwOrange": 9,
          "bwYellow": -9,
          "bwAqua": 9,
          "bwPurple": -9,
          "bwMagenta": 9,
          "grade": {
            "shadowHue": 9,
            "shadowSat": -9,
            "midHue": -9,
            "midSat": 9,
            "highHue": 9,
            "highSat": 9,
            "shadowLum": -9,
            "midLum": 9,
            "highLum": -9,
            "globalHue": 9,
            "globalSat": 9,
            "globalLum": 9,
            "blending": -9,
            "balance": 9
          },
          "vignetteMidpoint": -9,
          "vignetteRoundness": 9,
          "vignetteFeather": 9,
          "vignetteHighlights": -9,
          "grainSize": 9,
          "grainRoughness": -9,
          "sharpenDetail": 9,
          "sharpenMasking": -9,
          "noiseReductionDetail": 9,
          "noiseReductionContrast": -9,
          "colorNoiseReductionDetail": -9,
          "colorNoiseReductionSmoothness": 9,
          "opticsDistortion": 9,
          "opticsVignetting": -9,
          "opticsVignettingMidpoint": 9,
          "opticsProfileDistortion": -9,
          "opticsProfileVignetting": 9,
          "opticsDefringePurple": 9,
          "opticsDefringePurpleHueLo": -9,
          "opticsDefringePurpleHueHi": 9,
          "opticsDefringeGreen": -9,
          "opticsDefringeGreenHueLo": 9,
          "opticsDefringeGreenHueHi": -9,
          "opticsCARed": 9,
          "opticsCABlue": -9,
          "geometryVertical": 9,
          "geometryHorizontal": -9,
          "geometryAspect": 9,
          "geometryScale": 9,
          "geometryOffsetX": -9,
          "geometryOffsetY": 9,
          "calibrationShadowsTint": 9,
          "calibrationRedHue": -9,
          "calibrationRedSat": 9,
          "calibrationGreenHue": -9,
          "calibrationGreenSat": 9,
          "calibrationBlueHue": -9,
          "calibrationBlueSat": 9
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: json)
        #expect(decoded.profileAmount == 2)
        #expect([decoded.curveHighlights, decoded.curveLights, decoded.curveDarks, decoded.curveShadows] == [1, -1, 1, -1])
        #expect([decoded.curveSplitShadows, decoded.curveSplitMid, decoded.curveSplitHighlights] == [0, 1, 0])
        #expect(decoded.curveRefineSaturation == 1)
        #expect([decoded.bwOrange, decoded.bwYellow, decoded.bwAqua, decoded.bwPurple, decoded.bwMagenta] == [1, -1, 1, -1, 1])
        #expect(decoded.grade.shadowHue == 1)
        #expect(decoded.grade.shadowSat == 0)
        #expect(decoded.grade.midHue == 0)
        #expect(decoded.grade.midSat == 1)
        #expect(decoded.grade.highHue == 1)
        #expect(decoded.grade.highSat == 1)
        #expect([decoded.grade.shadowLum, decoded.grade.midLum, decoded.grade.highLum] == [-1, 1, -1])
        #expect(decoded.grade.globalHue == 1)
        #expect(decoded.grade.globalSat == 1)
        #expect(decoded.grade.globalLum == 1)
        #expect(decoded.grade.blending == 0)
        #expect(decoded.grade.balance == 1)
        #expect(decoded.vignetteMidpoint == 0)
        #expect(decoded.vignetteRoundness == 1)
        #expect(decoded.vignetteFeather == 1)
        #expect(decoded.vignetteHighlights == 0)
        #expect(decoded.grainSize == 1)
        #expect(decoded.grainRoughness == 0)
        #expect(decoded.sharpenDetail == 1)
        #expect(decoded.sharpenMasking == 0)
        #expect(decoded.noiseReductionDetail == 1)
        #expect(decoded.noiseReductionContrast == 0)
        #expect(decoded.colorNoiseReductionDetail == 0)
        #expect(decoded.colorNoiseReductionSmoothness == 1)
        #expect(decoded.opticsDistortion == 1)
        #expect(decoded.opticsVignetting == -1)
        #expect(decoded.opticsVignettingMidpoint == 1)
        #expect(decoded.opticsProfileDistortion == 0)
        #expect(decoded.opticsProfileVignetting == 2)
        #expect(decoded.opticsDefringePurple == 1)
        #expect(decoded.opticsDefringePurpleHueLo == 0)
        #expect(decoded.opticsDefringePurpleHueHi == 1)
        #expect(decoded.opticsDefringeGreen == 0)
        #expect(decoded.opticsDefringeGreenHueLo == 1)
        #expect(decoded.opticsDefringeGreenHueHi == 0)
        #expect(decoded.opticsCARed == 1)
        #expect(decoded.opticsCABlue == -1)
        #expect(decoded.geometryVertical == 1)
        #expect(decoded.geometryHorizontal == -1)
        #expect(decoded.geometryAspect == 1)
        #expect(decoded.geometryScale == 1.5)
        #expect(decoded.geometryOffsetX == -1)
        #expect(decoded.geometryOffsetY == 1)
        #expect(decoded.calibrationShadowsTint == 1)
        #expect(decoded.calibrationRedHue == -1)
        #expect(decoded.calibrationRedSat == 1)
        #expect(decoded.calibrationGreenHue == -1)
        #expect(decoded.calibrationGreenSat == 1)
        #expect(decoded.calibrationBlueHue == -1)
        #expect(decoded.calibrationBlueSat == 1)
    }

    @Test func malformedExpandedFieldsUseNeutralDefaults() throws {
        let json = """
        {
          "schemaVersion": 5,
          "profileAmount": "bad",
          "curveSplitMid": "bad",
          "grainSize": "bad",
          "geometryScale": "bad",
          "opticsProfileDistortion": "bad",
          "grade": { "globalSat": "bad", "blending": "bad" }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: json)
        #expect(decoded.profileAmount == 1)
        #expect(decoded.curveSplitMid == 0.5)
        #expect(decoded.grainSize == 0.25)
        #expect(decoded.geometryScale == 1)
        #expect(decoded.opticsProfileDistortion == 1)
        #expect(decoded.grade.globalSat == 0)
        #expect(decoded.grade.blending == 0.5)
        #expect(decoded.isIdentity)
    }

    @Test func futureSchemaIsRejected() {
        let json = """
        { "schemaVersion": 7, "exposure": 0.5 }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DevelopSettings.self, from: json)
        }
    }

    @Test func pastAndMalformedExplicitSchemaVersionsAreRejected() {
        let invalidDocuments = [
            #"{ "schemaVersion": 0 }"#,
            #"{ "schemaVersion": -1 }"#,
            #"{ "schemaVersion": "6" }"#,
            #"{ "schemaVersion": null }"#
        ]

        for document in invalidDocuments {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(DevelopSettings.self, from: Data(document.utf8))
            }
        }
    }

    @Test func curveLinearDetection() {
        var s = DevelopSettings()
        #expect(s.isCurveLinear)
        s.toneCurve[2].y = 0.7
        #expect(!s.isCurveLinear)
    }
}

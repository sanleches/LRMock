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
        #expect(DevelopSettings().isIdentity)
        #expect(DevelopSettings().isCurveLinear)
        #expect(DevelopSettings().isFullFrame)
        #expect(!DevelopSettings().hasGeometry)
    }

    @Test func editedIsNotIdentity() {
        var s = DevelopSettings()
        s.exposure = 0.3
        #expect(!s.isIdentity)
    }

    @Test func resetRestoresIdentityButKeepsSchema() {
        var s = DevelopSettings()
        s.exposure = 0.5; s.colorMix.hue[2] = 0.4; s.grade.highSat = 0.6
        s.toneCurveRed[1].y = 0.1; s.cropW = 0.5
        s.reset()
        #expect(s.isIdentity)
        #expect(s.schemaVersion == DevelopSettings.currentSchemaVersion)
    }

    @Test func beforeSettingsResetsLookKeepsGeometry() {
        var s = DevelopSettings()
        s.exposure = 0.4; s.saturation = 0.5
        s.cropX = 0.1; s.cropW = 0.8; s.straighten = 5; s.rotationQuarterTurns = 1; s.flipH = true
        let before = s.beforeSettings
        #expect(before.exposure == 0)
        #expect(before.saturation == 0)
        #expect(before.cropX == 0.1)
        #expect(before.cropW == 0.8)
        #expect(before.straighten == 5)
        #expect(before.rotationQuarterTurns == 1)
        #expect(before.flipH)
    }

    @Test func codableRoundTrip() throws {
        var s = DevelopSettings()
        s.exposure = 0.25; s.contrast = -0.4; s.temperature = 0.3
        s.colorMix.saturation[5] = -0.7
        s.grade.shadowHue = 0.6; s.grade.shadowSat = 0.5
        s.toneCurve[2].y = 0.6
        s.blackWhite = true; s.bwRed = 0.2
        s.vignette = -0.3; s.grain = 0.4
        s.cropX = 0.05; s.cropW = 0.9; s.cropH = 0.9; s.straighten = -3

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: data)
        #expect(decoded == s)
    }

    /// A v1-style sidecar (only a few fields) must decode with defaults, not fail.
    @Test func lenientDecodeOfOldSidecar() throws {
        let json = """
        { "schemaVersion": 1, "exposure": 0.5, "contrast": 0.2 }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: json)
        #expect(decoded.exposure == 0.5)
        #expect(decoded.contrast == 0.2)
        // New fields fall back to defaults.
        #expect(decoded.grain == 0)
        #expect(decoded.colorMix.isIdentity)
        #expect(decoded.toneCurveRed == DevelopSettings.linearCurve)
        #expect(!decoded.blackWhite)
    }

    @Test func emptyJSONDecodesToIdentity() throws {
        let decoded = try JSONDecoder().decode(DevelopSettings.self, from: "{}".data(using: .utf8)!)
        #expect(decoded.isIdentity)
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

    @Test func curveLinearDetection() {
        var s = DevelopSettings()
        #expect(s.isCurveLinear)
        s.toneCurve[2].y = 0.7
        #expect(!s.isCurveLinear)
    }
}

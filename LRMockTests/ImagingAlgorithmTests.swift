//
//  ImagingAlgorithmTests.swift
//  LRMockTests
//
//  Unit tests for the pure imaging math: tone-curve LUT (monotone cubic),
//  colour-cube engine (HSL mixer + grading), content digest, and fingerprint.
//

import Testing
import Foundation
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

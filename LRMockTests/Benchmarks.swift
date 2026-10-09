//
//  Benchmarks.swift
//  LRMockTests
//
//  Precise, reproducible micro-benchmarks that print exact per-op timings
//  (grep the log for "BENCHMARK"). XCTest so stdout reaches the console.
//  Simulator/Debug numbers are relative; device/Release are the real budget.
//

import XCTest
import CoreFoundation
@testable import LRMock

final class Benchmarks: XCTestCase {

    private func perOp(_ n: Int, _ block: () -> Void) -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { block() }
        return (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
    }

    func testBenchColorCubeBuild() {
        let n = 60
        let mixes = (0..<n).map { i -> ColorMix in
            var m = ColorMix()
            m.hue[i % 8] = Double(i) / Double(n) * 2 - 1
            m.saturation[(i + 1) % 8] = Double(i) / Double(n)
            return m
        }
        var idx = 0
        let per = perOp(n) { _ = ColorCubeEngine.hslCube(for: mixes[idx % n]); idx += 1 }
        print("BENCHMARK hslCube build (16^3): \(String(format: "%.3f", per)) ms/build")
    }

    func testBenchGradingCubeBuild() {
        let n = 60
        let grades = (0..<n).map { i -> ColorGrade in
            var g = ColorGrade(); g.shadowHue = Double(i) / Double(n); g.shadowSat = 0.3 + Double(i) / Double(n) * 0.5; return g
        }
        var idx = 0
        let per = perOp(n) { _ = ColorCubeEngine.gradingCube(for: grades[idx % n]); idx += 1 }
        print("BENCHMARK gradingCube build (16^3): \(String(format: "%.3f", per)) ms/build")
    }

    func testBenchChannelLUTBuild() {
        var master = DevelopSettings.linearCurve; master[2].y = 0.62
        var red = DevelopSettings.linearCurve; red[1].y = 0.2
        let per = perOp(200) {
            _ = ToneCurveLUT.channelLUT(master: master, red: red,
                                        green: DevelopSettings.linearCurve, blue: DevelopSettings.linearCurve)
        }
        print("BENCHMARK channelLUT build (256): \(String(format: "%.3f", per)) ms/build")
    }

    func testBenchRender() async throws {
        let url = TestImage.writeGrey(120, size: 2000)
        defer { try? FileManager.default.removeItem(at: url) }
        let pipe = CoreImagePipeline()

        var heavy = DevelopSettings()
        heavy.exposure = 0.3; heavy.contrast = 0.4; heavy.highlights = -0.3; heavy.shadows = 0.3
        heavy.vibrance = 0.4; heavy.clarity = 0.3; heavy.toneCurve[2].y = 0.6
        heavy.colorMix.saturation[5] = -0.5
        heavy.grade.shadowHue = 0.6; heavy.grade.shadowSat = 0.4
        heavy.vignette = -0.3; heavy.sharpness = 0.4

        var light = DevelopSettings(); light.exposure = 0.3

        // Dragging-an-HSL-slider scenario: distinct colorMix each frame.
        func avgVaryingMix(_ maxPixel: Int, iters: Int) async -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            for i in 0..<iters {
                var s = heavy; s.colorMix.hue[i % 8] = Double(i) / Double(iters) - 0.5
                _ = try? await pipe.renderPreview(
                    fileURL: url,
                    settings: s,
                    maxPixelSize: maxPixel,
                    quality: .interactive
                )
            }
            return (CFAbsoluteTimeGetCurrent() - t0) / Double(iters) * 1000
        }

        func avg(
            _ settings: DevelopSettings,
            _ maxPixel: Int,
            quality: PreviewRenderQuality,
            iters: Int
        ) async -> Double {
            _ = try? await pipe.renderPreview(
                fileURL: url,
                settings: settings,
                maxPixelSize: maxPixel,
                quality: quality
            )
            let t0 = CFAbsoluteTimeGetCurrent()
            for _ in 0..<iters {
                _ = try? await pipe.renderPreview(
                    fileURL: url,
                    settings: settings,
                    maxPixelSize: maxPixel,
                    quality: quality
                )
            }
            return (CFAbsoluteTimeGetCurrent() - t0) / Double(iters) * 1000
        }

        print("BENCHMARK render 1280 light interactive: \(String(format: "%.1f", await avg(light, 1280, quality: .interactive, iters: 20))) ms")
        print("BENCHMARK render 1280 heavy interactive (cube cached): \(String(format: "%.1f", await avg(heavy, 1280, quality: .interactive, iters: 20))) ms")
        print("BENCHMARK render 1280 heavy (HSL dragging): \(String(format: "%.1f", await avgVaryingMix(1280, iters: 20))) ms")
        print("BENCHMARK render 2400 heavy settled: \(String(format: "%.1f", await avg(heavy, 2400, quality: .settled, iters: 15))) ms")
    }
}

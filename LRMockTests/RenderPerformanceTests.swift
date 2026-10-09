//
//  RenderPerformanceTests.swift
//  LRMockTests
//
//  Performance baselines for the edit hot path. These measure the real cost of
//  rendering and the CPU-side algorithm pieces so we can target optimisation and
//  catch regressions. Run on the slowest supported device for real budgets; the
//  simulator/Debug numbers are only relative.
//

import XCTest
import CoreGraphics
@testable import LRMock

final class RenderPerformanceTests: XCTestCase {

    private let pipeline = CoreImagePipeline()
    private var imageURL: URL!

    override func setUp() {
        super.setUp()
        imageURL = TestImage.writeGrey(120, size: 2000)
    }
    override func tearDown() {
        if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
        super.tearDown()
    }

    /// A realistic "developed" recipe exercising curves, HSL mixer, and grading.
    private func heavyEdit() -> DevelopSettings {
        var s = DevelopSettings()
        s.exposure = 0.3; s.contrast = 0.4; s.highlights = -0.3; s.shadows = 0.3
        s.vibrance = 0.4; s.saturation = 0.2; s.clarity = 0.3; s.texture = 0.2
        s.toneCurve[2].y = 0.6
        s.colorMix.saturation[5] = -0.5; s.colorMix.luminance[3] = 0.3
        s.grade.shadowHue = 0.6; s.grade.shadowSat = 0.4; s.grade.highHue = 0.1; s.grade.highSat = 0.5
        s.vignette = -0.3; s.sharpness = 0.4
        return s
    }

    private func render(
        _ settings: DevelopSettings,
        maxPixel: Int,
        quality: PreviewRenderQuality
    ) {
        let exp = expectation(description: "render")
        Task {
            _ = try? await pipeline.renderPreview(
                fileURL: imageURL,
                settings: settings,
                maxPixelSize: maxPixel,
                quality: quality
            )
            exp.fulfill()
        }
        wait(for: [exp], timeout: 20)
    }

    // MARK: Render (the interactive hot path)

    func testRenderInteractiveLightEdit() {
        var s = DevelopSettings(); s.exposure = 0.3
        measure { render(s, maxPixel: 1280, quality: .interactive) }
    }

    func testRenderInteractiveHeavyEdit() {
        let s = heavyEdit()
        measure { render(s, maxPixel: 1280, quality: .interactive) }
    }

    func testRenderSettledHeavyEdit() {
        let s = heavyEdit()
        measure { render(s, maxPixel: 2400, quality: .settled) }
    }

    // MARK: CPU algorithm pieces

    /// Building distinct colour cubes (the per-frame cost while dragging an HSL
    /// or grading slider, since each new value misses the value cache).
    func testColorCubeBuildThroughput() {
        measure {
            for i in 0..<10 {
                var mix = ColorMix()
                mix.hue[0] = Double(i) / 23.0 + 0.0001
                mix.saturation[2] = Double(i) / 17.0
                _ = ColorCubeEngine.hslCube(for: mix)
            }
        }
    }

    func testToneCurveChannelLUTBuild() {
        var master = DevelopSettings.linearCurve; master[2].y = 0.62
        var red = DevelopSettings.linearCurve; red[1].y = 0.2
        measure {
            for _ in 0..<50 {
                _ = ToneCurveLUT.channelLUT(
                    master: master, red: red,
                    green: DevelopSettings.linearCurve, blue: DevelopSettings.linearCurve)
            }
        }
    }
}

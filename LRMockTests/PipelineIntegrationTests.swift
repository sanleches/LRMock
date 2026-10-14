//
//  PipelineIntegrationTests.swift
//  LRMockTests
//
//  End-to-end imaging tests: decode a real file, apply develop settings, and
//  verify the pipeline actually changes pixels the way it should, then that
//  export encodes a valid file. Also covers the recipe document + library paths.
//

import Testing
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import SwiftData
import UniformTypeIdentifiers
@testable import LRMock

/// Shared helpers for generating and measuring test images.
enum TestImage {

    /// Writes a flat mid-grey JPEG and returns its URL.
    static func writeGrey(_ level: UInt8 = 128, size: Int = 512) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grey-\(UUID().uuidString).jpg")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let v = CGFloat(level) / 255
        ctx.setFillColor(CGColor(colorSpace: cs, components: [v, v, v, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    static func writeColor(_ components: (Double, Double, Double), size: Int = 192) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("color-\(UUID().uuidString).png")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [
            components.0, components.1, components.2, 1,
        ])!)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    static func writePattern(size: Int = 192) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pattern-\(UUID().uuidString).png")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors: [[CGFloat]] = [
            [0.9, 0.15, 0.1, 1], [0.1, 0.75, 0.25, 1],
            [0.1, 0.25, 0.9, 1], [0.9, 0.75, 0.1, 1],
        ]
        let cell = size / 6
        for y in 0..<6 {
            for x in 0..<6 {
                let color = colors[(x + y * 3) % colors.count]
                ctx.setFillColor(CGColor(colorSpace: cs, components: color)!)
                ctx.fill(CGRect(x: x * cell, y: y * cell,
                                width: x == 5 ? size - x * cell : cell,
                                height: y == 5 ? size - y * cell : cell))
            }
        }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: size / 7, y: size * 3 / 5, width: size / 8, height: size / 8))
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    static func writeSplitColor(size: Int = 96) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-\(UUID().uuidString).png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(
            colorSpace: colorSpace, components: [0.9, 0.08, 0.05, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        context.setFillColor(CGColor(
            colorSpace: colorSpace, components: [0.05, 0.12, 0.9, 1])!)
        context.fill(CGRect(x: size / 2, y: 0, width: size - size / 2, height: size))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    static func writeRedEye(size: Int = 96) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("red-eye-\(UUID().uuidString).png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(
            colorSpace: colorSpace, components: [0.3, 0.32, 0.34, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(
            colorSpace: colorSpace, components: [0.95, 0.06, 0.05, 1])!)
        context.fillEllipse(in: CGRect(
            x: size * 3 / 8, y: size * 3 / 8,
            width: size / 4, height: size / 4
        ))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    static func writeBlemish(size: Int = 96) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("blemish-\(UUID().uuidString).png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(
            colorSpace: colorSpace, components: [0.65, 0.65, 0.65, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let radius = max(2, size / 16)
        context.setFillColor(CGColor(
            colorSpace: colorSpace, components: [0.03, 0.03, 0.03, 1])!)
        context.fillEllipse(in: CGRect(
            x: size * 3 / 4 - radius,
            y: size / 2 - radius,
            width: radius * 2,
            height: radius * 2
        ))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    static func writePetEye(size: Int = 96) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-eye-\(UUID().uuidString).png")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(
            colorSpace: colorSpace, components: [0.22, 0.24, 0.25, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(CGColor(
            colorSpace: colorSpace, components: [0.18, 0.92, 0.28, 1])!)
        context.fillEllipse(in: CGRect(
            x: size * 3 / 8, y: size * 3 / 8,
            width: size / 4, height: size / 4
        ))
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    /// Mean luminance (0...1) of a CGImage.
    static func meanLuminance(_ cg: CGImage) -> Double {
        let w = min(cg.width, 64), h = min(cg.height, 64)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        var i = 0
        while i < px.count {
            sum += (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255
            i += 4
        }
        return sum / Double(w * h)
    }

    static func rgba(_ cg: CGImage, size: Int = 64) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = CGContext(
            data: &pixels, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels
    }

    static func meanAbsoluteDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        let a = rgba(lhs), b = rgba(rhs)
        var difference = 0.0
        for index in stride(from: 0, to: a.count, by: 4) {
            difference += abs(Double(a[index]) - Double(b[index]))
            difference += abs(Double(a[index + 1]) - Double(b[index + 1]))
            difference += abs(Double(a[index + 2]) - Double(b[index + 2]))
        }
        return difference / Double((a.count / 4) * 3) / 255
    }

    static func centerSaturation(_ cg: CGImage) -> Double {
        let pixels = rgba(cg)
        let index = (32 * 64 + 32) * 4
        let values = [pixels[index], pixels[index + 1], pixels[index + 2]].map(Double.init)
        let chroma = (values.max() ?? 0) - (values.min() ?? 0)
        let luminance = 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
        return chroma / max(1, luminance)
    }

    static func rgb(_ cg: CGImage, x: Int, y: Int, size: Int = 64) -> SIMD3<Double> {
        let pixels = rgba(cg, size: size)
        let clampedX = min(size - 1, max(0, x))
        let clampedY = min(size - 1, max(0, y))
        let index = (clampedY * size + clampedX) * 4
        return SIMD3(
            Double(pixels[index]) / 255,
            Double(pixels[index + 1]) / 255,
            Double(pixels[index + 2]) / 255
        )
    }

    static func luminance(_ cg: CGImage, x: Int, y: Int, size: Int = 64) -> Double {
        let color = rgb(cg, x: x, y: y, size: size)
        return 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z
    }
}

struct PipelineIntegrationTests {

    private let pipeline = CoreImagePipeline()

    @Test func defaultAdjustmentsArePixelIdentity() throws {
        let url = TestImage.writePattern(size: 128)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try #require(CIImage(contentsOf: url))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let expected = try CoreImageAdjustments.rasterize(
            source, context: context, colorSpace: colorSpace)

        for quality in [PreviewRenderQuality.interactive, .settled] {
            let adjusted = CoreImageAdjustments.apply(
                to: source, settings: DevelopSettings(),
                includeBasics: true, quality: quality)
            #expect(adjusted.extent == source.extent)
            let actual = try CoreImageAdjustments.rasterize(
                adjusted, context: context, colorSpace: colorSpace)
            #expect(TestImage.rgba(actual.cgImage) == TestImage.rgba(expected.cgImage))
        }
    }

    @Test func renderProducesBoundedImage() async throws {
        let url = TestImage.writeGrey()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 256)
        #expect(result.cgImage.width <= 256 && result.cgImage.height <= 256)
        #expect(result.cgImage.width > 0)
    }

    @Test func exposureBrightensImage() async throws {
        let url = TestImage.writeGrey(100)
        defer { try? FileManager.default.removeItem(at: url) }

        let base = try await pipeline.renderPreview(fileURL: url, settings: DevelopSettings(), maxPixelSize: 256)
        var up = DevelopSettings(); up.exposure = 0.6
        let brighter = try await pipeline.renderPreview(fileURL: url, settings: up, maxPixelSize: 256)

        #expect(TestImage.meanLuminance(brighter.cgImage) > TestImage.meanLuminance(base.cgImage) + 0.03)
    }

    @Test func foundationToneControlsRenderInBothDirections() async throws {
        let cases: [(WritableKeyPath<DevelopSettings, Double>, UInt8)] = [
            (\DevelopSettings.blacks, 38),
            (\DevelopSettings.shadows, 100),
            (\DevelopSettings.highlights, 155),
            (\DevelopSettings.whites, 220),
        ]

        for (keyPath, level) in cases {
            let url = TestImage.writeGrey(level, size: 128)
            defer { try? FileManager.default.removeItem(at: url) }

            let base = try await pipeline.renderPreview(
                fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)
            var downSettings = DevelopSettings()
            downSettings[keyPath: keyPath] = -0.75
            let down = try await pipeline.renderPreview(
                fileURL: url, settings: downSettings, maxPixelSize: 64)
            var upSettings = DevelopSettings()
            upSettings[keyPath: keyPath] = 0.75
            let up = try await pipeline.renderPreview(
                fileURL: url, settings: upSettings, maxPixelSize: 64)

            let baseLuminance = TestImage.meanLuminance(base.cgImage)
            #expect(TestImage.meanLuminance(down.cgImage) < baseLuminance - 0.003)
            #expect(TestImage.meanLuminance(up.cgImage) > baseLuminance + 0.003)
        }
    }

    @Test func blackAndWhiteRemovesSaturation() async throws {
        // A coloured image → B&W should have near-equal R=G=B.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("col-\(UUID().uuidString).jpg")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.8, 0.2, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        defer { try? FileManager.default.removeItem(at: url) }

        var bw = DevelopSettings(); bw.blackWhite = true
        let out = try await pipeline.renderPreview(fileURL: url, settings: bw, maxPixelSize: 64)
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let octx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                             space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        octx.draw(out.cgImage, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        // Sample centre pixel R,G,B nearly equal.
        let idx = (32 * 64 + 32) * 4
        let r = Int(px[idx]), g = Int(px[idx + 1]), b = Int(px[idx + 2])
        #expect(abs(r - g) < 12 && abs(g - b) < 12)
    }

    @Test func parametricCurveAndRefineSaturationRender() async throws {
        let greyURL = TestImage.writeGrey(92, size: 128)
        defer { try? FileManager.default.removeItem(at: greyURL) }
        let baseline = try await pipeline.renderPreview(
            fileURL: greyURL, settings: DevelopSettings(), maxPixelSize: 96)

        var down = DevelopSettings()
        down.curveDarks = -0.9
        let darker = try await pipeline.renderPreview(
            fileURL: greyURL, settings: down, maxPixelSize: 96)
        var up = DevelopSettings()
        up.curveDarks = 0.9
        let lighter = try await pipeline.renderPreview(
            fileURL: greyURL, settings: up, maxPixelSize: 96)
        #expect(TestImage.meanLuminance(darker.cgImage)
            < TestImage.meanLuminance(baseline.cgImage) - 0.004)
        #expect(TestImage.meanLuminance(lighter.cgImage)
            > TestImage.meanLuminance(baseline.cgImage) + 0.004)

        let colorURL = TestImage.writeColor((0.68, 0.32, 0.14), size: 128)
        defer { try? FileManager.default.removeItem(at: colorURL) }
        var curved = DevelopSettings()
        curved.toneCurve = [
            CurvePoint(0, 0), CurvePoint(0.35, 0.12),
            CurvePoint(0.65, 0.88), CurvePoint(1, 1),
        ]
        curved.curveRefineSaturation = 1
        let ownSaturation = try await pipeline.renderPreview(
            fileURL: colorURL, settings: curved, maxPixelSize: 96)
        curved.curveRefineSaturation = 0
        let preserved = try await pipeline.renderPreview(
            fileURL: colorURL, settings: curved, maxPixelSize: 96)
        #expect(TestImage.centerSaturation(preserved.cgImage)
            < TestImage.centerSaturation(ownSaturation.cgImage) - 0.01)
    }

    @Test func eightBandBlackAndWhiteAndProfileStrengthChangePixels() async throws {
        let url = TestImage.writeColor((1, 0.5, 0), size: 128)
        defer { try? FileManager.default.removeItem(at: url) }

        var darkOrange = DevelopSettings()
        darkOrange.blackWhite = true
        darkOrange.bwOrange = -1
        let dark = try await pipeline.renderPreview(
            fileURL: url, settings: darkOrange, maxPixelSize: 96)
        var lightOrange = darkOrange
        lightOrange.bwOrange = 1
        let light = try await pipeline.renderPreview(
            fileURL: url, settings: lightOrange, maxPixelSize: 96)
        #expect(TestImage.meanLuminance(light.cgImage)
            > TestImage.meanLuminance(dark.cgImage) + 0.08)

        let neutral = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 96)
        var profile = DevelopSettings()
        profile.profileAmount = 2
        let stronger = try await pipeline.renderPreview(
            fileURL: url, settings: profile, maxPixelSize: 96)
        #expect(TestImage.meanAbsoluteDifference(neutral.cgImage, stronger.cgImage) > 0.004)
    }

    @Test func opticsAndGeometryPreserveExtentAndMovePixels() async throws {
        let url = TestImage.writePattern(size: 192)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 160)

        var disabledProfile = DevelopSettings()
        disabledProfile.opticsDistortion = 0.9
        disabledProfile.opticsProfileDistortion = 0
        let disabled = try await pipeline.renderPreview(
            fileURL: url, settings: disabledProfile, maxPixelSize: 160)
        #expect(TestImage.meanAbsoluteDifference(baseline.cgImage, disabled.cgImage) < 0.000_1)

        disabledProfile.opticsProfileDistortion = 1
        disabledProfile.opticsCARed = 1
        disabledProfile.opticsCABlue = -1
        let corrected = try await pipeline.renderPreview(
            fileURL: url, settings: disabledProfile, maxPixelSize: 160)
        #expect(corrected.cgImage.width == baseline.cgImage.width)
        #expect(corrected.cgImage.height == baseline.cgImage.height)
        #expect(TestImage.meanAbsoluteDifference(baseline.cgImage, corrected.cgImage) > 0.01)

        var geometry = DevelopSettings()
        geometry.geometryVertical = 0.55
        geometry.geometryHorizontal = -0.35
        geometry.geometryAspect = 0.4
        geometry.geometryScale = 1.15
        geometry.geometryOffsetX = 0.12
        geometry.geometryOffsetY = -0.08
        let transformed = try await pipeline.renderPreview(
            fileURL: url, settings: geometry, maxPixelSize: 160)
        #expect(transformed.cgImage.width == baseline.cgImage.width)
        #expect(transformed.cgImage.height == baseline.cgImage.height)
        #expect(TestImage.meanAbsoluteDifference(baseline.cgImage, transformed.cgImage) > 0.04)
    }

    @Test func vignetteSignsAndShapeControlsMatter() async throws {
        let url = TestImage.writeGrey(128, size: 160)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 128)

        var dark = DevelopSettings()
        dark.vignette = -0.8
        dark.vignetteMidpoint = 0.2
        dark.vignetteRoundness = -1
        dark.vignetteFeather = 0.15
        let darkened = try await pipeline.renderPreview(
            fileURL: url, settings: dark, maxPixelSize: 128)
        var light = dark
        light.vignette = 0.8
        light.vignetteMidpoint = 0.85
        light.vignetteRoundness = 1
        light.vignetteFeather = 0.9
        let lightened = try await pipeline.renderPreview(
            fileURL: url, settings: light, maxPixelSize: 128)

        #expect(TestImage.meanLuminance(darkened.cgImage)
            < TestImage.meanLuminance(baseline.cgImage) - 0.01)
        #expect(TestImage.meanLuminance(lightened.cgImage)
            > TestImage.meanLuminance(baseline.cgImage) + 0.005)
        #expect(TestImage.meanAbsoluteDifference(darkened.cgImage, lightened.cgImage) > 0.05)
    }

    @Test func pointColorMateriallyChangesItsSampledColor() async throws {
        let color = SIMD3(0.78, 0.18, 0.08)
        let url = TestImage.writeColor((color.x, color.y, color.z), size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)
        let sampling = try await pipeline.renderPointColorSamplingPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)
        let sampledColor = try #require(PointColorImageSampler.extendedLinearDisplayP3(
            in: sampling.cgImage,
            at: NormalizedPoint(x: 0.5, y: 0.5)
        ))

        let reference = ColorCubeEngine.pointColorReference(
            red: sampledColor.x, green: sampledColor.y, blue: sampledColor.z)
        var settings = DevelopSettings()
        settings.pointColors = [PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: reference.hue,
            hueShift: 0.35,
            saturationShift: -0.55,
            luminanceShift: 0.55,
            range: 1,
            hueRange: 1,
            chromaRange: 1,
            luminanceRange: 1
        )]
        let adjusted = try await pipeline.renderPreview(
            fileURL: url, settings: settings, maxPixelSize: 64)
        #expect(TestImage.meanAbsoluteDifference(baseline.cgImage, adjusted.cgImage) > 0.03)
    }

    @Test func pointColorSamplingPreservesNativeDetailDecodeSettingsAndIntent() async throws {
        let recorder = NativeDecodeRecorder()
        let pipeline = CoreImagePipeline(nativeDecoder: { recorder.decode($0) })
        var settings = DevelopSettings()
        settings.sharpness = 0.83
        settings.sharpenDetail = 0.71
        settings.noiseReduction = 0.62
        settings.noiseReductionDetail = 0.44
        settings.colorNoiseReduction = 0.57
        settings.colorNoiseReductionSmoothness = 0.36

        _ = try await pipeline.renderPointColorSamplingPreview(
            fileURL: URL(fileURLWithPath: "/raw-sampling-test.dng"),
            settings: settings,
            maxPixelSize: 80
        )
        _ = try await pipeline.renderPreview(
            fileURL: URL(fileURLWithPath: "/raw-display-test.dng"),
            settings: settings,
            maxPixelSize: 96,
            quality: .interactive
        )

        let requests = recorder.snapshot()
        #expect(requests.count == 2)
        #expect(requests[0].intent == .pointColorSampling)
        #expect(requests[0].quality == .settled)
        #expect(requests[0].maxPixelSize == 80)
        #expect(requests[0].settings == settings)
        #expect(requests[1].intent == .display)
        #expect(requests[1].quality == .interactive)
        #expect(requests[1].settings == settings)
    }

    @Test func pointColorPreservesExtendedRangePixels() throws {
        let colorSpace = try #require(
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        )
        let selected = SIMD3<Double>(0.24, 0.62, 0.18)
        let reference = ColorCubeEngine.pointColorReference(
            red: selected.x,
            green: selected.y,
            blue: selected.z
        )
        let cube = try #require(ColorCubeEngine.pointColorCube(for: [
            PointColorAdjustment(
                luminance: reference.luminance,
                chroma: reference.chroma,
                hue: reference.hue,
                hueShift: 0.75,
                saturationShift: -0.6,
                luminanceShift: 0.5,
                range: 1,
                hueRange: 1,
                chromaRange: 1,
                luminanceRange: 1
            ),
        ]))

        let colors: [(rgb: SIMD3<Float>, alpha: Float)] = [
            (SIMD3(1.35, 0.15, 0.08), 0.5),
            (SIMD3(-0.18, 0.35, 0.55), 0.75),
            (SIMD3(Float(selected.x), Float(selected.y), Float(selected.z)), 0.625),
        ]
        let source = colors.flatMap { color in
            [
                color.rgb.x * color.alpha,
                color.rgb.y * color.alpha,
                color.rgb.z * color.alpha,
                color.alpha,
            ]
        }
        let halfSource = source.map(Float16.init)
        let variants: [(name: String, format: CIFormat, data: Data, rowBytes: Int)] = [
            (
                "float",
                .RGBAf,
                source.withUnsafeBytes { Data($0) },
                colors.count * 4 * MemoryLayout<Float>.size
            ),
            (
                "half-float",
                .RGBAh,
                halfSource.withUnsafeBytes { Data($0) },
                colors.count * 4 * MemoryLayout<Float16>.size
            ),
        ]
        let extent = CGRect(x: 0, y: 0, width: colors.count, height: 1)
        let context = CIContext(options: [
            .useSoftwareRenderer: true,
            .workingColorSpace: colorSpace,
            .workingFormat: CIFormat.RGBAf,
        ])

        func renderedPixels(_ image: CIImage) -> [Float] {
            var pixels = [Float](repeating: 0, count: colors.count * 4)
            pixels.withUnsafeMutableBytes { bytes in
                context.render(
                    image,
                    toBitmap: bytes.baseAddress!,
                    rowBytes: colors.count * 4 * MemoryLayout<Float>.size,
                    bounds: extent,
                    format: .RGBAf,
                    colorSpace: colorSpace
                )
            }
            return pixels
        }

        for variant in variants {
            let input = CIImage(
                bitmapData: variant.data,
                bytesPerRow: variant.rowBytes,
                size: extent.size,
                format: variant.format,
                colorSpace: colorSpace
            )
            let output = CoreImageAdjustments.applyPointColorCube(cube, to: input)
            let before = renderedPixels(input)
            let after = renderedPixels(output)

            #expect(output.extent == input.extent)
            for index in 0..<8 {
                #expect(
                    abs(after[index] - before[index]) < 0.002,
                    "Point Color changed an extended-range \(variant.name) component"
                )
            }
            for index in stride(from: 3, to: after.count, by: 4) {
                #expect(abs(after[index] - before[index]) < 0.002)
            }
            let selectedOffset = 8
            let selectedDifference = (0..<3).reduce(0.0) { difference, component in
                difference + Double(abs(
                    after[selectedOffset + component] - before[selectedOffset + component]
                ))
            }
            #expect(selectedDifference > 0.02)
        }
    }

    @Test func pointColorSamplingStopsBeforePointColorAndLaterEffects() async throws {
        let url = TestImage.writePattern(size: 96)
        defer { try? FileManager.default.removeItem(at: url) }

        var inputSettings = DevelopSettings()
        // Keep the sampled yellow nominal while still exercising a pre-Point-
        // Color adjustment; extended samples are intentionally not selectable.
        inputSettings.exposure = -0.1
        inputSettings.cropX = 0.15
        inputSettings.cropW = 0.5
        inputSettings.rotationQuarterTurns = 1
        inputSettings.straighten = 8
        inputSettings.geometryVertical = 0.25
        inputSettings.geometryScale = 1.1
        let input = try await pipeline.renderPointColorSamplingPreview(
            fileURL: url, settings: inputSettings, maxPixelSize: 96)
        var noGeometry = inputSettings
        noGeometry.cropX = 0
        noGeometry.cropW = 1
        noGeometry.rotationQuarterTurns = 0
        noGeometry.straighten = 0
        noGeometry.geometryVertical = 0
        noGeometry.geometryScale = 1
        let sourceStage = try await pipeline.renderPointColorSamplingPreview(
            fileURL: url,
            settings: noGeometry,
            maxPixelSize: 96
        )
        #expect(input.cgImage.width == sourceStage.cgImage.width)
        #expect(input.cgImage.height == sourceStage.cgImage.height)
        #expect(TestImage.rgba(input.cgImage) == TestImage.rgba(sourceStage.cgImage))
        let sampledColor = try #require(PointColorImageSampler.extendedLinearDisplayP3(
            in: input.cgImage,
            at: NormalizedPoint(x: 0.5, y: 0.5)
        ))
        let reference = ColorCubeEngine.pointColorReference(
            red: sampledColor.x,
            green: sampledColor.y,
            blue: sampledColor.z
        )

        var laterSettings = inputSettings
        laterSettings.pointColors = [PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: reference.hue,
            hueShift: 0.8,
            saturationShift: -0.7,
            luminanceShift: 0.7,
            range: 1,
            hueRange: 1,
            chromaRange: 1,
            luminanceRange: 1
        )]
        laterSettings.grade.globalHue = 0.7
        laterSettings.grade.globalSat = 0.8
        laterSettings.dehaze = 0.8
        laterSettings.vibrance = 0.7
        laterSettings.vignette = -0.8
        laterSettings.masks = [LocalMask(
            components: [MaskComponent(shape: .radial(
                center: NormalizedPoint(x: 0.5, y: 0.5),
                radiusX: 0.4,
                radiusY: 0.4,
                angle: 0,
                feather: 0.2,
                inverted: false
            ))],
            adjustments: LocalAdjustments(exposure: 0.8)
        )]

        let laterSample = try await pipeline.renderPointColorSamplingPreview(
            fileURL: url, settings: laterSettings, maxPixelSize: 96)
        #expect(laterSample.cgImage.width == input.cgImage.width)
        #expect(laterSample.cgImage.height == input.cgImage.height)
        #expect(TestImage.rgba(laterSample.cgImage) == TestImage.rgba(input.cgImage))
        #expect(laterSample.cgImage.colorSpace?.name
            == CGColorSpace.extendedLinearDisplayP3)

        let before = try await pipeline.renderPreview(
            fileURL: url, settings: inputSettings, maxPixelSize: 96)
        let after = try await pipeline.renderPreview(
            fileURL: url, settings: laterSettings, maxPixelSize: 96)
        #expect(TestImage.meanAbsoluteDifference(before.cgImage, after.cgImage) > 0.02)
    }

    @Test func narrowPointColorSelectionChangesAnOffGridSample() async throws {
        let url = TestImage.writeColor((0.413, 0.527, 0.219), size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)
        let sampling = try await pipeline.renderPointColorSamplingPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)
        let sampledColor = try #require(PointColorImageSampler.extendedLinearDisplayP3(
            in: sampling.cgImage,
            at: NormalizedPoint(x: 0.5, y: 0.5)
        ))
        let reference = ColorCubeEngine.pointColorReference(
            red: sampledColor.x,
            green: sampledColor.y,
            blue: sampledColor.z
        )
        var settings = DevelopSettings()
        settings.pointColors = [PointColorAdjustment(
            luminance: reference.luminance,
            chroma: reference.chroma,
            hue: reference.hue,
            hueShift: 1,
            saturationShift: -0.8,
            luminanceShift: 0.8,
            range: 0,
            hueRange: 0,
            chromaRange: 0,
            luminanceRange: 0
        )]

        let adjusted = try await pipeline.renderPreview(
            fileURL: url, settings: settings, maxPixelSize: 64)
        #expect(TestImage.meanAbsoluteDifference(baseline.cgImage, adjusted.cgImage) > 0.002)
    }

    @Test func brushLinearAndRadialMasksLimitExposureSpatially() async throws {
        let url = TestImage.writeGrey(92, size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let exposure = LocalAdjustments(exposure: 0.8)
        let masks = [
            LocalMask(
                components: [MaskComponent(shape: .brush(strokes: [BrushStroke(
                    points: [NormalizedPoint(x: 0.5, y: 0.5)],
                    size: 0.18,
                    feather: 0.35
                )]))],
                adjustments: exposure
            ),
            LocalMask(
                components: [MaskComponent(shape: .linear(
                    start: NormalizedPoint(x: 0, y: 0.5),
                    end: NormalizedPoint(x: 1, y: 0.5)
                ))],
                adjustments: exposure
            ),
            LocalMask(
                components: [MaskComponent(shape: .radial(
                    center: NormalizedPoint(x: 0.5, y: 0.5),
                    radiusX: 0.25,
                    radiusY: 0.25,
                    angle: 0,
                    feather: 0.35,
                    inverted: false
                ))],
                adjustments: exposure
            ),
        ]

        for (index, mask) in masks.enumerated() {
            var settings = DevelopSettings()
            settings.masks = [mask]
            let rendered = try await pipeline.renderPreview(
                fileURL: url, settings: settings, maxPixelSize: 64)
            switch index {
            case 0, 2:
                #expect(TestImage.luminance(rendered.cgImage, x: 32, y: 32)
                    > TestImage.luminance(rendered.cgImage, x: 4, y: 4) + 0.12)
            default:
                #expect(TestImage.luminance(rendered.cgImage, x: 56, y: 32)
                    > TestImage.luminance(rendered.cgImage, x: 8, y: 32) + 0.12)
            }
        }
    }

    @Test func verticalAndRotatedMasksPreserveTopLeftDirection() async throws {
        let url = TestImage.writeGrey(92, size: 64)
        defer { try? FileManager.default.removeItem(at: url) }

        var linearSettings = DevelopSettings()
        linearSettings.masks = [LocalMask(
            components: [MaskComponent(shape: .linear(
                start: NormalizedPoint(x: 0.5, y: 0),
                end: NormalizedPoint(x: 0.5, y: 1)
            ))],
            adjustments: LocalAdjustments(exposure: 0.8)
        )]
        let linear = try await pipeline.renderPreview(
            fileURL: url, settings: linearSettings, maxPixelSize: 64)
        #expect(TestImage.luminance(linear.cgImage, x: 32, y: 56)
            > TestImage.luminance(linear.cgImage, x: 32, y: 8) + 0.12)

        var radialSettings = DevelopSettings()
        radialSettings.masks = [LocalMask(
            components: [MaskComponent(shape: .radial(
                center: NormalizedPoint(x: 0.5, y: 0.5),
                radiusX: 0.3,
                radiusY: 0.08,
                angle: 45,
                feather: 0.2,
                inverted: false
            ))],
            adjustments: LocalAdjustments(exposure: 0.8)
        )]
        let radial = try await pipeline.renderPreview(
            fileURL: url, settings: radialSettings, maxPixelSize: 64)
        #expect(TestImage.luminance(radial.cgImage, x: 42, y: 42)
            > TestImage.luminance(radial.cgImage, x: 42, y: 22) + 0.12)
    }

    @Test func localAmountScalesParametersInsteadOfMaskOpacity() async throws {
        let url = TestImage.writeGrey(92, size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)

        func settings(exposure: Double, amount: Double) -> DevelopSettings {
            var settings = DevelopSettings()
            settings.masks = [LocalMask(
                components: [MaskComponent(shape: .radial(
                    center: NormalizedPoint(x: 0.5, y: 0.5),
                    radiusX: 1,
                    radiusY: 1,
                    angle: 0,
                    feather: 0,
                    inverted: false
                ))],
                adjustments: LocalAdjustments(exposure: exposure, amount: amount)
            )]
            return settings
        }

        let scaled = try await pipeline.renderPreview(
            fileURL: url, settings: settings(exposure: 0.4, amount: 0.5),
            maxPixelSize: 64)
        let direct = try await pipeline.renderPreview(
            fileURL: url, settings: settings(exposure: 0.2, amount: 1),
            maxPixelSize: 64)
        #expect(TestImage.rgba(scaled.cgImage) == TestImage.rgba(direct.cgImage))

        let zero = try await pipeline.renderPreview(
            fileURL: url, settings: settings(exposure: 1, amount: 0),
            maxPixelSize: 64)
        #expect(TestImage.rgba(zero.cgImage) == TestImage.rgba(baseline.cgImage))

        var neutral = DevelopSettings()
        neutral.masks = [LocalMask(
            components: [MaskComponent(shape: .linear(
                start: NormalizedPoint(x: 0, y: 0),
                end: NormalizedPoint(x: 1, y: 1)
            ))],
            adjustments: LocalAdjustments(amount: 2)
        )]
        let neutralRender = try await pipeline.renderPreview(
            fileURL: url, settings: neutral, maxPixelSize: 64)
        #expect(TestImage.rgba(neutralRender.cgImage) == TestImage.rgba(baseline.cgImage))
    }

    @Test func cloneCopiesTheConfiguredSourceIntoTheTarget() async throws {
        let url = TestImage.writeSplitColor(size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)
        var settings = DevelopSettings()
        settings.spots = [SpotCorrection(
            mode: .clone,
            points: [NormalizedPoint(x: 0.75, y: 0.5)],
            size: 0.15,
            feather: 0.2,
            sourceOffset: NormalizedVector(dx: -0.5, dy: 0)
        )]
        let cloned = try await pipeline.renderPreview(
            fileURL: url, settings: settings, maxPixelSize: 64)
        let before = TestImage.rgb(baseline.cgImage, x: 48, y: 32)
        let after = TestImage.rgb(cloned.cgImage, x: 48, y: 32)
        #expect(after.x > before.x + 0.35)
        #expect(after.z < before.z - 0.35)
    }

    @Test func spotCountAndOutOfFrameSourceSamplingAreIgnored() async throws {
        let url = TestImage.writePattern(size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)

        var outOfFrame = DevelopSettings()
        outOfFrame.spots = [SpotCorrection(
            mode: .clone,
            points: [NormalizedPoint(x: 0.5, y: 0.5)],
            size: 0.1,
            feather: 0.2,
            sourceOffset: NormalizedVector(dx: 0, dy: -0.75)
        )]
        let invalidSource = try await pipeline.renderPreview(
            fileURL: url, settings: outOfFrame, maxPixelSize: 64)
        #expect(TestImage.rgba(invalidSource.cgImage) == TestImage.rgba(baseline.cgImage))

        var overLimit = DevelopSettings()
        overLimit.spots = Array(
            repeating: SpotCorrection(opacity: 0),
            count: SpotCorrection.maximumCount
        )
        overLimit.spots.append(SpotCorrection(
            mode: .clone,
            points: [NormalizedPoint(x: 0.75, y: 0.5)],
            size: 0.1,
            sourceOffset: NormalizedVector(dx: -0.5, dy: 0)
        ))
        let bounded = try await pipeline.renderPreview(
            fileURL: url, settings: overLimit, maxPixelSize: 64)
        #expect(TestImage.rgba(bounded.cgImage) == TestImage.rgba(baseline.cgImage))
    }

    @Test func healAndRemoveSoftenBlemishWithinTheConfiguredPath() async throws {
        let url = TestImage.writeBlemish(size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)
        let baselineCenter = TestImage.luminance(baseline.cgImage, x: 48, y: 32)
        let baselineOutside = TestImage.rgb(baseline.cgImage, x: 6, y: 6)

        for mode in [SpotMode.heal, .remove] {
            var settings = DevelopSettings()
            settings.spots = [SpotCorrection(
                mode: mode,
                points: [NormalizedPoint(x: 0.75, y: 0.5)],
                size: 0.14,
                feather: 0.3,
                sourceOffset: NormalizedVector(dx: -0.5, dy: 0)
            )]
            let corrected = try await pipeline.renderPreview(
                fileURL: url, settings: settings, maxPixelSize: 64)
            #expect(TestImage.luminance(corrected.cgImage, x: 48, y: 32)
                > baselineCenter + 0.08)
            let outside = TestImage.rgb(corrected.cgImage, x: 6, y: 6)
            #expect(abs(outside.x - baselineOutside.x)
                + abs(outside.y - baselineOutside.y)
                + abs(outside.z - baselineOutside.z) < 0.02)
        }
    }

    @Test func redEyeLowersRedDominanceAndPreservesOutside() async throws {
        let url = TestImage.writeRedEye(size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)
        var settings = DevelopSettings()
        settings.redEyes = [RedEyeCorrection(
            center: NormalizedPoint(x: 0.5, y: 0.5),
            radiusX: 0.18,
            radiusY: 0.18,
            pupilSize: 1,
            darken: 0.6
        )]
        let corrected = try await pipeline.renderPreview(
            fileURL: url, settings: settings, maxPixelSize: 64)

        let beforeCenter = TestImage.rgb(baseline.cgImage, x: 32, y: 32)
        let afterCenter = TestImage.rgb(corrected.cgImage, x: 32, y: 32)
        #expect(RedEyeMath.redDominance(
            red: afterCenter.x, green: afterCenter.y, blue: afterCenter.z)
            < RedEyeMath.redDominance(
                red: beforeCenter.x, green: beforeCenter.y, blue: beforeCenter.z) - 0.25)
        let beforeOutside = TestImage.rgb(baseline.cgImage, x: 5, y: 5)
        let afterOutside = TestImage.rgb(corrected.cgImage, x: 5, y: 5)
        #expect(abs(afterOutside.x - beforeOutside.x)
            + abs(afterOutside.y - beforeOutside.y)
            + abs(afterOutside.z - beforeOutside.z) < 0.02)
    }

    @Test func petEyeDarkensThePupilAndRestoresAnOptionalCatchlight() async throws {
        let url = TestImage.writePetEye(size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 64)

        var darkSettings = DevelopSettings()
        darkSettings.redEyes = [RedEyeCorrection(
            center: NormalizedPoint(x: 0.5, y: 0.5),
            radiusX: 0.18,
            radiusY: 0.18,
            pupilSize: 1,
            darken: 1,
            petEye: true
        )]
        let darkened = try await pipeline.renderPreview(
            fileURL: url, settings: darkSettings, maxPixelSize: 64)

        var catchlightSettings = DevelopSettings()
        catchlightSettings.redEyes = [RedEyeCorrection(
            center: NormalizedPoint(x: 0.5, y: 0.5),
            radiusX: 0.18,
            radiusY: 0.18,
            pupilSize: 1,
            darken: 1,
            petEye: true,
            catchlight: NormalizedVector(dx: 0, dy: 0)
        )]
        let withCatchlight = try await pipeline.renderPreview(
            fileURL: url, settings: catchlightSettings, maxPixelSize: 64)

        let baselineCenter = TestImage.luminance(baseline.cgImage, x: 32, y: 32)
        let darkCenter = TestImage.luminance(darkened.cgImage, x: 32, y: 32)
        let catchlightCenter = TestImage.luminance(withCatchlight.cgImage, x: 32, y: 32)
        #expect(darkCenter < baselineCenter - 0.15)
        #expect(catchlightCenter > darkCenter + 0.25)

        let baselineOutside = TestImage.rgb(baseline.cgImage, x: 5, y: 5)
        let darkOutside = TestImage.rgb(darkened.cgImage, x: 5, y: 5)
        #expect(abs(darkOutside.x - baselineOutside.x)
            + abs(darkOutside.y - baselineOutside.y)
            + abs(darkOutside.z - baselineOutside.z) < 0.02)
    }

    @Test func spatialMaskRemainsAlignedWhenUserCropIsApplied() async throws {
        let url = TestImage.writeGrey(90, size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = DevelopSettings()
        settings.cropW = 0.5
        settings.masks = [LocalMask(
            components: [MaskComponent(shape: .radial(
                center: NormalizedPoint(x: 0.25, y: 0.5),
                radiusX: 0.12,
                radiusY: 0.2,
                angle: 0,
                feather: 0.25,
                inverted: false
            ))],
            adjustments: LocalAdjustments(exposure: 0.9)
        )]
        let rendered = try await pipeline.renderPreview(
            fileURL: url, settings: settings, maxPixelSize: 64)
        #expect(rendered.cgImage.width * 2 == rendered.cgImage.height)
        #expect(TestImage.luminance(rendered.cgImage, x: 32, y: 32)
            > TestImage.luminance(rendered.cgImage, x: 7, y: 32) + 0.1)
    }

    @Test func exportWritesValidJPEG() async throws {
        let url = TestImage.writeGrey()
        defer { try? FileManager.default.removeItem(at: url) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }

        var opts = ExportOptions(); opts.format = .jpeg; opts.maxPixelSize = 256
        let written = try await pipeline.export(
            fileURL: url, settings: DevelopSettings(), options: opts, to: out)
        #expect(FileManager.default.fileExists(atPath: written.path))
        // Decodes back as an image.
        let src = CGImageSourceCreateWithURL(written as CFURL, nil)
        #expect(src != nil)
        #expect(CGImageSourceCreateImageAtIndex(src!, 0, nil) != nil)
    }
}

@MainActor
struct RecipeDocumentTests {

    @Test func buildAndApplyRoundTrip() throws {
        let fp = ImageFingerprint(filename: "t.jpg", fileSizeBytes: 10)
        let asset = ImageAsset(originalFilename: "t.jpg", storageMode: .managed,
                               fingerprint: fp, fileSizeBytes: 10)
        asset.develop.exposure = 0.4
        asset.develop.grade.highSat = 0.5
        asset.rating = 3
        asset.flag = .picked

        let doc = RecipeDocument(asset: asset)
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(RecipeDocument.self, from: data)

        let target = ImageAsset(originalFilename: "t.jpg", storageMode: .managed,
                                fingerprint: fp, fileSizeBytes: 10)
        decoded.apply(to: target)
        #expect(target.develop.exposure == 0.4)
        #expect(target.develop.grade.highSat == 0.5)
        #expect(target.rating == 3)
        #expect(target.flag == .picked)
        #expect(doc.format == "com.rawlight.recipe")
        #expect(doc.parameters["foundation.exposureEV"] == 1.0) // 0.4 * 2.5
    }

    @Test func applyClampsUntrustedMetadata() {
        let fingerprint = ImageFingerprint(filename: "t.jpg", fileSizeBytes: 10)
        let source = ImageAsset(
            originalFilename: "t.jpg",
            storageMode: .managed,
            fingerprint: fingerprint,
            fileSizeBytes: 10
        )
        var document = RecipeDocument(asset: source)
        document.rating = 99
        document.flag = 99
        document.colorLabel = -4

        let target = ImageAsset(
            originalFilename: "t.jpg",
            storageMode: .managed,
            fingerprint: fingerprint,
            fileSizeBytes: 10
        )
        document.apply(to: target)

        #expect(target.rating == 5)
        #expect(target.flag == .unflagged)
        #expect(target.colorLabel == 0)
    }
}

@Suite(.serialized)
struct LibraryLayoutTests {

    private func createCatalogStore(in generation: URL) throws {
        let catalog = generation
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let configuration = ModelConfiguration(schema: CatalogStore.schema, url: catalog)
        _ = try ModelContainer(for: CatalogStore.schema, configurations: [configuration])

        let generationID = try #require(UUID(uuidString: generation.lastPathComponent))
        let completion = """
        { "schemaVersion": 1, "generationID": "\(generationID.uuidString)" }
        """
        try Data(completion.utf8).write(
            to: catalog.deletingLastPathComponent()
                .appendingPathComponent("Catalog.complete.json"),
            options: [.atomic]
        )
    }

    private func withTemporaryLibrary<T>(
        _ operation: (_ appRoot: URL, _ cacheRoot: URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-LibraryTests-\(UUID().uuidString)", isDirectory: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-CacheTests-\(UUID().uuidString)", isDirectory: true)
        LibraryLocations.configureRoots(appRoot: root, cacheRoot: cache)
        defer {
            LibraryLocations.resetConfiguredRoots()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache)
        }
        return try operation(root, cache)
    }

    @MainActor
    private func withTemporaryLibraryAsync<T>(
        _ operation: (_ appRoot: URL, _ cacheRoot: URL) async throws -> T
    ) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-LibraryTests-\(UUID().uuidString)", isDirectory: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-CacheTests-\(UUID().uuidString)", isDirectory: true)
        LibraryLocations.configureRoots(appRoot: root, cacheRoot: cache)
        defer {
            LibraryLocations.resetConfiguredRoots()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache)
        }
        return try await operation(root, cache)
    }

    @Test func relativePathRoundTrips() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let id = UUID()
            let url = LibraryLocations.managedOriginalURL(assetID: id, fileExtension: "raf")
            let rel = try LibraryLocations.relativePath(of: url)
            let resolved = try LibraryLocations.url(forManagedRelativePath: rel)
            #expect(resolved.path == url.path)
            #expect(rel.hasPrefix("Originals/"))
        }
    }

    @Test func bootstrapCreatesGenerationTree() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: LibraryLocations.originals.path))
            #expect(fm.fileExists(atPath: LibraryLocations.incoming.path))
            #expect(fm.fileExists(atPath: LibraryLocations.recipes.path))
            #expect(fm.fileExists(atPath: LibraryLocations.trash.path))
            #expect(fm.fileExists(atPath: LibraryLocations.thumbnailsCache.path))
        }
    }

    @Test func bootstrapReusesPointerGeneration() throws {
        try withTemporaryLibrary { root, cache in
            let first = try {
                let firstResult = CatalogStore.makeContainer()
                try #require(firstResult.failure == nil)
                return try #require(UUID(
                    uuidString: LibraryLocations.currentGeneration.lastPathComponent
                ))
            }()
            LibraryLocations.resetConfiguredRoots()
            LibraryLocations.configureRoots(appRoot: root, cacheRoot: cache)
            let secondResult = CatalogStore.makeContainer()
            try #require(secondResult.failure == nil)
            let second = try #require(UUID(
                uuidString: LibraryLocations.currentGeneration.lastPathComponent
            ))
            #expect(second == first)
        }
    }

    @Test func corruptPointerRecoversExistingGeneration() throws {
        try withTemporaryLibrary { root, _ in
            let expected = UUID()
            let generation = root
                .appendingPathComponent("Libraries", isDirectory: true)
                .appendingPathComponent(expected.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
            try createCatalogStore(in: generation)
            try Data("not-json".utf8).write(
                to: root.appendingPathComponent("CurrentLibrary.json")
            )

            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            let recovered = try #require(UUID(
                uuidString: LibraryLocations.currentGeneration.lastPathComponent
            ))
            #expect(recovered == expected)
            let rewritten = try String(
                contentsOf: root.appendingPathComponent("CurrentLibrary.json"),
                encoding: .utf8
            )
            #expect(rewritten.contains(expected.uuidString))
            #expect(rewritten.contains("checksum"))
        }
    }

    @Test func recoveryRejectsGenerationWithoutCatalog() throws {
        try withTemporaryLibrary { root, _ in
            let generation = root
                .appendingPathComponent("Libraries", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(
                to: root.appendingPathComponent("CurrentLibrary.json")
            )

            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.bootstrap()
            }
        }
    }

    @Test func recoveryRejectsAmbiguousCatalogGenerations() throws {
        try withTemporaryLibrary { root, _ in
            for _ in 0..<2 {
                let generation = root
                    .appendingPathComponent("Libraries", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try createCatalogStore(in: generation)
            }

            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.bootstrap()
            }
        }
    }

    @Test func unsupportedPointerVersionIsNotOverwritten() throws {
        try withTemporaryLibrary { root, _ in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let pointer = """
            { "schemaVersion": 999, "generationID": "\(UUID().uuidString)" }
            """
            try Data(pointer.utf8).write(to: root.appendingPathComponent("CurrentLibrary.json"))

            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.bootstrap()
            }
        }
    }

    @Test func managedPathsRejectTraversalAndExternalFiles() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("outside-\(UUID().uuidString).raw")
            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.relativePath(of: outside)
            }
            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.url(forManagedRelativePath: "../outside.raw")
            }
            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.url(forManagedRelativePath: "/tmp/outside.raw")
            }
        }
    }

    @Test func managedPathsEnforceNamespaceOwnershipAndSymlinkContainment() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let assetID = UUID()
            let relative = "Originals/\(assetID.uuidString)/primary.raf"

            #expect(try LibraryLocations.url(
                forManagedRelativePath: relative,
                expectedAssetID: assetID
            ).lastPathComponent == "primary.raf")
            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.url(
                    forManagedRelativePath: relative,
                    expectedAssetID: UUID()
                )
            }

            for invalid in [
                "Recipes/\(assetID.uuidString)/primary.raf",
                "Originals/\(assetID.uuidString)/preview.raf",
                "Originals/\(assetID.uuidString)/primary.tar.gz",
            ] {
                #expect(throws: LibraryLocations.LocationError.self) {
                    try LibraryLocations.url(forManagedRelativePath: invalid)
                }
            }

            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("RawLight-Outside-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("raw".utf8).write(to: outside.appendingPathComponent("primary.raf"))
            try FileManager.default.createSymbolicLink(
                at: LibraryLocations.managedOriginalDirectory(assetID: assetID),
                withDestinationURL: outside
            )

            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.url(forManagedRelativePath: relative)
            }
        }
    }

    @MainActor
    @Test func recipeStoreRoundTripsAndReportsCorruption() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let asset = ImageAsset(
                originalFilename: "recipe.jpg",
                storageMode: .managed,
                fingerprint: ImageFingerprint(filename: "recipe.jpg", fileSizeBytes: 12),
                fileSizeBytes: 12
            )
            asset.develop.exposure = 0.4
            asset.rating = 4
            try RecipeStore.write(for: asset)

            let restored = try RecipeStore.read(assetID: asset.id)
            #expect(restored?.develop.exposure == 0.4)
            #expect(restored?.rating == 4)

            try Data("{}".utf8).write(
                to: LibraryLocations.recipeURL(assetID: asset.id),
                options: .atomic
            )
            #expect(throws: DecodingError.self) {
                try RecipeStore.read(assetID: asset.id)
            }
        }
    }

    @MainActor
    @Test func recipeStoreRejectsMismatchedIdentityVersionAndSource() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let asset = ImageAsset(
                originalFilename: "recipe.jpg",
                storageMode: .managed,
                fingerprint: ImageFingerprint(filename: "recipe.jpg", fileSizeBytes: 12),
                fileSizeBytes: 12
            )
            asset.contentDigest = "sha256:source"
            let recipeURL = LibraryLocations.recipeURL(assetID: asset.id)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            func write(_ document: RecipeDocument) throws {
                try encoder.encode(document).write(to: recipeURL, options: .atomic)
            }

            try RecipeStore.write(for: asset)
            #expect(try RecipeStore.read(
                assetID: asset.id,
                sourceContentDigest: "sha256:source"
            ) != nil)
            #expect(throws: RecipeStore.RecipeError.self) {
                try RecipeStore.read(assetID: asset.id, sourceContentDigest: "sha256:other")
            }

            let valid = RecipeDocument(asset: asset)
            var wrongRecipeID = valid
            wrongRecipeID.recipeID = UUID()
            var wrongAssetID = valid
            wrongAssetID.assetID = UUID()
            var wrongResourceID = valid
            wrongResourceID.editablePrimaryResourceID = UUID()
            for document in [wrongRecipeID, wrongAssetID, wrongResourceID] {
                try write(document)
                #expect(throws: RecipeStore.RecipeError.self) {
                    try RecipeStore.read(assetID: asset.id)
                }
            }

            var unsupportedFormat = valid
            unsupportedFormat.format = "example.unsupported"
            try write(unsupportedFormat)
            #expect(throws: RecipeStore.RecipeError.self) {
                try RecipeStore.read(assetID: asset.id)
            }

            var unsupportedVersion = valid
            unsupportedVersion.schemaVersion = 999
            try write(unsupportedVersion)
            #expect(throws: RecipeStore.RecipeError.self) {
                try RecipeStore.read(assetID: asset.id)
            }
        }
    }

    @MainActor
    @Test func recipeStoreRejectsOversizedDocument() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let assetID = UUID()
            try Data(repeating: 0, count: 4 * 1024 * 1024 + 1).write(
                to: LibraryLocations.recipeURL(assetID: assetID),
                options: .atomic
            )
            #expect(throws: RecipeStore.RecipeError.self) {
                try RecipeStore.read(assetID: assetID)
            }
        }
    }

    @MainActor
    @Test func persistenceWritersNormalizeSelectiveEditsWithoutMutatingSources() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let asset = ImageAsset(
                originalFilename: "bounded.jpg",
                storageMode: .managed,
                fingerprint: ImageFingerprint(filename: "bounded.jpg", fileSizeBytes: 1),
                fileSizeBytes: 1
            )
            let point = NormalizedPoint(x: 0.25, y: 0.75)
            let overLimitSpots = Array(
                repeating: SpotCorrection(points: [point]),
                count: SpotCorrection.maximumCount + 1
            )
            asset.develop.spots = overLimitSpots

            let snapshot = RecipeDocument(asset: asset)
            #expect(snapshot.develop.spots.count == SpotCorrection.maximumCount)
            #expect(asset.develop.spots.count == SpotCorrection.maximumCount + 1)

            var directDocument = snapshot
            directDocument.develop.spots = overLimitSpots
            try RecipeStore.write(directDocument)
            let storedRecipe = try RecipeStore.read(assetID: asset.id)
            let recipe = try #require(storedRecipe)
            #expect(recipe.develop.spots.count == SpotCorrection.maximumCount)
            #expect(directDocument.develop.spots.count == SpotCorrection.maximumCount + 1)

            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent("bounded-sidecar-\(UUID().uuidString).raw")
            try Data([1]).write(to: source)
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: SidecarService.sidecarURL(for: source))
            }
            let sidecar = Sidecar(
                fingerprint: ImageFingerprint(filename: source.lastPathComponent, fileSizeBytes: 1),
                develop: {
                    var settings = DevelopSettings()
                    settings.spots = overLimitSpots
                    return settings
                }(),
                rating: 0,
                flag: 0,
                colorLabel: 0
            )
            try SidecarService.write(sidecar, for: source)
            let storedSidecar = try SidecarService.read(for: source)
            let restoredSidecar = try #require(storedSidecar)
            #expect(restoredSidecar.develop.spots.count == SpotCorrection.maximumCount)
            #expect(sidecar.develop.spots.count == SpotCorrection.maximumCount + 1)
        }
    }

    @MainActor
    @Test func recipeWriterRejectsOversizedOutputWithoutReplacingExistingFile() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let asset = ImageAsset(
                originalFilename: "oversized.jpg",
                storageMode: .managed,
                fingerprint: ImageFingerprint(filename: "oversized.jpg", fileSizeBytes: 1),
                fileSizeBytes: 1
            )
            let valid = RecipeDocument(asset: asset)
            try RecipeStore.write(valid)
            let url = LibraryLocations.recipeURL(assetID: asset.id)
            let existingData = try Data(contentsOf: url)

            var oversized = valid
            oversized.sourceContentDigest = String(repeating: "x", count: 4 * 1024 * 1024)
            do {
                try RecipeStore.write(oversized)
                Issue.record("An oversized recipe write was accepted")
            } catch let error as RecipeStore.RecipeError {
                #expect(error == .fileTooLarge)
            }

            #expect(try Data(contentsOf: url) == existingData)
        }
    }

    @Test func sidecarRoundTripsAndRejectsUnsupportedVersion() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString).jpg")
        try Data([1]).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: SidecarService.sidecarURL(for: source))
        }
        let fingerprint = ImageFingerprint(filename: source.lastPathComponent, fileSizeBytes: 1)
        let digest = try ContentDigest.sha256(of: source)
        var sidecar = Sidecar(
            fingerprint: fingerprint,
            sourceContentDigest: digest,
            develop: DevelopSettings(),
            rating: 3,
            flag: PickFlag.picked.rawValue,
            colorLabel: 2
        )
        sidecar.develop.exposure = 0.25
        try SidecarService.write(sidecar, for: source)

        let restored = try SidecarService.read(for: source)
        #expect(restored?.fingerprint == fingerprint)
        #expect(restored?.sourceContentDigest == digest)
        #expect(restored?.develop.exposure == 0.25)
        #expect(restored?.rating == 3)

        let legacyJSON = """
        {
          "schemaVersion": 1,
          "fingerprint": {
            "filename": "\(source.lastPathComponent)",
            "fileSizeBytes": 1
          },
          "develop": {},
          "rating": 2,
          "flag": 0,
          "colorLabel": 0
        }
        """
        try Data(legacyJSON.utf8).write(
            to: SidecarService.sidecarURL(for: source),
            options: .atomic
        )
        let legacy = try SidecarService.read(for: source)
        #expect(legacy?.sourceContentDigest == nil)

        sidecar.schemaVersion = 2
        try JSONEncoder().encode(sidecar).write(
            to: SidecarService.sidecarURL(for: source),
            options: .atomic
        )
        #expect(throws: SidecarService.SidecarError.self) {
            try SidecarService.read(for: source)
        }
    }

    @Test func sidecarWriterRejectsOversizedOutputWithoutReplacingExistingFile() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-sidecar-\(UUID().uuidString).raw")
        let sidecarURL = SidecarService.sidecarURL(for: source)
        try Data([1]).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: sidecarURL)
        }

        let valid = Sidecar(
            fingerprint: ImageFingerprint(filename: source.lastPathComponent, fileSizeBytes: 1),
            develop: DevelopSettings(),
            rating: 2,
            flag: 0,
            colorLabel: 0
        )
        try SidecarService.write(valid, for: source)
        let existingData = try Data(contentsOf: sidecarURL)

        var oversized = valid
        oversized.sourceContentDigest = String(repeating: "x", count: 2 * 1024 * 1024)
        do {
            try SidecarService.write(oversized, for: source)
            Issue.record("An oversized sidecar write was accepted")
        } catch let error as SidecarService.SidecarError {
            guard case .fileTooLarge = error else {
                Issue.record("Unexpected sidecar error: \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: sidecarURL) == existingData)
    }

    @Test func trashReceiptRestoresOriginalAndRecipe() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let id = UUID()
            let original = LibraryLocations.managedOriginalURL(assetID: id, fileExtension: "raf")
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("raw".utf8).write(to: original)
            let recipe = LibraryLocations.recipeURL(assetID: id)
            try Data("recipe".utf8).write(to: recipe)
            let relative = try LibraryLocations.relativePath(of: original)

            let receipt = try LibraryTrash.moveManagedAsset(
                id: id,
                originalFilename: "photo.raf",
                managedRelativePath: relative
            )
            #expect(!FileManager.default.fileExists(atPath: original.path))
            #expect(!FileManager.default.fileExists(atPath: recipe.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: LibraryLocations.trash.path).count == 1)

            try receipt.restore()
            #expect(FileManager.default.fileExists(atPath: original.path))
            #expect(FileManager.default.fileExists(atPath: recipe.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: LibraryLocations.trash.path).isEmpty)
        }
    }

    @MainActor
    @Test func managedImportCopiesWritesRecipeAndDeduplicates() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let source = TestImage.writeGrey(110, size: 96)
            defer { try? FileManager.default.removeItem(at: source) }
            let container = CatalogStore.makeInMemoryContainer()
            let context = container.mainContext
            let importer = ImportService(modelContext: context)

            let first = await importer.importFiles([source], into: nil)
            #expect(first.imported == 1)
            #expect(first.skipped == 0)
            #expect(first.failed == 0)

            let assets = try context.fetch(FetchDescriptor<ImageAsset>())
            #expect(assets.count == 1)
            let asset = try #require(assets.first)
            let relative = try #require(asset.managedRelativePath)
            let managed = try LibraryLocations.url(forManagedRelativePath: relative)
            #expect(FileManager.default.fileExists(atPath: managed.path))
            #expect(try ContentDigest.sha256(of: managed) == asset.contentDigest)
            #expect(try RecipeStore.read(assetID: asset.id) != nil)

            let duplicate = await importer.importFiles([source], into: nil)
            #expect(duplicate.imported == 0)
            #expect(duplicate.skipped == 1)
            #expect(duplicate.failed == 0)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 1)
        }
    }

    @MainActor
    @Test func managedImportRestoresDigestMatchedSidecar() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let source = TestImage.writeGrey(110, size: 96)
            let sidecarURL = SidecarService.sidecarURL(for: source)
            defer {
                try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: sidecarURL)
            }
            let values = try source.resourceValues(forKeys: [.fileSizeKey])
            let digest = try ContentDigest.sha256(of: source)
            var develop = DevelopSettings()
            develop.exposure = 0.35
            try SidecarService.write(
                Sidecar(
                    fingerprint: ImageFingerprint(
                        filename: source.lastPathComponent,
                        fileSizeBytes: Int64(try #require(values.fileSize))
                    ),
                    sourceContentDigest: digest,
                    develop: develop,
                    rating: 4,
                    flag: PickFlag.picked.rawValue,
                    colorLabel: 3
                ),
                for: source
            )

            let container = CatalogStore.makeInMemoryContainer()
            let context = container.mainContext
            let summary = await ImportService(modelContext: context)
                .importFiles([source], into: nil)

            #expect(summary.imported == 1)
            #expect(summary.failed == 0)
            let asset = try #require(context.fetch(FetchDescriptor<ImageAsset>()).first)
            #expect(asset.develop.exposure == 0.35)
            #expect(asset.rating == 4)
            #expect(asset.flag == .picked)
            #expect(asset.colorLabel == 3)
            let restoredRecipe = try RecipeStore.read(
                assetID: asset.id,
                sourceContentDigest: digest
            )
            let recipe = try #require(restoredRecipe)
            #expect(recipe.develop.exposure == 0.35)
            #expect(recipe.rating == 4)
        }
    }

    @MainActor
    @Test func managedImportRejectsMismatchedAndWeakLegacySidecars() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let container = CatalogStore.makeInMemoryContainer()
            let context = container.mainContext
            let importer = ImportService(modelContext: context)

            let digestMismatch = TestImage.writeGrey(90, size: 64)
            let digestMismatchSidecar = SidecarService.sidecarURL(for: digestMismatch)
            defer {
                try? FileManager.default.removeItem(at: digestMismatch)
                try? FileManager.default.removeItem(at: digestMismatchSidecar)
            }
            let mismatchSize = try #require(
                digestMismatch.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
            try SidecarService.write(
                Sidecar(
                    fingerprint: ImageFingerprint(
                        filename: digestMismatch.lastPathComponent,
                        fileSizeBytes: Int64(mismatchSize)
                    ),
                    sourceContentDigest: "sha256:not-the-source",
                    develop: DevelopSettings(),
                    rating: 0,
                    flag: 0,
                    colorLabel: 0
                ),
                for: digestMismatch
            )
            let mismatchSummary = await importer.importFiles([digestMismatch], into: nil)
            #expect(mismatchSummary.failed == 1)
            #expect(mismatchSummary.imported == 0)

            let weakLegacy = TestImage.writeGrey(100, size: 64)
            let weakLegacySidecar = SidecarService.sidecarURL(for: weakLegacy)
            defer {
                try? FileManager.default.removeItem(at: weakLegacy)
                try? FileManager.default.removeItem(at: weakLegacySidecar)
            }
            let weakSize = try #require(
                weakLegacy.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
            try SidecarService.write(
                Sidecar(
                    fingerprint: ImageFingerprint(
                        filename: weakLegacy.lastPathComponent,
                        fileSizeBytes: Int64(weakSize)
                    ),
                    develop: DevelopSettings(),
                    rating: 0,
                    flag: 0,
                    colorLabel: 0
                ),
                for: weakLegacy
            )
            let weakSummary = await importer.importFiles([weakLegacy], into: nil)
            #expect(weakSummary.failed == 1)
            #expect(weakSummary.imported == 0)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 0)
        }
    }

    @MainActor
    private func makePreviewSource(
        filename: String
    ) throws -> (id: UUID, source: AssetFileAccess.Reference) {
        let id = UUID()
        let original = LibraryLocations.managedOriginalURL(
            assetID: id,
            fileExtension: "jpg"
        )
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1]).write(to: original)
        let asset = ImageAsset(
            id: id,
            originalFilename: filename,
            storageMode: .managed,
            fingerprint: ImageFingerprint(filename: filename, fileSizeBytes: 1),
            fileSizeBytes: 1
        )
        asset.managedRelativePath = try LibraryLocations.relativePath(of: original)
        return (id, AssetFileAccess.Reference(asset: asset))
    }

    @MainActor
    @Test func previewRasterizationSerializesAcrossRendererInstances() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let preview = try makePreviewSource(filename: "shared-preview.jpg")
            let pipeline = BlockingPreviewPipeline()
            let firstRenderer = DevelopPreviewRenderer()
            let secondRenderer = DevelopPreviewRenderer()
            var first = DevelopSettings()
            first.exposure = 0.1
            var second = DevelopSettings()
            second.exposure = 0.2

            firstRenderer.submit(
                assetID: preview.id,
                source: preview.source,
                settings: first,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .pointColorSampling
            )
            await pipeline.waitForCallCount(1)
            firstRenderer.cancel()
            #expect(firstRenderer.isRendering)
            secondRenderer.submit(
                assetID: preview.id,
                source: preview.source,
                settings: second,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .pointColorSampling
            )
            await PreviewRasterizationGate.shared.waitForQueuedRequest()

            let blocked = await pipeline.snapshot()
            let queuedCount = await PreviewRasterizationGate.shared.queuedRequestCount()
            #expect(blocked.exposures == [0.1])
            #expect(queuedCount >= 1)

            await pipeline.releaseFirst()
            await pipeline.waitForCallCount(2)
            await pipeline.waitForCompletionCount(2)
            while firstRenderer.isRendering || secondRenderer.isRendering {
                await Task.yield()
            }

            let completed = await pipeline.snapshot()
            #expect(completed.exposures == [0.1, 0.2])
            #expect(completed.maximumConcurrentCalls == 1)
            firstRenderer.cancel()
            secondRenderer.cancel()
        }
    }

    @MainActor
    @Test func previewFramesAndFailuresStayKeyedToRequestIdentity() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let preview = try makePreviewSource(filename: "keyed-preview.jpg")
            let pipeline = SequencedBlockingPreviewPipeline(outcomes: [.success, .failure])
            let renderer = DevelopPreviewRenderer()
            var after = DevelopSettings()
            after.exposure = 0.7
            let before = after.beforeSettings
            let afterIdentity = DevelopPreviewRequestIdentity(
                assetID: preview.id,
                settings: after,
                renderIntent: .display,
                interactivePixels: 128,
                settledPixels: 256
            )
            let beforeIdentity = DevelopPreviewRequestIdentity(
                assetID: preview.id,
                settings: before,
                renderIntent: .display,
                interactivePixels: 128,
                settledPixels: 256
            )

            renderer.submit(
                assetID: preview.id,
                source: preview.source,
                settings: after,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .display
            )
            await pipeline.waitForCallCount(1)
            await pipeline.release(call: 1)
            await pipeline.waitForCompletionCount(1)
            while renderer.isRendering { await Task.yield() }
            #expect(renderer.renderedImage(matching: afterIdentity) != nil)

            renderer.submit(
                assetID: preview.id,
                source: preview.source,
                settings: before,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .display
            )
            await pipeline.waitForCallCount(2)
            #expect(renderer.rendered == nil)
            #expect(renderer.renderedImage(matching: beforeIdentity) == nil)
            #expect(renderer.renderedImage(matching: afterIdentity) != nil)

            await pipeline.release(call: 2)
            await pipeline.waitForCompletionCount(2)
            while renderer.isRendering { await Task.yield() }
            #expect(renderer.failure?.identity == beforeIdentity)
            #expect(renderer.failureMessage(matching: beforeIdentity) != nil)
            #expect(renderer.failureMessage(matching: afterIdentity) == nil)
            #expect(renderer.rendered == nil)
            #expect(renderer.renderedImage(matching: beforeIdentity) == nil)
            renderer.cancel()
        }
    }

    @MainActor
    @Test func obsoleteSamplingFailureIsNotAcceptedByNewRequest() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let preview = try makePreviewSource(filename: "sampling-error-preview.jpg")
            let pipeline = SequencedBlockingPreviewPipeline(outcomes: [.failure, .success])
            let renderer = DevelopPreviewRenderer()
            var first = DevelopSettings()
            first.exposure = 0.1
            var second = DevelopSettings()
            second.exposure = 0.2
            let firstIdentity = DevelopPreviewRequestIdentity(
                assetID: preview.id,
                settings: first,
                renderIntent: .pointColorSampling,
                interactivePixels: 128,
                settledPixels: 256
            )
            let secondIdentity = DevelopPreviewRequestIdentity(
                assetID: preview.id,
                settings: second,
                renderIntent: .pointColorSampling,
                interactivePixels: 128,
                settledPixels: 256
            )

            renderer.submit(
                assetID: preview.id,
                source: preview.source,
                settings: first,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .pointColorSampling
            )
            await pipeline.waitForCallCount(1)
            renderer.submit(
                assetID: preview.id,
                source: preview.source,
                settings: second,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .pointColorSampling
            )
            await pipeline.release(call: 1)
            await pipeline.waitForCallCount(2)

            #expect(renderer.failureMessage(matching: firstIdentity) == nil)
            #expect(renderer.failureMessage(matching: secondIdentity) == nil)

            await pipeline.release(call: 2)
            await pipeline.waitForCompletionCount(2)
            while renderer.isRendering { await Task.yield() }
            #expect(renderer.failure == nil)
            #expect(renderer.renderedImage(matching: secondIdentity) != nil)
            renderer.cancel()
        }
    }

    @MainActor
    @Test func previewCancelKeepsBlockingWorkerSerialized() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let id = UUID()
            let original = LibraryLocations.managedOriginalURL(
                assetID: id,
                fileExtension: "jpg"
            )
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: original)
            let asset = ImageAsset(
                id: id,
                originalFilename: "blocking-preview.jpg",
                storageMode: .managed,
                fingerprint: ImageFingerprint(
                    filename: "blocking-preview.jpg",
                    fileSizeBytes: 1
                ),
                fileSizeBytes: 1
            )
            asset.managedRelativePath = try LibraryLocations.relativePath(of: original)
            let source = AssetFileAccess.Reference(asset: asset)
            let pipeline = BlockingPreviewPipeline()
            let renderer = DevelopPreviewRenderer()

            var first = DevelopSettings()
            first.exposure = 0.1
            renderer.submit(
                assetID: id,
                source: source,
                settings: first,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .pointColorSampling
            )
            await pipeline.waitForCallCount(1)
            #expect(renderer.isRendering)

            renderer.cancel()
            #expect(renderer.isRendering)

            var second = DevelopSettings()
            second.exposure = 0.2
            renderer.submit(
                assetID: id,
                source: source,
                settings: second,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .pointColorSampling
            )
            let queued = await pipeline.snapshot()
            #expect(queued.exposures == [0.1])

            await pipeline.releaseFirst()
            await pipeline.waitForCallCount(2)
            await pipeline.waitForCompletionCount(2)
            while renderer.isRendering { await Task.yield() }

            let completed = await pipeline.snapshot()
            #expect(completed.exposures == [0.1, 0.2])
            #expect(completed.maximumConcurrentCalls == 1)
            #expect(renderer.settledSettings == second)
            #expect(renderer.settledRenderIntent == .pointColorSampling)
            renderer.cancel()
        }
    }

    @MainActor
    @Test func previewRendererBoundsWorkAndKeepsLatestSettings() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let id = UUID()
            let original = LibraryLocations.managedOriginalURL(assetID: id, fileExtension: "jpg")
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: original)
            let asset = ImageAsset(
                id: id,
                originalFilename: "preview.jpg",
                storageMode: .managed,
                fingerprint: ImageFingerprint(filename: "preview.jpg", fileSizeBytes: 1),
                fileSizeBytes: 1
            )
            asset.managedRelativePath = try LibraryLocations.relativePath(of: original)
            let source = AssetFileAccess.Reference(asset: asset)
            let pipeline = RecordingPipeline(delay: .milliseconds(80))
            let renderer = DevelopPreviewRenderer()

            var first = DevelopSettings()
            first.exposure = 0.1
            renderer.submit(
                assetID: id,
                source: source,
                settings: first,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256
            )
            try await Task.sleep(for: .milliseconds(25))

            var obsolete = DevelopSettings()
            obsolete.exposure = 0.2
            renderer.submit(
                assetID: id,
                source: source,
                settings: obsolete,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256
            )
            var latest = DevelopSettings()
            latest.exposure = 0.3
            renderer.submit(
                assetID: id,
                source: source,
                settings: latest,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256
            )

            try await Task.sleep(for: .milliseconds(550))
            let calls = await pipeline.recordedCalls()
            #expect(calls.count == 3)
            #expect(calls.contains { $0.exposure == 0.1 && $0.quality == .interactive })
            #expect(!calls.contains { $0.exposure == 0.2 })
            #expect(calls.contains { $0.exposure == 0.3 && $0.quality == .interactive })
            #expect(calls.last?.exposure == 0.3)
            #expect(calls.last?.quality == .settled)
            #expect(renderer.settledImage != nil)
            #expect(renderer.settledAssetID == id)
            #expect(renderer.settledSettings == latest)
            #expect(renderer.settledRenderIntent == .display)
            #expect(!renderer.isRendering)

            renderer.submit(
                assetID: id,
                source: source,
                settings: latest,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256
            )
            try await Task.sleep(for: .milliseconds(50))
            let cachedCalls = await pipeline.recordedCalls()
            #expect(cachedCalls.count == calls.count)

            let samplingRenderer = DevelopPreviewRenderer()
            var samplingSettings = latest
            samplingSettings.pointColors = [PointColorAdjustment(hueShift: 0.5)]
            samplingRenderer.submit(
                assetID: id,
                source: source,
                settings: samplingSettings,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256,
                renderIntent: .pointColorSampling
            )
            try await Task.sleep(for: .milliseconds(150))
            let samplingCalls = await pipeline.recordedCalls()
            #expect(samplingCalls.count == calls.count + 1)
            #expect(samplingCalls.last?.quality == .settled)
            #expect(samplingCalls.last?.pointColorCount == 0)
            #expect(samplingRenderer.settledImage != nil)
            #expect(samplingRenderer.settledAssetID == id)
            #expect(samplingRenderer.settledSettings == samplingSettings)
            #expect(samplingRenderer.settledRenderIntent == .pointColorSampling)

            samplingRenderer.cancel()
            renderer.cancel()
        }
    }
}

private final class NativeDecodeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [RawNativeDecoder.Request] = []

    func decode(_ request: RawNativeDecoder.Request) -> CIImage? {
        lock.lock()
        requests.append(request)
        lock.unlock()
        return CIImage(color: CIColor(red: 0.35, green: 0.45, blue: 0.55, alpha: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    func snapshot() -> [RawNativeDecoder.Request] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private actor RecordingPipeline: RawPipeline {
    struct Call: Sendable {
        let exposure: Double
        let quality: PreviewRenderQuality
        let pointColorCount: Int
    }

    private let delay: Duration
    private var calls: [Call] = []

    init(delay: Duration) {
        self.delay = delay
    }

    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int,
        quality: PreviewRenderQuality
    ) async throws -> RenderedImage {
        calls.append(Call(
            exposure: settings.exposure,
            quality: quality,
            pointColorCount: settings.pointColors.count
        ))
        try await Task.sleep(for: delay)
        guard let image = Self.makeImage() else { throw RawPipelineError.renderFailed }
        return RenderedImage(cgImage: image, pixelWidth: 1, pixelHeight: 1)
    }

    func export(
        fileURL: URL,
        settings: DevelopSettings,
        options: ExportOptions,
        to destination: URL
    ) async throws -> URL {
        throw RawPipelineError.encodeFailed
    }

    func recordedCalls() -> [Call] {
        calls
    }

    nonisolated private static func makeImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(colorSpace: colorSpace, components: [0.5, 0.5, 0.5, 1])!)
        context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context?.makeImage()
    }
}

private actor SequencedBlockingPreviewPipeline: RawPipeline {
    enum Outcome: Equatable, Sendable {
        case success
        case failure
    }

    private let outcomes: [Outcome]
    private var callCount = 0
    private var completionCount = 0
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int,
        quality: PreviewRenderQuality
    ) async throws -> RenderedImage {
        callCount += 1
        let call = callCount
        resumeWaiters(&callWaiters, reached: callCount)
        await withCheckedContinuation { continuation in
            releases[call] = continuation
        }

        completionCount += 1
        resumeWaiters(&completionWaiters, reached: completionCount)
        guard outcomes.indices.contains(call - 1), outcomes[call - 1] == .success,
              let image = Self.makeImage() else { throw RawPipelineError.renderFailed }
        return RenderedImage(cgImage: image, pixelWidth: 1, pixelHeight: 1)
    }

    func export(
        fileURL: URL,
        settings: DevelopSettings,
        options: ExportOptions,
        to destination: URL
    ) async throws -> URL {
        throw RawPipelineError.encodeFailed
    }

    func waitForCallCount(_ count: Int) async {
        guard callCount < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    func waitForCompletionCount(_ count: Int) async {
        guard completionCount < count else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append((count, continuation))
        }
    }

    func release(call: Int) {
        releases.removeValue(forKey: call)?.resume()
    }

    private func resumeWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        reached count: Int
    ) {
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for waiter in ready { waiter.1.resume() }
    }

    nonisolated private static func makeImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(
            colorSpace: colorSpace,
            components: [0.5, 0.5, 0.5, 1]
        )!)
        context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context?.makeImage()
    }
}

private actor BlockingPreviewPipeline: RawPipeline {
    nonisolated struct Snapshot: Sendable {
        let exposures: [Double]
        let maximumConcurrentCalls: Int
    }

    private var exposures: [Double] = []
    private var activeCalls = 0
    private var maximumConcurrentCalls = 0
    private var completedCalls = 0
    private var firstRelease: CheckedContinuation<Void, Never>?
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int,
        quality: PreviewRenderQuality
    ) async throws -> RenderedImage {
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        exposures.append(settings.exposure)
        let callNumber = exposures.count
        resumeWaiters(&callWaiters, reached: callNumber)

        if callNumber == 1 {
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
        }

        activeCalls -= 1
        completedCalls += 1
        resumeWaiters(&completionWaiters, reached: completedCalls)
        guard let image = Self.makeImage() else { throw RawPipelineError.renderFailed }
        return RenderedImage(cgImage: image, pixelWidth: 1, pixelHeight: 1)
    }

    func export(
        fileURL: URL,
        settings: DevelopSettings,
        options: ExportOptions,
        to destination: URL
    ) async throws -> URL {
        throw RawPipelineError.encodeFailed
    }

    func waitForCallCount(_ count: Int) async {
        guard exposures.count < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count, continuation))
        }
    }

    func waitForCompletionCount(_ count: Int) async {
        guard completedCalls < count else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append((count, continuation))
        }
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            exposures: exposures,
            maximumConcurrentCalls: maximumConcurrentCalls
        )
    }

    private func resumeWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        reached count: Int
    ) {
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for waiter in ready { waiter.1.resume() }
    }

    nonisolated private static func makeImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(
            colorSpace: colorSpace,
            components: [0.5, 0.5, 0.5, 1]
        )!)
        context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context?.makeImage()
    }
}

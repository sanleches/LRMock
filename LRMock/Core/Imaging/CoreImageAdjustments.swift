//
//  CoreImageAdjustments.swift
//  RawLight
//
//  Core Image building blocks used by `CoreImagePipeline`: RAW-aware decode plus
//  the full develop adjustment chain.
//
//  This is the single source of truth for the normalised-units → CI-parameter
//  mapping. RAW inputs are developed by `RawNativeDecoder` (CIRAWFilter) first,
//  so `includeBasics` lets the chain skip the operations already done natively.
//

import CoreImage
import CoreImage.CIFilterBuiltins

nonisolated enum CoreImageAdjustments {

    // MARK: Decode

    /// Result of decoding: the baseline image plus whether it came from the
    /// RAW-native engine (which already consumed exposure/WB/NR/sharpen).
    struct Decoded {
        var image: CIImage
        var isRAW: Bool
    }

    /// Decodes `url`, developing RAW inputs through `CIRAWFilter` (high fidelity)
    /// and loading non-RAW inputs directly.
    static func decode(
        _ url: URL,
        settings: DevelopSettings,
        maxPixelSize: Int?,
        quality: PreviewRenderQuality
    ) throws -> Decoded {
        if let raw = RawNativeDecoder.developedImage(
            url: url,
            settings: settings,
            maxPixelSize: maxPixelSize,
            quality: quality
        ) {
            return Decoded(image: raw, isRAW: true)
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw RawPipelineError.decodeFailed
        }
        return Decoded(image: image, isRAW: false)
    }

    // MARK: Adjustment chain

    /// Applies the develop adjustments that are NOT handled by the RAW-native
    /// decoder.
    /// - Parameter includeBasics: apply exposure/WB/NR/sharpen here (true for
    ///   non-RAW; false for RAW, where `CIRAWFilter` already did them).
    static func apply(
        to input: CIImage,
        settings s: DevelopSettings,
        includeBasics: Bool,
        quality: PreviewRenderQuality
    ) -> CIImage {
        var image = input
        let extent = input.extent

        // 1. Exposure — normalised ±1 → ±2.5 EV. (RAW: done natively.)
        if includeBasics, s.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(s.exposure * 2.5)
            image = f.outputImage ?? image
        }

        // 2. White balance. (RAW: done natively in Kelvin.)
        if includeBasics, s.temperature != 0 || s.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + s.temperature * 3000, y: s.tint * 120)
            image = f.outputImage ?? image
        }

        // 3. Highlights / shadows.
        if s.highlights != 0 || s.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1.0 - max(0, -s.highlights))
            f.shadowAmount = Float(max(0, s.shadows))
            f.radius = 0
            image = f.outputImage ?? image
        }

        // 4. Whites / blacks — tone-curve endpoints.
        if s.whites != 0 || s.blacks != 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = image
            f.point0 = CGPoint(x: 0, y: clamp(0 + s.blacks * 0.12))
            f.point1 = CGPoint(x: 0.25, y: 0.25)
            f.point2 = CGPoint(x: 0.5, y: 0.5)
            f.point3 = CGPoint(x: 0.75, y: 0.75)
            f.point4 = CGPoint(x: 1, y: clamp(1 + s.whites * 0.12))
            image = f.outputImage ?? image
        }

        // 5. Tone curves — master (luminance) + per-channel R/G/B, one LUT pass.
        let curvesActive = !s.isCurveLinear(s.toneCurve) || !s.isCurveLinear(s.toneCurveRed)
            || !s.isCurveLinear(s.toneCurveGreen) || !s.isCurveLinear(s.toneCurveBlue)
        if curvesActive {
            let lut = ToneCurveLUT.channelLUT(
                master: s.toneCurve, red: s.toneCurveRed,
                green: s.toneCurveGreen, blue: s.toneCurveBlue, sampleCount: 256)
            let f = CIFilter.colorCurves()
            f.inputImage = image
            f.curvesData = lut.withUnsafeBytes { Data($0) }
            f.curvesDomain = CIVector(x: 0, y: 1)
            f.colorSpace = CGColorSpaceCreateDeviceRGB()
            image = f.outputImage ?? image
        }

        // 5b. Black & White conversion (weighted channel mix).
        if s.blackWhite {
            let wr = 0.299 + s.bwRed * 0.5
            let wg = 0.587 + s.bwGreen * 0.5
            let wb = 0.114 + s.bwBlue * 0.5
            let f = CIFilter.colorMatrix()
            f.inputImage = image
            f.rVector = CIVector(x: wr, y: wg, z: wb, w: 0)
            f.gVector = CIVector(x: wr, y: wg, z: wb, w: 0)
            f.bVector = CIVector(x: wr, y: wg, z: wb, w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            image = f.outputImage ?? image
        }

        // 6. Contrast + saturation.
        if s.contrast != 0 || s.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1 + s.contrast * 0.5)
            f.saturation = Float(s.blackWhite ? 0 : 1 + s.saturation)
            f.brightness = 0
            image = f.outputImage ?? image
        }

        // 6b. Color Mixer (8-band HSL) via a GPU colour-cube LUT.
        if !s.blackWhite, let cube = ColorCubeEngine.hslCube(for: s.colorMix) {
            let f = CIFilter.colorCube()
            f.inputImage = image
            f.cubeDimension = Float(cube.dimension)
            f.cubeData = cube.data
            image = f.outputImage ?? image
        }

        // 6c. Color Grading (3-way split toning) via a GPU colour-cube LUT.
        if let cube = ColorCubeEngine.gradingCube(for: s.grade) {
            let f = CIFilter.colorCube()
            f.inputImage = image
            f.cubeDimension = Float(cube.dimension)
            f.cubeData = cube.data
            image = f.outputImage ?? image
        }

        // 7. Dehaze — approximate: lift contrast + saturation, deepen blacks.
        if s.dehaze != 0 {
            let cc = CIFilter.colorControls()
            cc.inputImage = image
            cc.contrast = Float(1 + s.dehaze * 0.35)
            cc.saturation = Float(1 + s.dehaze * 0.25)
            cc.brightness = Float(-s.dehaze * 0.03)
            image = cc.outputImage ?? image
        }

        // 8. Clarity — midtone local contrast via a wide-radius unsharp mask.
        if s.clarity != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = quality == .interactive ? 14 : 40
            f.intensity = Float(s.clarity * 0.8)
            image = f.outputImage ?? image
        }

        // 9. Texture — fine local contrast via a small-radius unsharp mask.
        if s.texture != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = 2.5
            f.intensity = Float(s.texture * 0.7)
            image = f.outputImage ?? image
        }

        // 10. Vibrance.
        if s.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(s.vibrance)
            image = f.outputImage ?? image
        }

        // 11. Noise reduction. (RAW: luminance done natively; colour NR here.)
        let lumaNR = includeBasics ? s.noiseReduction : 0
        if quality == .settled, lumaNR > 0 || s.colorNoiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = Float(max(lumaNR, s.colorNoiseReduction) * 0.03)
            f.sharpness = 0.4
            image = f.outputImage ?? image
        }

        // 12. Sharpening with radius. (RAW: base sharpen done natively.)
        if s.sharpness > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = image
            f.radius = Float(0.8 + s.sharpenRadius * 4)
            f.intensity = Float(s.sharpness * (includeBasics ? 1.0 : 0.6))
            image = f.outputImage ?? image
        }

        // 13. Grain — monochrome noise blended in, amount controls opacity.
        if quality == .settled, s.grain > 0 {
            image = applyGrain(to: image, amount: s.grain)
        }

        // 14. Vignette (negative darkens the edges, the classic look).
        if s.vignette != 0 {
            let f = CIFilter.vignette()
            f.inputImage = image
            f.intensity = Float(s.vignette * 2.0)
            f.radius = 1.6
            image = f.outputImage ?? image
        }

        image = image.cropped(to: image.extent.isInfinite ? extent : image.extent)

        // 15. Geometry — flips, 90° rotation, straighten, crop.
        image = applyGeometry(image, settings: s)
        return image
    }

    // MARK: Grain

    private static func applyGrain(to image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent.isInfinite ? CGRect(x: 0, y: 0, width: 2048, height: 2048) : image.extent
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }

        // Monochrome noise cropped to the image.
        let mono = CIFilter.colorMatrix()
        mono.inputImage = noise
        mono.rVector = CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0)
        mono.gVector = CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0)
        mono.bVector = CIVector(x: 0.3, y: 0.3, z: 0.3, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mono.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let grain = mono.outputImage?.cropped(to: extent) else { return image }

        let overlay = CIFilter.overlayBlendMode()
        overlay.inputImage = grain
        overlay.backgroundImage = image
        guard let blended = overlay.outputImage else { return image }

        // Mix original ↔ grained by amount.
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = blended
        mix.time = Float(min(0.6, amount * 0.5))
        return mix.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: Geometry

    private static func applyGeometry(_ input: CIImage, settings s: DevelopSettings) -> CIImage {
        var image = input
        var e = image.extent
        guard !e.isInfinite, !e.isNull else { return image }

        // Flips.
        if s.flipH || s.flipV {
            var t = CGAffineTransform.identity
            t = t.translatedBy(x: s.flipH ? e.width : 0, y: s.flipV ? e.height : 0)
            t = t.scaledBy(x: s.flipH ? -1 : 1, y: s.flipV ? -1 : 1)
            image = image.transformed(by: t)
            image = reorigin(image)
            e = image.extent
        }

        // 90° rotation.
        let turns = ((s.rotationQuarterTurns % 4) + 4) % 4
        if turns != 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -Double(turns) * .pi / 2))
            image = reorigin(image)
            e = image.extent
        }

        // Straighten (rotate + auto-crop to remove empty corners).
        if s.straighten != 0 {
            if let f = CIFilter(name: "CIStraightenFilter") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(s.straighten * .pi / 180, forKey: kCIInputAngleKey)
                if let out = f.outputImage { image = reorigin(out); e = image.extent }
            }
        }

        // Crop rectangle (normalised, origin top-left in UI → flip Y for CI).
        if !s.isFullFrame {
            let rect = CGRect(
                x: e.minX + s.cropX * e.width,
                y: e.minY + (1 - s.cropY - s.cropH) * e.height,
                width: s.cropW * e.width,
                height: s.cropH * e.height
            )
            image = reorigin(image.cropped(to: rect))
        }
        return image
    }

    /// Shifts an image so its extent origin is (0, 0).
    private static func reorigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard !e.isInfinite, !e.isNull else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    // MARK: Scaling / rasterising / encoding

    static func downscale(_ image: CIImage, maxPixelSize: Int) -> CIImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isNull,
              extent.width > 0, extent.height > 0 else { return image }
        let longest = max(extent.width, extent.height)
        guard longest > CGFloat(maxPixelSize) else { return image }

        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = Float(CGFloat(maxPixelSize) / longest)
        f.aspectRatio = 1
        return f.outputImage ?? image
    }

    static func rasterize(_ image: CIImage, context: CIContext, colorSpace: CGColorSpace) throws -> RenderedImage {
        let extent = image.extent.isInfinite
            ? CGRect(x: 0, y: 0, width: 1024, height: 1024)
            : image.extent
        guard let cg = context.createCGImage(image, from: extent,
                                             format: .RGBA8, colorSpace: colorSpace)
        else { throw RawPipelineError.renderFailed }
        return RenderedImage(cgImage: cg, pixelWidth: cg.width, pixelHeight: cg.height)
    }

    static func encode(_ cgImage: CGImage, options: ExportOptions,
                       colorSpace: CGColorSpace, to destination: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            destination as CFURL, utType(for: options.format), 1, nil
        ) else { throw RawPipelineError.encodeFailed }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: options.quality]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RawPipelineError.encodeFailed }
    }

    // MARK: Helpers

    static func clamp(_ value: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        min(max(value, lo), hi)
    }

    static func colorSpace(for space: ExportOptions.ColorSpace) -> CGColorSpace {
        switch space {
        case .sRGB:      return CGColorSpace(name: CGColorSpace.sRGB)!
        case .displayP3: return CGColorSpace(name: CGColorSpace.displayP3)!
        case .adobeRGB:  return CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        }
    }

    static func utType(for format: ExportOptions.Format) -> CFString {
        switch format {
        case .jpeg: return "public.jpeg" as CFString
        case .heic: return "public.heic" as CFString
        case .tiff: return "public.tiff" as CFString
        case .png:  return "public.png" as CFString
        }
    }
}

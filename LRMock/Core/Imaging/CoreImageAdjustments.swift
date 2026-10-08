//
//  CoreImageAdjustments.swift
//  RawLight
//
//  Shared Core Image building blocks used by BOTH imaging backends:
//    * `CoreImagePipeline` applies the whole chain (contrast included).
//    * `MetalPipeline` applies the chain with `skipContrast: true` and injects
//      RawTherapee's contrast curve as a Metal kernel instead.
//
//  Centralising decode + the adjustment mapping here means the two backends can
//  differ in exactly one operation without drifting on everything else. This is
//  the single source of truth for the normalised-units → CI-parameter mapping.
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
    static func decode(_ url: URL, settings: DevelopSettings) throws -> Decoded {
        if let raw = RawNativeDecoder.developedImage(url: url, settings: settings) {
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
    /// - Parameters:
    ///   - includeBasics: apply exposure/WB/NR/sharpen here (true for non-RAW;
    ///     false for RAW, where `CIRAWFilter` already did them).
    ///   - skipContrast: omit contrast (the Metal backend supplies RT contrast).
    static func apply(
        to input: CIImage,
        settings s: DevelopSettings,
        includeBasics: Bool,
        skipContrast: Bool
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

        // 5. Contrast (optional) + saturation.
        if (!skipContrast && s.contrast != 0) || s.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = skipContrast ? 1 : Float(1 + s.contrast * 0.5)
            f.saturation = Float(1 + s.saturation)
            f.brightness = 0
            image = f.outputImage ?? image
        }

        // 6. Vibrance.
        if s.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(s.vibrance)
            image = f.outputImage ?? image
        }

        // 7. Noise reduction. (RAW: done natively.)
        if includeBasics, s.noiseReduction > 0 {
            let f = CIFilter.noiseReduction()
            f.inputImage = image
            f.noiseLevel = Float(s.noiseReduction * 0.03)
            f.sharpness = 0.4
            image = f.outputImage ?? image
        }

        // 8. Sharpening. (RAW: done natively.)
        if includeBasics, s.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(s.sharpness)
            image = f.outputImage ?? image
        }

        // 9. User rotation.
        if s.rotationQuarterTurns % 4 != 0 {
            let radians = -Double(s.rotationQuarterTurns % 4) * (.pi / 2)
            image = image.transformed(by: CGAffineTransform(rotationAngle: radians))
        }

        return image.cropped(to: image.extent.isInfinite ? extent : image.extent)
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

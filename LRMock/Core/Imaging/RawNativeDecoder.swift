//
//  RawNativeDecoder.swift
//  RawLight
//
//  High-fidelity RAW development using Apple's built-in RAW engine (`CIRAWFilter`).
//
//  Why this exists
//  ---------------
//  RawLight is a RAW tool first. Apple's RAW pipeline is GPU-accelerated and
//  highly optimised for Apple silicon, and — crucially — it operates on the
//  *sensor data* before demosaic, so a handful of controls behave with true RAW
//  latitude that you simply cannot reproduce by stacking filters on an 8-bit
//  image:
//      • exposure            — real EV scaling in linear sensor space
//      • white balance       — genuine Kelvin / tint re-neutralisation
//      • noise reduction     — luminance + colour NR tuned per camera
//      • sharpening          — RAW-aware detail reconstruction
//
//  So for RAW inputs we let `CIRAWFilter` own those operations, and layer our
//  creative "look" (tone curve, contrast, colour) on top. For non-RAW inputs
//  this returns `nil` and the generic Core Image chain handles everything.
//
//  RawTherapee informs *which* controls matter and how they should feel; the
//  implementation here is pure iOS. This keeps RawLight its own high-performance
//  tool rather than a desktop port.
//

import CoreImage

/// Shared normalized-slider mapping for both RAW and rendered inputs.
nonisolated enum WhiteBalanceMapping {

    struct Neutral: Equatable, Sendable {
        let kelvin: Double
        let tint: Double
    }

    static let kelvinDeltaPerUnit = 3000.0
    static let tintDeltaPerUnit = 50.0
    static let renderedBaseline = Neutral(kelvin: 6500, tint: 0)

    /// Applies normalized deltas to a source-specific neutral. RAW callers pass
    /// the camera's as-shot neutral; rendered images use `renderedBaseline`.
    static func adjustedNeutral(
        baseline: Neutral,
        temperature: Double,
        tint: Double
    ) -> Neutral {
        let temperature = normalized(temperature)
        let tint = normalized(tint)
        return Neutral(
            kelvin: min(50_000, max(2_000,
                baseline.kelvin + temperature * kelvinDeltaPerUnit)),
            tint: min(150, max(-150,
                baseline.tint + tint * tintDeltaPerUnit))
        )
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }
}

/// Pure mapping from normalized Detail controls to CIRAWFilter's bounded native
/// controls. Spatial masking and the finer NR controls remain in the common chain.
nonisolated enum RawDetailMapping {

    struct Values: Equatable, Sendable {
        let luminanceNoise: Float
        let colorNoise: Float
        let sharpness: Float
        let detail: Float
        let contrast: Float
    }

    static func values(for settings: DevelopSettings) -> Values {
        let luminance = unit(settings.noiseReduction)
        let luminanceDetail = unit(settings.noiseReductionDetail)
        let color = unit(settings.colorNoiseReduction)
        let colorDetail = unit(settings.colorNoiseReductionDetail)
        let colorSmoothness = unit(settings.colorNoiseReductionSmoothness)
        let sharpness = unit(settings.sharpness)
        let sharpenDetail = unit(settings.sharpenDetail)

        return Values(
            luminanceNoise: Float(luminance * (1 - 0.3 * luminanceDetail)),
            colorNoise: Float(min(1, color * (1 - 0.25 * colorDetail) * (0.75 + 0.5 * colorSmoothness))),
            sharpness: Float(sharpness),
            detail: Float(min(3, sharpness * (0.5 + 2.5 * sharpenDetail))),
            contrast: Float(min(1, max(
                sharpness * sharpenDetail * 0.45,
                luminance * unit(settings.noiseReductionContrast) * 0.65
            )))
        )
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

nonisolated enum RawNativeDecoder {

    enum RenderIntent: Equatable, Sendable {
        case display
        case pointColorSampling
    }

    struct Request: Equatable, Sendable {
        let url: URL
        let settings: DevelopSettings
        let maxPixelSize: Int?
        let quality: PreviewRenderQuality
        let intent: RenderIntent
    }

    /// Develops a RAW file through `CIRAWFilter`, applying the RAW-native subset
    /// of the request settings. Sampling uses the same native detail settings as
    /// display because those operations are baked before Point Color.
    ///
    /// Operations consumed here (and therefore skipped by the creative chain):
    /// exposure, white balance, noise reduction, sharpening.
    static func developedImage(request: Request) -> CIImage? {
        let s = request.settings
        guard let filter = CIRAWFilter(imageURL: request.url) else { return nil }

        if request.quality == .interactive {
            filter.isDraftModeEnabled = true
        }
        if let maxPixelSize = request.maxPixelSize {
            let longestEdge = max(filter.nativeSize.width, filter.nativeSize.height)
            if longestEdge > CGFloat(maxPixelSize), longestEdge > 0 {
                filter.scaleFactor = Float(CGFloat(maxPixelSize) / longestEdge)
            }
        }

        // Exposure — normalised ±1 → ±2.5 EV, applied in linear sensor space.
        if s.exposure != 0 {
            filter.exposure = Float(s.exposure * 2.5)
        }

        // White balance — shift relative to the camera's as-shot neutral.
        if s.temperature != 0 || s.tint != 0 {
            let neutral = WhiteBalanceMapping.adjustedNeutral(
                baseline: .init(
                    kelvin: Double(filter.neutralTemperature),
                    tint: Double(filter.neutralTint)
                ),
                temperature: s.temperature,
                tint: s.tint
            )
            filter.neutralTemperature = Float(neutral.kelvin)
            filter.neutralTint = Float(neutral.tint)
        }

        let detail = RawDetailMapping.values(for: s)

        // Noise reduction — Apple's per-camera luminance and colour stages.
        if s.noiseReduction > 0, filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = detail.luminanceNoise
        }
        if s.colorNoiseReduction > 0, filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = detail.colorNoise
        }

        // Sharpening/detail — RAW-aware reconstruction. Masking and radius are
        // spatial post-RAW operations and are intentionally handled downstream.
        if s.sharpness > 0, filter.isSharpnessSupported {
            filter.sharpnessAmount = detail.sharpness
        }
        if s.sharpness > 0, filter.isDetailSupported {
            filter.detailAmount = detail.detail
        }
        if detail.contrast > 0, filter.isContrastSupported {
            filter.contrastAmount = detail.contrast
        }

        return filter.outputImage
    }

    /// Fast check used for UI/metadata ("is this a RAW?") without developing.
    static func isRAW(url: URL) -> Bool {
        CIRAWFilter(imageURL: url) != nil
    }
}

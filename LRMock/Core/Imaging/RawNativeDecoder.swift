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

nonisolated enum RawNativeDecoder {

    /// Develops a RAW file through `CIRAWFilter`, applying the RAW-native subset
    /// of `settings`. Returns `nil` if `url` is not a RAW the system can decode.
    ///
    /// Operations consumed here (and therefore skipped by the creative chain):
    /// exposure, white balance, noise reduction, sharpening.
    static func developedImage(
        url: URL,
        settings s: DevelopSettings,
        maxPixelSize: Int?,
        quality: PreviewRenderQuality
    ) -> CIImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }

        if quality == .interactive {
            filter.isDraftModeEnabled = true
        }
        if let maxPixelSize {
            let longestEdge = max(filter.nativeSize.width, filter.nativeSize.height)
            if longestEdge > CGFloat(maxPixelSize), longestEdge > 0 {
                filter.scaleFactor = Float(CGFloat(maxPixelSize) / longestEdge)
            }
        }

        // Exposure — normalised ±1 → ±2.5 EV, applied in linear sensor space.
        if s.exposure != 0 {
            filter.exposure = Float(s.exposure * 2.5)
        }

        // White balance — shift relative to the camera's as-shot neutral so the
        // slider means "warmer/cooler than the photographer's setting".
        if s.temperature != 0 {
            filter.neutralTemperature += Float(s.temperature * 3000) // ±3000 K
        }
        if s.tint != 0 {
            filter.neutralTint += Float(s.tint * 50)                 // ±50 tint
        }

        // Noise reduction — Apple's per-camera luminance + colour NR.
        if s.noiseReduction > 0 {
            filter.luminanceNoiseReductionAmount = Float(s.noiseReduction)
            filter.colorNoiseReductionAmount = Float(min(1, s.noiseReduction * 1.2))
        }

        // Sharpening — RAW-aware detail reconstruction.
        if s.sharpness > 0 {
            filter.sharpnessAmount = Float(s.sharpness)
        }

        return filter.outputImage
    }

    /// Fast check used for UI/metadata ("is this a RAW?") without developing.
    static func isRAW(url: URL) -> Bool {
        CIRAWFilter(imageURL: url) != nil
    }
}

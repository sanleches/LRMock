//
//  MetalPipeline.swift
//  RawLight
//
//  Phase 2 imaging backend. Identical to `CoreImagePipeline` except the contrast
//  step is RawTherapee's contrast curve, ported to a Metal compute kernel
//  (`RTContrastKernel` → rtContrast.metal) and injected into the Core Image
//  graph. Everything else (decode, white balance, tone, colour, export) is the
//  shared `CoreImageAdjustments` path.
//
//  This is the template for future RawTherapee ports: add a kernel, swap one
//  step here, and the UI/`RawPipeline` contract is untouched. Falls back to the
//  Core Image contrast automatically if Metal is unavailable.
//

import Foundation
import CoreImage

nonisolated final class MetalPipeline: RawPipeline {

    private let context: CIContext

    init() {
        // Reuse the Metal-bound Core Image context so textures stay on one device.
        self.context = MetalContext.shared.ciContext
    }

    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int
    ) async throws -> RenderedImage {
        let image = try developed(fileURL: fileURL, settings: settings)
        let scaled = CoreImageAdjustments.downscale(image, maxPixelSize: maxPixelSize)
        return try CoreImageAdjustments.rasterize(
            scaled, context: context, colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    func export(
        fileURL: URL,
        settings: DevelopSettings,
        options: ExportOptions,
        to destination: URL
    ) async throws -> URL {
        var image = try developed(fileURL: fileURL, settings: settings)
        if let maxPixel = options.maxPixelSize {
            image = CoreImageAdjustments.downscale(image, maxPixelSize: maxPixel)
        }
        let colorSpace = CoreImageAdjustments.colorSpace(for: options.colorSpace)
        let rendered = try CoreImageAdjustments.rasterize(image, context: context, colorSpace: colorSpace)
        try CoreImageAdjustments.encode(rendered.cgImage, options: options,
                                        colorSpace: colorSpace, to: destination)
        return destination
    }

    // MARK: Shared develop step

    /// Decodes and applies the chain with the RawTherapee contrast curve swapped
    /// in for Core Image's contrast.
    private func developed(fileURL: URL, settings: DevelopSettings) throws -> CIImage {
        let decoded = try CoreImageAdjustments.decode(fileURL, settings: settings)
        let includeBasics = !decoded.isRAW

        if settings.contrast != 0, MetalContext.shared.isAvailable {
            // Everything except contrast via the shared chain…
            let partial = CoreImageAdjustments.apply(
                to: decoded.image, settings: settings,
                includeBasics: includeBasics, skipContrast: true
            )
            // …then RawTherapee's contrast curve on the GPU.
            return RTContrastKernel.apply(to: partial, amount: Float(settings.contrast))
        } else {
            // No contrast, or Metal unavailable: plain shared chain (CI contrast).
            return CoreImageAdjustments.apply(
                to: decoded.image, settings: settings,
                includeBasics: includeBasics, skipContrast: false
            )
        }
    }
}

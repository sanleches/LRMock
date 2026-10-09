//
//  CoreImagePipeline.swift
//  RawLight
//
//  Phase 1 imaging backend: pure Apple Core Image.
//
//  Decoding via `CIRAWFilter` (falls back to a direct load for non-RAW inputs so
//  the app is testable without RAW samples) and the full adjustment chain from
//  `CoreImageAdjustments`. The class is `nonisolated` so rendering runs off the
//  main thread; `CIContext` is thread-safe.
//

import Foundation
import CoreImage

nonisolated final class CoreImagePipeline: RawPipeline {

    /// Fast context for interactive previews (skips high-quality downsampling).
    private let interactiveContext: CIContext
    /// High-quality context for settled previews and exports.
    private let qualityContext: CIContext

    /// Previews at or below this longest edge use the fast interactive context.
    private let interactiveThreshold = 1600

    init() {
        let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        self.interactiveContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: false,
            .cacheIntermediates: false,
            .workingColorSpace: workingSpace,
            .workingFormat: CIFormat.RGBAh
        ])
        self.qualityContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true,
            .workingColorSpace: workingSpace,
            .workingFormat: CIFormat.RGBAh
        ])
    }

    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int,
        quality: PreviewRenderQuality
    ) async throws -> RenderedImage {
        try Task.checkCancellation()
        let decoded = try CoreImageAdjustments.decode(
            fileURL,
            settings: settings,
            maxPixelSize: maxPixelSize,
            quality: quality
        )
        try Task.checkCancellation()
        let adjusted = CoreImageAdjustments.apply(
            to: decoded.image, settings: settings,
            includeBasics: !decoded.isRAW,
            quality: quality
        )
        let scaled = CoreImageAdjustments.downscale(adjusted, maxPixelSize: maxPixelSize)
        try Task.checkCancellation()
        let ctx = quality == .interactive ? interactiveContext : qualityContext
        return try CoreImageAdjustments.rasterize(
            scaled,
            context: ctx,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
        )
    }

    func export(
        fileURL: URL,
        settings: DevelopSettings,
        options: ExportOptions,
        to destination: URL
    ) async throws -> URL {
        try Task.checkCancellation()
        let decoded = try CoreImageAdjustments.decode(
            fileURL,
            settings: settings,
            maxPixelSize: nil,
            quality: .settled
        )
        var image = CoreImageAdjustments.apply(
            to: decoded.image, settings: settings,
            includeBasics: !decoded.isRAW,
            quality: .settled
        )
        if let maxPixel = options.maxPixelSize {
            image = CoreImageAdjustments.downscale(image, maxPixelSize: maxPixel)
        }
        let colorSpace = CoreImageAdjustments.colorSpace(for: options.colorSpace)
        try Task.checkCancellation()
        let rendered = try CoreImageAdjustments.rasterize(image, context: qualityContext, colorSpace: colorSpace)
        try CoreImageAdjustments.encode(rendered.cgImage, options: options,
                                        colorSpace: colorSpace, to: destination)
        return destination
    }
}

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

    private static var workingColorSpace: CGColorSpace {
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    }

    /// Fast context for interactive previews (skips high-quality downsampling).
    private let interactiveContext: CIContext
    /// High-quality context for settled previews and exports.
    private let qualityContext: CIContext
    private let nativeDecoder: CoreImageAdjustments.NativeDecoder

    /// Previews at or below this longest edge use the fast interactive context.
    private let interactiveThreshold = 1600

    init(
        nativeDecoder: @escaping CoreImageAdjustments.NativeDecoder = {
            RawNativeDecoder.developedImage(request: $0)
        }
    ) {
        let workingSpace = Self.workingColorSpace
        self.nativeDecoder = nativeDecoder
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
            quality: quality,
            intent: .display,
            nativeDecoder: nativeDecoder
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

    func renderPointColorSamplingPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int
    ) async throws -> RenderedImage {
        try Task.checkCancellation()

        let decoded = try CoreImageAdjustments.decode(
            fileURL,
            settings: settings,
            maxPixelSize: maxPixelSize,
            quality: .settled,
            intent: .pointColorSampling,
            nativeDecoder: nativeDecoder
        )
        try Task.checkCancellation()

        let pointColorInput = CoreImageAdjustments.applyPointColorInput(
            to: decoded.image,
            settings: settings,
            includeBasics: !decoded.isRAW,
            quality: .settled
        )
        // Geometry would interpolate colours that never entered Point Color.
        // Return the exact pre-Point-Color image and invert viewport geometry
        // when mapping the user's tap instead.
        let scaled = CoreImageAdjustments.downscale(pointColorInput, maxPixelSize: maxPixelSize)
        try Task.checkCancellation()
        return try CoreImageAdjustments.rasterize(
            scaled,
            context: qualityContext,
            colorSpace: Self.workingColorSpace,
            format: .RGBAh
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
            quality: .settled,
            intent: .display,
            nativeDecoder: nativeDecoder
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

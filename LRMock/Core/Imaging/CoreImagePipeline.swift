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

    private let context: CIContext

    init() {
        self.context = CIContext(options: [.useSoftwareRenderer: false])
    }

    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int
    ) async throws -> RenderedImage {
        let decoded = try CoreImageAdjustments.decode(fileURL, settings: settings)
        let adjusted = CoreImageAdjustments.apply(
            to: decoded.image, settings: settings,
            includeBasics: !decoded.isRAW, skipContrast: false
        )
        let scaled = CoreImageAdjustments.downscale(adjusted, maxPixelSize: maxPixelSize)
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
        let decoded = try CoreImageAdjustments.decode(fileURL, settings: settings)
        var image = CoreImageAdjustments.apply(
            to: decoded.image, settings: settings,
            includeBasics: !decoded.isRAW, skipContrast: false
        )
        if let maxPixel = options.maxPixelSize {
            image = CoreImageAdjustments.downscale(image, maxPixelSize: maxPixel)
        }
        let colorSpace = CoreImageAdjustments.colorSpace(for: options.colorSpace)
        let rendered = try CoreImageAdjustments.rasterize(image, context: context, colorSpace: colorSpace)
        try CoreImageAdjustments.encode(rendered.cgImage, options: options,
                                        colorSpace: colorSpace, to: destination)
        return destination
    }
}

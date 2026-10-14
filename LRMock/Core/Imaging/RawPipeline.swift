//
//  RawPipeline.swift
//  RawLight
//
//  The seam between the UI and whatever is actually decoding/processing pixels.
//
//  Everything above this protocol (grid, loupe, inspector) depends ONLY on this
//  abstraction, never on Core Image directly — so the imaging backend can evolve
//  without touching a single view.
//
//  A pipeline has three jobs:
//    1. `renderPreview` – decode + apply `DevelopSettings`, bounded to a max
//       pixel size, for on-screen display (loupe / filmstrip).
//    2. `renderPointColorSamplingPreview` – render the colour stage sampled by
//       Point Color, aligned to the visible crop.
//    3. `export` – render at full resolution and encode to a file.
//

import Foundation
import CoreGraphics

/// A decoded, develop-applied image ready to show. `CGImage` keeps the protocol
/// UI-framework agnostic (SwiftUI, UIKit and AppKit can all consume it).
///
/// `@unchecked Sendable`: `CGImage` is an immutable, thread-safe Core Graphics
/// value but is not formally marked `Sendable`; it is safe to pass across actors.
nonisolated struct RenderedImage: @unchecked Sendable {
    var cgImage: CGImage
    var pixelWidth: Int
    var pixelHeight: Int
}

nonisolated enum PreviewRenderQuality: Sendable, Equatable {
    case interactive
    case settled
}

/// Options describing a file export.
nonisolated struct ExportOptions: Sendable {
    enum Format: String, CaseIterable, Sendable { case jpeg, heic, tiff, png }
    enum ColorSpace: String, CaseIterable, Sendable { case sRGB, displayP3, adobeRGB }

    var format: Format = .jpeg
    var colorSpace: ColorSpace = .sRGB
    /// Longest edge in pixels; `nil` keeps full resolution.
    var maxPixelSize: Int?
    /// 0...1 for lossy formats.
    var quality: Double = 0.9
}

nonisolated enum RawPipelineError: Error {
    case decodeFailed
    case renderFailed
    case encodeFailed
    case fileUnavailable
}

/// The contract every imaging backend implements.
nonisolated protocol RawPipeline: Sendable {

    /// Decodes `fileURL` and applies `settings`, limited to `maxPixelSize` on the
    /// longest edge for responsive on-screen preview.
    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int,
        quality: PreviewRenderQuality
    ) async throws -> RenderedImage

    /// Renders pixels in extended-linear Display P3 at the stage immediately
    /// before Point Color, with only viewport geometry and crop applied after it.
    func renderPointColorSamplingPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int
    ) async throws -> RenderedImage

    /// Full-resolution render encoded to a file, returned as the output URL.
    func export(
        fileURL: URL,
        settings: DevelopSettings,
        options: ExportOptions,
        to destination: URL
    ) async throws -> URL
}

extension RawPipeline {
    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int
    ) async throws -> RenderedImage {
        try await renderPreview(
            fileURL: fileURL,
            settings: settings,
            maxPixelSize: maxPixelSize,
            quality: .settled
        )
    }

    /// Compatibility fallback for lightweight/test pipelines. Production Core
    /// Image rendering overrides this to stop at the exact Point Color stage.
    func renderPointColorSamplingPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int
    ) async throws -> RenderedImage {
        var settings = settings
        settings.pointColors = []
        return try await renderPreview(
            fileURL: fileURL,
            settings: settings,
            maxPixelSize: maxPixelSize,
            quality: .settled
        )
    }
}

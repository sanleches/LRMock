//
//  RawPipeline.swift
//  RawLight
//
//  The seam between the UI and whatever is actually decoding/processing pixels.
//
//  Everything above this protocol (grid, loupe, inspector) depends ONLY on this
//  abstraction, never on Core Image or Metal directly. That is what lets us ship
//  Phase 1 on `CoreImagePipeline` and later drop in a `MetalPipeline` built from
//  RawTherapee-derived kernels without touching a single view.
//
//  A pipeline has two jobs:
//    1. `renderPreview` – decode + apply `DevelopSettings`, bounded to a max
//       pixel size, for on-screen display (loupe / filmstrip).
//    2. `export` – render at full resolution and encode to a file.
//

import Foundation
import CoreGraphics

/// A decoded, develop-applied image ready to show. `CGImage` keeps the protocol
/// UI-framework agnostic (SwiftUI, UIKit and AppKit can all consume it).
///
/// `@unchecked Sendable`: `CGImage` is an immutable, thread-safe Core Graphics
/// value but is not formally marked `Sendable`; it is safe to pass across actors.
struct RenderedImage: @unchecked Sendable {
    var cgImage: CGImage
    var pixelWidth: Int
    var pixelHeight: Int
}

/// Options describing a file export.
struct ExportOptions: Sendable {
    enum Format: String, CaseIterable, Sendable { case jpeg, heic, tiff, png }
    enum ColorSpace: String, CaseIterable, Sendable { case sRGB, displayP3, adobeRGB }

    var format: Format = .jpeg
    var colorSpace: ColorSpace = .sRGB
    /// Longest edge in pixels; `nil` keeps full resolution.
    var maxPixelSize: Int?
    /// 0...1 for lossy formats.
    var quality: Double = 0.9
}

enum RawPipelineError: Error {
    case decodeFailed
    case renderFailed
    case encodeFailed
    case fileUnavailable
}

/// The contract every imaging backend implements.
protocol RawPipeline: Sendable {

    /// Decodes `fileURL` and applies `settings`, limited to `maxPixelSize` on the
    /// longest edge for responsive on-screen preview.
    func renderPreview(
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

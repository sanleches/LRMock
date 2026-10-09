//
//  PipelineIntegrationTests.swift
//  LRMockTests
//
//  End-to-end imaging tests: decode a real file, apply develop settings, and
//  verify the pipeline actually changes pixels the way it should, then that
//  export encodes a valid file. Also covers the recipe document + library paths.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import SwiftData
import UniformTypeIdentifiers
@testable import LRMock

/// Shared helpers for generating and measuring test images.
enum TestImage {

    /// Writes a flat mid-grey JPEG and returns its URL.
    static func writeGrey(_ level: UInt8 = 128, size: Int = 512) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grey-\(UUID().uuidString).jpg")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let v = CGFloat(level) / 255
        ctx.setFillColor(CGColor(colorSpace: cs, components: [v, v, v, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    /// Mean luminance (0...1) of a CGImage.
    static func meanLuminance(_ cg: CGImage) -> Double {
        let w = min(cg.width, 64), h = min(cg.height, 64)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        var i = 0
        while i < px.count {
            sum += (0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])) / 255
            i += 4
        }
        return sum / Double(w * h)
    }
}

struct PipelineIntegrationTests {

    private let pipeline = CoreImagePipeline()

    @Test func renderProducesBoundedImage() async throws {
        let url = TestImage.writeGrey()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await pipeline.renderPreview(
            fileURL: url, settings: DevelopSettings(), maxPixelSize: 256)
        #expect(result.cgImage.width <= 256 && result.cgImage.height <= 256)
        #expect(result.cgImage.width > 0)
    }

    @Test func exposureBrightensImage() async throws {
        let url = TestImage.writeGrey(100)
        defer { try? FileManager.default.removeItem(at: url) }

        let base = try await pipeline.renderPreview(fileURL: url, settings: DevelopSettings(), maxPixelSize: 256)
        var up = DevelopSettings(); up.exposure = 0.6
        let brighter = try await pipeline.renderPreview(fileURL: url, settings: up, maxPixelSize: 256)

        #expect(TestImage.meanLuminance(brighter.cgImage) > TestImage.meanLuminance(base.cgImage) + 0.03)
    }

    @Test func blackAndWhiteRemovesSaturation() async throws {
        // A coloured image → B&W should have near-equal R=G=B.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("col-\(UUID().uuidString).jpg")
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.8, 0.2, 0.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        defer { try? FileManager.default.removeItem(at: url) }

        var bw = DevelopSettings(); bw.blackWhite = true
        let out = try await pipeline.renderPreview(fileURL: url, settings: bw, maxPixelSize: 64)
        var px = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let octx = CGContext(data: &px, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                             space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        octx.draw(out.cgImage, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        // Sample centre pixel R,G,B nearly equal.
        let idx = (32 * 64 + 32) * 4
        let r = Int(px[idx]), g = Int(px[idx + 1]), b = Int(px[idx + 2])
        #expect(abs(r - g) < 12 && abs(g - b) < 12)
    }

    @Test func exportWritesValidJPEG() async throws {
        let url = TestImage.writeGrey()
        defer { try? FileManager.default.removeItem(at: url) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("exp-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: out) }

        var opts = ExportOptions(); opts.format = .jpeg; opts.maxPixelSize = 256
        let written = try await pipeline.export(
            fileURL: url, settings: DevelopSettings(), options: opts, to: out)
        #expect(FileManager.default.fileExists(atPath: written.path))
        // Decodes back as an image.
        let src = CGImageSourceCreateWithURL(written as CFURL, nil)
        #expect(src != nil)
        #expect(CGImageSourceCreateImageAtIndex(src!, 0, nil) != nil)
    }
}

@MainActor
struct RecipeDocumentTests {

    @Test func buildAndApplyRoundTrip() throws {
        let fp = ImageFingerprint(filename: "t.jpg", fileSizeBytes: 10)
        let asset = ImageAsset(originalFilename: "t.jpg", storageMode: .managed,
                               fingerprint: fp, fileSizeBytes: 10)
        asset.develop.exposure = 0.4
        asset.develop.grade.highSat = 0.5
        asset.rating = 3
        asset.flag = .picked

        let doc = RecipeDocument(asset: asset)
        let data = try JSONEncoder().encode(doc)
        let decoded = try JSONDecoder().decode(RecipeDocument.self, from: data)

        let target = ImageAsset(originalFilename: "t.jpg", storageMode: .managed,
                                fingerprint: fp, fileSizeBytes: 10)
        decoded.apply(to: target)
        #expect(target.develop.exposure == 0.4)
        #expect(target.develop.grade.highSat == 0.5)
        #expect(target.rating == 3)
        #expect(target.flag == .picked)
        #expect(doc.format == "com.rawlight.recipe")
        #expect(doc.parameters["foundation.exposureEV"] == 1.0) // 0.4 * 2.5
    }
}

@Suite(.serialized)
struct LibraryLayoutTests {

    private func withTemporaryLibrary<T>(
        _ operation: (_ appRoot: URL, _ cacheRoot: URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-LibraryTests-\(UUID().uuidString)", isDirectory: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-CacheTests-\(UUID().uuidString)", isDirectory: true)
        LibraryLocations.configureRoots(appRoot: root, cacheRoot: cache)
        defer {
            LibraryLocations.resetConfiguredRoots()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache)
        }
        return try operation(root, cache)
    }

    @MainActor
    private func withTemporaryLibraryAsync<T>(
        _ operation: (_ appRoot: URL, _ cacheRoot: URL) async throws -> T
    ) async rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-LibraryTests-\(UUID().uuidString)", isDirectory: true)
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-CacheTests-\(UUID().uuidString)", isDirectory: true)
        LibraryLocations.configureRoots(appRoot: root, cacheRoot: cache)
        defer {
            LibraryLocations.resetConfiguredRoots()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: cache)
        }
        return try await operation(root, cache)
    }

    @Test func relativePathRoundTrips() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let id = UUID()
            let url = LibraryLocations.managedOriginalURL(assetID: id, fileExtension: "raf")
            let rel = try LibraryLocations.relativePath(of: url)
            let resolved = try LibraryLocations.url(forManagedRelativePath: rel)
            #expect(resolved.path == url.path)
            #expect(rel.hasPrefix("Originals/"))
        }
    }

    @Test func bootstrapCreatesGenerationTree() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let fm = FileManager.default
            #expect(fm.fileExists(atPath: LibraryLocations.originals.path))
            #expect(fm.fileExists(atPath: LibraryLocations.incoming.path))
            #expect(fm.fileExists(atPath: LibraryLocations.recipes.path))
            #expect(fm.fileExists(atPath: LibraryLocations.trash.path))
            #expect(fm.fileExists(atPath: LibraryLocations.thumbnailsCache.path))
        }
    }

    @Test func bootstrapReusesPointerGeneration() throws {
        try withTemporaryLibrary { root, cache in
            let first = try LibraryLocations.bootstrap()
            LibraryLocations.resetConfiguredRoots()
            LibraryLocations.configureRoots(appRoot: root, cacheRoot: cache)
            let second = try LibraryLocations.bootstrap()
            #expect(second == first)
        }
    }

    @Test func corruptPointerRecoversExistingGeneration() throws {
        try withTemporaryLibrary { root, _ in
            let expected = UUID()
            let generation = root
                .appendingPathComponent("Libraries", isDirectory: true)
                .appendingPathComponent(expected.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(
                to: root.appendingPathComponent("CurrentLibrary.json")
            )

            let recovered = try LibraryLocations.bootstrap()
            #expect(recovered == expected)
            let rewritten = try String(
                contentsOf: root.appendingPathComponent("CurrentLibrary.json"),
                encoding: .utf8
            )
            #expect(rewritten.contains(expected.uuidString))
            #expect(rewritten.contains("checksum"))
        }
    }

    @Test func unsupportedPointerVersionIsNotOverwritten() throws {
        try withTemporaryLibrary { root, _ in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let pointer = """
            { "schemaVersion": 999, "generationID": "\(UUID().uuidString)" }
            """
            try Data(pointer.utf8).write(to: root.appendingPathComponent("CurrentLibrary.json"))

            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.bootstrap()
            }
        }
    }

    @Test func managedPathsRejectTraversalAndExternalFiles() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("outside-\(UUID().uuidString).raw")
            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.relativePath(of: outside)
            }
            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.url(forManagedRelativePath: "../outside.raw")
            }
            #expect(throws: LibraryLocations.LocationError.self) {
                try LibraryLocations.url(forManagedRelativePath: "/tmp/outside.raw")
            }
        }
    }

    @MainActor
    @Test func recipeStoreRoundTripsAndReportsCorruption() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let asset = ImageAsset(
                originalFilename: "recipe.jpg",
                storageMode: .managed,
                fingerprint: ImageFingerprint(filename: "recipe.jpg", fileSizeBytes: 12),
                fileSizeBytes: 12
            )
            asset.develop.exposure = 0.4
            asset.rating = 4
            try RecipeStore.write(for: asset)

            let restored = try RecipeStore.read(assetID: asset.id)
            #expect(restored?.develop.exposure == 0.4)
            #expect(restored?.rating == 4)

            try Data("{}".utf8).write(
                to: LibraryLocations.recipeURL(assetID: asset.id),
                options: .atomic
            )
            #expect(throws: DecodingError.self) {
                try RecipeStore.read(assetID: asset.id)
            }
        }
    }

    @Test func sidecarRoundTripsAndRejectsUnsupportedVersion() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString).jpg")
        try Data([1]).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: SidecarService.sidecarURL(for: source))
        }
        let fingerprint = ImageFingerprint(filename: source.lastPathComponent, fileSizeBytes: 1)
        var sidecar = Sidecar(
            fingerprint: fingerprint,
            develop: DevelopSettings(),
            rating: 3,
            flag: PickFlag.picked.rawValue,
            colorLabel: 2
        )
        sidecar.develop.exposure = 0.25
        try SidecarService.write(sidecar, for: source)

        let restored = try SidecarService.read(for: source)
        #expect(restored?.fingerprint == fingerprint)
        #expect(restored?.develop.exposure == 0.25)
        #expect(restored?.rating == 3)

        sidecar.schemaVersion = 2
        try JSONEncoder().encode(sidecar).write(
            to: SidecarService.sidecarURL(for: source),
            options: .atomic
        )
        #expect(throws: SidecarService.SidecarError.self) {
            try SidecarService.read(for: source)
        }
    }

    @Test func trashReceiptRestoresOriginalAndRecipe() throws {
        try withTemporaryLibrary { _, _ in
            _ = try LibraryLocations.bootstrap()
            let id = UUID()
            let original = LibraryLocations.managedOriginalURL(assetID: id, fileExtension: "raf")
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("raw".utf8).write(to: original)
            let recipe = LibraryLocations.recipeURL(assetID: id)
            try Data("recipe".utf8).write(to: recipe)
            let relative = try LibraryLocations.relativePath(of: original)

            let receipt = try LibraryTrash.moveManagedAsset(
                id: id,
                originalFilename: "photo.raf",
                managedRelativePath: relative
            )
            #expect(!FileManager.default.fileExists(atPath: original.path))
            #expect(!FileManager.default.fileExists(atPath: recipe.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: LibraryLocations.trash.path).count == 1)

            try receipt.restore()
            #expect(FileManager.default.fileExists(atPath: original.path))
            #expect(FileManager.default.fileExists(atPath: recipe.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: LibraryLocations.trash.path).isEmpty)
        }
    }

    @MainActor
    @Test func managedImportCopiesWritesRecipeAndDeduplicates() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let source = TestImage.writeGrey(110, size: 96)
            defer { try? FileManager.default.removeItem(at: source) }
            let container = CatalogStore.makeInMemoryContainer()
            let context = container.mainContext
            let importer = ImportService(modelContext: context)

            let first = await importer.importFiles([source], into: nil)
            #expect(first.imported == 1)
            #expect(first.skipped == 0)
            #expect(first.failed == 0)

            let assets = try context.fetch(FetchDescriptor<ImageAsset>())
            #expect(assets.count == 1)
            let asset = try #require(assets.first)
            let relative = try #require(asset.managedRelativePath)
            let managed = try LibraryLocations.url(forManagedRelativePath: relative)
            #expect(FileManager.default.fileExists(atPath: managed.path))
            #expect(try ContentDigest.sha256(of: managed) == asset.contentDigest)
            #expect(try RecipeStore.read(assetID: asset.id) != nil)

            let duplicate = await importer.importFiles([source], into: nil)
            #expect(duplicate.imported == 0)
            #expect(duplicate.skipped == 1)
            #expect(duplicate.failed == 0)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 1)
        }
    }

    @MainActor
    @Test func previewRendererBoundsWorkAndKeepsLatestSettings() async throws {
        try await withTemporaryLibraryAsync { _, _ in
            _ = try LibraryLocations.bootstrap()
            let id = UUID()
            let original = LibraryLocations.managedOriginalURL(assetID: id, fileExtension: "jpg")
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data([1]).write(to: original)
            let asset = ImageAsset(
                id: id,
                originalFilename: "preview.jpg",
                storageMode: .managed,
                fingerprint: ImageFingerprint(filename: "preview.jpg", fileSizeBytes: 1),
                fileSizeBytes: 1
            )
            asset.managedRelativePath = try LibraryLocations.relativePath(of: original)
            let source = AssetFileAccess.Reference(asset: asset)
            let pipeline = RecordingPipeline(delay: .milliseconds(80))
            let renderer = DevelopPreviewRenderer()

            var first = DevelopSettings()
            first.exposure = 0.1
            renderer.submit(
                assetID: id,
                source: source,
                settings: first,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256
            )
            try await Task.sleep(for: .milliseconds(25))

            var obsolete = DevelopSettings()
            obsolete.exposure = 0.2
            renderer.submit(
                assetID: id,
                source: source,
                settings: obsolete,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256
            )
            var latest = DevelopSettings()
            latest.exposure = 0.3
            renderer.submit(
                assetID: id,
                source: source,
                settings: latest,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256
            )

            try await Task.sleep(for: .milliseconds(550))
            let calls = await pipeline.recordedCalls()
            #expect(calls.count == 3)
            #expect(calls.contains { $0.exposure == 0.1 && $0.quality == .interactive })
            #expect(!calls.contains { $0.exposure == 0.2 })
            #expect(calls.contains { $0.exposure == 0.3 && $0.quality == .interactive })
            #expect(calls.last?.exposure == 0.3)
            #expect(calls.last?.quality == .settled)
            #expect(renderer.settledImage != nil)
            #expect(!renderer.isRendering)

            renderer.submit(
                assetID: id,
                source: source,
                settings: latest,
                pipeline: pipeline,
                interactivePixels: 128,
                settledPixels: 256
            )
            try await Task.sleep(for: .milliseconds(50))
            let cachedCalls = await pipeline.recordedCalls()
            #expect(cachedCalls.count == calls.count)
            renderer.cancel()
        }
    }
}

private actor RecordingPipeline: RawPipeline {
    struct Call: Sendable {
        let exposure: Double
        let quality: PreviewRenderQuality
    }

    private let delay: Duration
    private var calls: [Call] = []

    init(delay: Duration) {
        self.delay = delay
    }

    func renderPreview(
        fileURL: URL,
        settings: DevelopSettings,
        maxPixelSize: Int,
        quality: PreviewRenderQuality
    ) async throws -> RenderedImage {
        calls.append(Call(exposure: settings.exposure, quality: quality))
        try await Task.sleep(for: delay)
        guard let image = Self.makeImage() else { throw RawPipelineError.renderFailed }
        return RenderedImage(cgImage: image, pixelWidth: 1, pixelHeight: 1)
    }

    func export(
        fileURL: URL,
        settings: DevelopSettings,
        options: ExportOptions,
        to destination: URL
    ) async throws -> URL {
        throw RawPipelineError.encodeFailed
    }

    func recordedCalls() -> [Call] {
        calls
    }

    nonisolated private static func makeImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(colorSpace: colorSpace, components: [0.5, 0.5, 0.5, 1])!)
        context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context?.makeImage()
    }
}

//
//  ThumbnailService.swift
//  RawLight
//
//  Generates and caches small grid thumbnails.
//
//  Strategy
//  --------
//  RAW files embed a full-size JPEG preview; ImageIO's
//  `CGImageSourceCreateThumbnailAtIndex` pulls that (or down-samples the image
//  if absent) without a full RAW decode — fast enough to run while scrolling.
//  Results are cached as JPEG in `Caches/Thumbnails/<assetID>.jpg`, keyed by the
//  asset id, so subsequent launches are instant and the cache can be purged by
//  the OS without data loss.
//
//  This is an `actor` so the in-memory cache and disk writes are serialised
//  without the caller worrying about threads.
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

actor ThumbnailService {

    static let shared = ThumbnailService()

    /// Longest-edge pixel size for generated grid thumbnails.
    private let maxPixelSize = 512

    /// Small in-memory LRU-ish cache to avoid re-reading disk during a scroll.
    private var memoryCache: [UUID: CGImage] = [:]
    private var insertionOrder: [UUID] = []
    private let memoryLimit = 120

    /// Returns a thumbnail for the asset `id`, generating and caching on demand.
    /// `fileURL` must be an accessible URL to the original bytes (the caller
    /// resolves bookmarks / scoped access before calling). We key on `UUID`
    /// rather than the `ImageAsset` so this stays `Sendable`-safe across actors.
    func thumbnail(for id: UUID, fileURL: URL) -> CGImage? {
        if let cached = memoryCache[id] { return cached }

        if let disk = loadFromDisk(id: id) {
            store(disk, for: id)
            return disk
        }

        guard let generated = generate(from: fileURL) else { return nil }
        writeToDisk(generated, id: id)
        store(generated, for: id)
        return generated
    }

    /// Removes the cached thumbnail for an asset (e.g. after a re-import).
    func invalidate(_ id: UUID) {
        memoryCache[id] = nil
        try? FileManager.default.removeItem(at: diskURL(id: id))
    }

    // MARK: Generation

    private func generate(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // respect EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Disk cache

    private func diskURL(id: UUID) -> URL {
        LibraryLocations.thumbnailsCache.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func loadFromDisk(id: UUID) -> CGImage? {
        let url = diskURL(id: id)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func writeToDisk(_ image: CGImage, id: UUID) {
        let url = diskURL(id: id)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    // MARK: Memory cache

    private func store(_ image: CGImage, for id: UUID) {
        memoryCache[id] = image
        insertionOrder.append(id)
        if insertionOrder.count > memoryLimit {
            let evicted = insertionOrder.removeFirst()
            if evicted != id { memoryCache[evicted] = nil }
        }
    }
}

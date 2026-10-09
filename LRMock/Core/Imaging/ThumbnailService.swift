//
//  ThumbnailService.swift
//  RawLight
//
//  Size-aware thumbnail generation with bounded parallel work, in-flight request
//  deduplication, an LRU memory budget, and a disposable disk cache.
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CryptoKit

private actor ThumbnailPermitPool {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = permits
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor ThumbnailService {

    static let shared = ThumbnailService()

    private struct CacheKey: Hashable, Sendable {
        let assetID: UUID
        let maxPixelSize: Int
        let sourceVersion: String
    }

    private struct GeneratedThumbnail: @unchecked Sendable {
        let image: CGImage?
    }

    private let workers = ThumbnailPermitPool(permits: 4)
    private var memoryCache: [CacheKey: CGImage] = [:]
    private var recency: [CacheKey] = []
    private var memoryCost = 0
    private let memoryCostLimit = 96 * 1024 * 1024
    private var inFlight: [CacheKey: Task<GeneratedThumbnail, Never>] = [:]

    func thumbnail(
        for id: UUID,
        source: AssetFileAccess.Reference,
        sourceVersion: String,
        maxPixelSize: Int
    ) async -> CGImage? {
        let boundedSize = min(max(maxPixelSize, 64), 1024)
        let key = CacheKey(
            assetID: id,
            maxPixelSize: boundedSize,
            sourceVersion: sourceVersion
        )
        if let cached = memoryCache[key] {
            touch(key)
            return cached
        }
        if let existing = inFlight[key] {
            return await existing.value.image
        }

        let cacheURL = diskURL(for: key)
        let workers = workers
        let task = Task.detached(priority: .utility) {
            await workers.acquire()
            defer { Task { await workers.release() } }
            if Task.isCancelled { return GeneratedThumbnail(image: nil) }
            if let disk = Self.loadFromDisk(cacheURL) {
                return GeneratedThumbnail(image: disk)
            }
            guard let handle = try? AssetFileAccess.open(source) else {
                return GeneratedThumbnail(image: nil)
            }
            defer { handle.release() }
            guard !Task.isCancelled,
                  let generated = Self.generate(from: handle.url, maxPixelSize: boundedSize)
            else { return GeneratedThumbnail(image: nil) }
            Self.writeToDisk(generated, url: cacheURL)
            return GeneratedThumbnail(image: generated)
        }
        inFlight[key] = task
        let result = await task.value.image
        inFlight[key] = nil
        if let result { store(result, for: key) }
        return result
    }

    func invalidate(_ id: UUID) {
        for key in memoryCache.keys where key.assetID == id {
            removeFromMemory(key)
        }
        for key in inFlight.keys where key.assetID == id {
            inFlight[key]?.cancel()
            inFlight[key] = nil
        }

        let prefix = id.uuidString + "-"
        if let files = try? FileManager.default.contentsOfDirectory(
            at: LibraryLocations.thumbnailsCache,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: Generation and disk cache

    nonisolated private static func generate(from url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: false
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func diskURL(for key: CacheKey) -> URL {
        let digest = SHA256.hash(data: Data(key.sourceVersion.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return LibraryLocations.thumbnailsCache.appendingPathComponent(
            "\(key.assetID.uuidString)-\(key.maxPixelSize)-\(digest).jpg"
        )
    }

    nonisolated private static func loadFromDisk(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    nonisolated private static func writeToDisk(_ image: CGImage, url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        _ = CGImageDestinationFinalize(destination)
    }

    // MARK: Cost-bounded LRU

    private func touch(_ key: CacheKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func store(_ image: CGImage, for key: CacheKey) {
        if memoryCache[key] != nil { removeFromMemory(key) }
        memoryCache[key] = image
        memoryCost += image.bytesPerRow * image.height
        touch(key)

        while memoryCost > memoryCostLimit, let oldest = recency.first {
            removeFromMemory(oldest)
        }
    }

    private func removeFromMemory(_ key: CacheKey) {
        if let image = memoryCache.removeValue(forKey: key) {
            memoryCost -= image.bytesPerRow * image.height
        }
        recency.removeAll { $0 == key }
    }
}

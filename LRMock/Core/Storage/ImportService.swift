//
//  ImportService.swift
//  RawLight
//
//  Turns user-picked files into catalog `ImageAsset`s.
//
//  For each incoming URL it:
//    1. Gains (scoped) read access.
//    2. Reads EXIF metadata + size and builds a re-link fingerprint.
//    3. Re-uses an existing `.rawlight` sidecar if the file was edited before,
//       so edits survive re-import.
//    4. Either copies the file into the managed library or stores a bookmark to
//       it in place (the default — RAWs are big; don't duplicate 40 MB files).
//    5. Pre-generates a thumbnail and persists the asset.
//
//  Runs on the main actor because it mutates the SwiftData `ModelContext`. The
//  heavy per-file work (metadata read, copy, thumbnail) is cheap enough for the
//  import sizes we expect in Phase 0; a future phase can move it to a background
//  `ModelActor`.
//

import Foundation
import SwiftData

@MainActor
struct ImportService {

    let modelContext: ModelContext

    /// Result summary for user feedback.
    struct Summary {
        var imported: Int = 0
        var skipped: Int = 0
        var failed: Int = 0
    }

    /// Imports `urls` into `folder` (or the loose library when `folder` is nil).
    /// - Parameter copyIntoLibrary: when true, files are duplicated into the
    ///   managed library; when false (default) they are referenced in place.
    @discardableResult
    func importFiles(
        _ urls: [URL],
        into folder: LibraryFolder?,
        copyIntoLibrary: Bool = false
    ) -> Summary {
        var summary = Summary()
        for url in urls {
            do {
                try importOne(url, into: folder, copyIntoLibrary: copyIntoLibrary)
                summary.imported += 1
            } catch {
                summary.failed += 1
            }
        }
        try? modelContext.save()
        return summary
    }

    /// Imports every supported image inside an external directory, referencing
    /// each file in place (no copy). The folder's scope is held for the whole
    /// enumeration so per-file bookmarks can be created.
    @discardableResult
    func importFolder(_ folderURL: URL, into folder: LibraryFolder?) -> Summary {
        var summary = Summary()
        let scoped = folderURL.startAccessingSecurityScopedResource()
        defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }

        for url in imageFiles(in: folderURL) {
            do {
                try importOne(url, into: folder, copyIntoLibrary: false, manageScope: false)
                summary.imported += 1
            } catch {
                summary.failed += 1
            }
        }
        try? modelContext.save()
        return summary
    }

    /// Imports files the user dropped into the app's RawLight folder (Documents)
    /// via the Files app, as managed in-place assets (already inside the sandbox,
    /// so no copy and no bookmark needed). Skips files already in the catalog.
    @discardableResult
    func scanManagedLibrary(into folder: LibraryFolder?) -> Summary {
        var summary = Summary()
        let existing = Set(
            ((try? modelContext.fetch(FetchDescriptor<ImageAsset>())) ?? [])
                .compactMap(\.managedRelativePath)
        )

        for url in imageFiles(in: LibraryLocations.documents) {
            let relative = relativePath(of: url)
            if existing.contains(relative) { summary.skipped += 1; continue }
            do {
                try importManagedInPlace(url, relativePath: relative, into: folder)
                summary.imported += 1
            } catch {
                summary.failed += 1
            }
        }
        try? modelContext.save()
        return summary
    }

    // MARK: Single file

    private func importOne(
        _ pickedURL: URL,
        into folder: LibraryFolder?,
        copyIntoLibrary: Bool,
        manageScope: Bool = true
    ) throws {
        // The document picker hands us a security-scoped URL. For folder imports
        // the parent directory already holds the scope, so we skip it here.
        let scoped = manageScope && pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let filename = pickedURL.lastPathComponent
        let size = fileSize(of: pickedURL)
        let metadata = MetadataExtractor.read(from: pickedURL)

        let fingerprint = ImageFingerprint(
            filename: filename,
            fileSizeBytes: size,
            captureDate: metadata.captureDate
        )

        // Reuse edits from a sidecar if the file carries one.
        let existingSidecar = SidecarService.read(for: pickedURL)

        let asset = ImageAsset(
            originalFilename: filename,
            storageMode: copyIntoLibrary ? .managed : .referenced,
            fingerprint: fingerprint,
            fileSizeBytes: size
        )
        apply(metadata, to: asset)
        if let sidecar = existingSidecar {
            asset.develop = sidecar.develop
            asset.rating = sidecar.rating
            asset.flagRaw = sidecar.flag
            asset.colorLabel = sidecar.colorLabel
        }

        // Persist the bytes according to the chosen storage mode.
        if copyIntoLibrary {
            let destination = try copyFile(pickedURL, forFolderNamed: folder?.name)
            asset.managedRelativePath = relativePath(of: destination)
            try writeSidecar(for: asset, at: destination)
        } else {
            asset.bookmarkData = try BookmarkStore.makeBookmark(for: pickedURL)
            // Best-effort sidecar next to the original (read-write entitlement).
            try? writeSidecar(for: asset, at: pickedURL)
        }

        asset.folder = folder
        modelContext.insert(asset)

        // Warm the thumbnail cache so the grid shows the image immediately.
        pregenerateThumbnail(for: asset)
    }

    // MARK: Steps

    private func apply(_ meta: RawMetadata, to asset: ImageAsset) {
        asset.captureDate = meta.captureDate
        asset.cameraMake = meta.cameraMake
        asset.cameraModel = meta.cameraModel
        asset.lensModel = meta.lensModel
        asset.isoValue = meta.iso
        asset.focalLength = meta.focalLength
        asset.aperture = meta.aperture
        asset.shutterSpeed = meta.shutterSpeed
        asset.pixelWidth = meta.pixelWidth
        asset.pixelHeight = meta.pixelHeight
        asset.exifOrientation = meta.orientation
    }

    private func copyFile(_ source: URL, forFolderNamed folderName: String?) throws -> URL {
        let directory = folderName.map { LibraryLocations.managedFolder(named: $0) }
            ?? LibraryLocations.managedRoot
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var destination = directory.appendingPathComponent(source.lastPathComponent)
        destination = uniqueURL(destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func writeSidecar(for asset: ImageAsset, at originalURL: URL) throws {
        let sidecar = SidecarService.snapshot(of: asset)
        try SidecarService.write(sidecar, for: originalURL)
    }

    private func pregenerateThumbnail(for asset: ImageAsset) {
        guard let handle = try? AssetFileAccess.open(asset) else { return }
        let url = handle.url
        let id = asset.id
        asset.thumbnailFileName = "\(id.uuidString).jpg"
        Task.detached {
            _ = await ThumbnailService.shared.thumbnail(for: id, fileURL: url)
            handle.release()
        }
    }

    /// Creates a managed asset for a file that already lives inside the sandbox
    /// (dropped into the RawLight folder). No copy, no bookmark.
    private func importManagedInPlace(
        _ url: URL,
        relativePath: String,
        into folder: LibraryFolder?
    ) throws {
        let filename = url.lastPathComponent
        let size = fileSize(of: url)
        let metadata = MetadataExtractor.read(from: url)
        let fingerprint = ImageFingerprint(
            filename: filename, fileSizeBytes: size, captureDate: metadata.captureDate
        )

        let asset = ImageAsset(
            originalFilename: filename,
            storageMode: .managed,
            fingerprint: fingerprint,
            fileSizeBytes: size
        )
        apply(metadata, to: asset)
        asset.managedRelativePath = relativePath

        if let sidecar = SidecarService.read(for: url) {
            asset.develop = sidecar.develop
            asset.rating = sidecar.rating
            asset.flagRaw = sidecar.flag
            asset.colorLabel = sidecar.colorLabel
        } else {
            try? writeSidecar(for: asset, at: url)
        }

        asset.folder = folder
        modelContext.insert(asset)
        pregenerateThumbnail(for: asset)
    }

    // MARK: Small utilities

    /// Recursively lists supported image files under a directory.
    private func imageFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator where Self.supportedExtensions.contains(
            url.pathExtension.lowercased()
        ) {
            result.append(url)
        }
        return result
    }

    /// RAW + common delivered formats we accept on import.
    private static let supportedExtensions: Set<String> = [
        // Standard
        "jpg", "jpeg", "heic", "heif", "tif", "tiff", "png", "dng",
        // Camera RAW
        "raf", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "orf", "rw2", "pef", "raw", "rwl", "3fr", "fff", "iiq", "x3f", "gpr"
    ]

    private func fileSize(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    private func relativePath(of url: URL) -> String {
        let root = LibraryLocations.documents.path
        return url.path.hasPrefix(root)
            ? String(url.path.dropFirst(root.count).drop(while: { $0 == "/" }))
            : url.lastPathComponent
    }

    /// Appends ` (n)` before the extension until the URL is free.
    private func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var index = 1
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) (\(index))").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}

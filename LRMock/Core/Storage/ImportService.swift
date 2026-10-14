//
//  ImportService.swift
//  RawLight
//
//  Transactional managed and referenced import. Expensive inspection, hashing,
//  copying, and directory enumeration run away from the main actor; SwiftData
//  mutations remain on the main actor.
//

import Foundation
import SwiftData

nonisolated private struct InspectedImport: Sendable {
    let sourceURL: URL
    let filename: String
    let fileSize: Int64
    let metadata: RawMetadata
    let fingerprint: ImageFingerprint
    let contentDigest: String
    let bookmarkData: Data?
    let sidecar: Sidecar?
    let sidecarWarning: String?
}

@MainActor
struct ImportService {

    let modelContext: ModelContext

    struct Summary {
        var imported = 0
        var skipped = 0
        var failed = 0
        var restoredSidecars = 0
        var errors: [String] = []
        var warnings: [String] = []
    }

    private struct ImportOutcome {
        let restoredSidecar: Bool
        let warning: String?
    }

    enum ImportError: LocalizedError {
        case duplicate
        case unsupportedImage
        case digestMismatch
        case sidecarMismatch

        var errorDescription: String? {
            switch self {
            case .duplicate:
                return "This file is already in the library."
            case .unsupportedImage:
                return "The file is not a supported or readable image."
            case .digestMismatch:
                return "The managed copy did not match the selected original."
            case .sidecarMismatch:
                return "The adjacent sidecar belongs to a different image."
            }
        }
    }

    /// Imports selected files. Managed import is the default and copies original
    /// bytes into an atomic staging directory before committing catalog state.
    @discardableResult
    func importFiles(
        _ urls: [URL],
        into folder: LibraryFolder?,
        copyIntoLibrary: Bool = true
    ) async -> Summary {
        var summary = Summary()
        let explicitSidecars = Self.explicitSidecars(in: urls)
        let imageURLs = urls.filter {
            $0.pathExtension.lowercased() != SidecarService.fileExtension
        }
        for url in imageURLs {
            guard !Task.isCancelled else { break }
            do {
                let outcome = try await importOne(
                    url,
                    into: folder,
                    copyIntoLibrary: copyIntoLibrary,
                    manageScope: true,
                    explicitSidecarURL: explicitSidecars[url.standardizedFileURL.path]
                )
                summary.imported += 1
                if outcome.restoredSidecar { summary.restoredSidecars += 1 }
                if let warning = outcome.warning {
                    summary.warnings.append("\(url.lastPathComponent): \(warning)")
                }
            } catch ImportError.duplicate {
                summary.skipped += 1
            } catch is CancellationError {
                break
            } catch {
                summary.failed += 1
                summary.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return summary
    }

    /// References every supported regular image below an external directory.
    @discardableResult
    func importFolder(_ folderURL: URL, into folder: LibraryFolder?) async -> Summary {
        var summary = Summary()
        let scoped = folderURL.startAccessingSecurityScopedResource()
        defer { if scoped { folderURL.stopAccessingSecurityScopedResource() } }

        let enumeration = Task.detached(priority: .userInitiated) {
            Self.imageFiles(in: folderURL)
        }
        let files = await withTaskCancellationHandler {
            await enumeration.value
        } onCancel: {
            enumeration.cancel()
        }

        for url in files {
            guard !Task.isCancelled else { break }
            do {
                let outcome = try await importOne(
                    url,
                    into: folder,
                    copyIntoLibrary: false,
                    manageScope: false,
                    explicitSidecarURL: nil
                )
                summary.imported += 1
                if outcome.restoredSidecar { summary.restoredSidecars += 1 }
                if let warning = outcome.warning {
                    summary.warnings.append("\(url.lastPathComponent): \(warning)")
                }
            } catch ImportError.duplicate {
                summary.skipped += 1
            } catch is CancellationError {
                break
            } catch {
                summary.failed += 1
                summary.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return summary
    }

    // MARK: Single file

    private func importOne(
        _ sourceURL: URL,
        into folder: LibraryFolder?,
        copyIntoLibrary: Bool,
        manageScope: Bool,
        explicitSidecarURL: URL?
    ) async throws -> ImportOutcome {
        let inspected = try await Self.runDetached {
            try Self.inspect(
                sourceURL,
                includeBookmark: !copyIntoLibrary,
                manageScope: manageScope,
                explicitSidecarURL: explicitSidecarURL
            )
        }
        try Task.checkCancellation()

        guard try !containsAsset(withDigest: inspected.contentDigest) else {
            throw ImportError.duplicate
        }

        let assetID = UUID()
        var managedDirectory: URL?
        var recipeWritten = false

        do {
            let asset = ImageAsset(
                id: assetID,
                originalFilename: inspected.filename,
                storageMode: copyIntoLibrary ? .managed : .referenced,
                fingerprint: inspected.fingerprint,
                fileSizeBytes: inspected.fileSize
            )
            apply(inspected.metadata, to: asset)
            asset.contentDigest = inspected.contentDigest
            asset.folder = folder
            if let sidecar = inspected.sidecar {
                asset.develop = sidecar.develop
                asset.rating = min(max(sidecar.rating, 0), 5)
                asset.flagRaw = PickFlag(rawValue: sidecar.flag)?.rawValue ?? PickFlag.unflagged.rawValue
                asset.colorLabel = min(max(sidecar.colorLabel, 0), 5)
            }

            if copyIntoLibrary {
                let destination = try await Self.runDetached {
                    try Self.copyIntoManagedLibrary(
                        inspected.sourceURL,
                        assetID: assetID,
                        expectedDigest: inspected.contentDigest,
                        manageScope: manageScope
                    )
                }
                managedDirectory = destination.deletingLastPathComponent()
                try Task.checkCancellation()
                guard try !containsAsset(withDigest: inspected.contentDigest) else {
                    throw ImportError.duplicate
                }
                asset.managedRelativePath = try LibraryLocations.relativePath(of: destination)
                try Task.checkCancellation()
                let recipe = RecipeDocument(asset: asset)
                try await Self.runDetached {
                    try RecipeStore.write(recipe)
                }
                recipeWritten = true
            } else {
                asset.bookmarkData = inspected.bookmarkData
            }

            try Task.checkCancellation()
            modelContext.insert(asset)
            do {
                try Task.checkCancellation()
                try modelContext.save()
            } catch {
                modelContext.delete(asset)
                try? modelContext.save()
                throw error
            }
            return ImportOutcome(
                restoredSidecar: inspected.sidecar != nil,
                warning: inspected.sidecarWarning
            )
        } catch {
            if recipeWritten { try? RecipeStore.remove(assetID: assetID) }
            if let managedDirectory {
                try? FileManager.default.removeItem(at: managedDirectory)
            }
            throw error
        }
    }

    private func containsAsset(withDigest digest: String) throws -> Bool {
        var descriptor = FetchDescriptor<ImageAsset>(
            predicate: #Predicate<ImageAsset> { asset in
                asset.contentDigest == digest
            }
        )
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    // MARK: Background preparation

    nonisolated private static func inspect(
        _ sourceURL: URL,
        includeBookmark: Bool,
        manageScope: Bool,
        explicitSidecarURL: URL?
    ) throws -> InspectedImport {
        try Task.checkCancellation()
        let scoped = manageScope && sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let byteCount = values.fileSize, byteCount > 0 else {
            throw ImportError.unsupportedImage
        }

        let metadata = MetadataExtractor.read(from: sourceURL)
        guard metadata.pixelWidth > 0, metadata.pixelHeight > 0 else {
            throw ImportError.unsupportedImage
        }

        let filename = sourceURL.lastPathComponent
        let fileSize = Int64(byteCount)
        let fingerprint = ImageFingerprint(
            filename: filename,
            fileSizeBytes: fileSize,
            captureDate: metadata.captureDate
        )
        let digest = try ContentDigest.sha256(of: sourceURL)

        var bookmark: Data?
        if includeBookmark {
            bookmark = try BookmarkStore.makeBookmark(for: sourceURL)
        }
        var sidecar: Sidecar?
        var sidecarWarning: String?
        do {
            if let explicitSidecarURL {
                let sidecarScoped = manageScope
                    && explicitSidecarURL.startAccessingSecurityScopedResource()
                defer {
                    if sidecarScoped {
                        explicitSidecarURL.stopAccessingSecurityScopedResource()
                    }
                }
                sidecar = try SidecarService.read(at: explicitSidecarURL)
            } else {
                sidecar = try SidecarService.read(for: sourceURL)
            }
        } catch {
            guard SidecarService.isAccessDenied(error) else { throw error }
            sidecarWarning = "The adjacent .rawlight sidecar could not be read with the picker's file-only access. Select the photo and sidecar together to restore its edits."
        }
        if let sidecar {
            if let sidecarDigest = sidecar.sourceContentDigest {
                guard sidecarDigest == digest else { throw ImportError.sidecarMismatch }
            } else if sidecar.fingerprint.match(fingerprint).rawValue < ImageFingerprint.MatchStrength.strong.rawValue {
                throw ImportError.sidecarMismatch
            }
        }

        return InspectedImport(
            sourceURL: sourceURL,
            filename: filename,
            fileSize: fileSize,
            metadata: metadata,
            fingerprint: fingerprint,
            contentDigest: digest,
            bookmarkData: bookmark,
            sidecar: sidecar,
            sidecarWarning: sidecarWarning
        )
    }

    nonisolated private static func explicitSidecars(in urls: [URL]) -> [String: URL] {
        var result: [String: URL] = [:]
        for url in urls where url.pathExtension.lowercased() == SidecarService.fileExtension {
            result[url.deletingPathExtension().standardizedFileURL.path] = url
        }
        return result
    }

    /// Copies through `Incoming/<transaction>/`, verifies the complete digest,
    /// then atomically promotes the directory into `Originals/<assetID>/`.
    nonisolated private static func copyIntoManagedLibrary(
        _ source: URL,
        assetID: UUID,
        expectedDigest: String,
        manageScope: Bool
    ) throws -> URL {
        try Task.checkCancellation()
        let scoped = manageScope && source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let stagingDirectory = LibraryLocations.incoming
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let finalDirectory = LibraryLocations.managedOriginalDirectory(assetID: assetID)
        let staged = stagingDirectory.appendingPathComponent(
            source.pathExtension.isEmpty ? "primary" : "primary.\(source.pathExtension.lowercased())"
        )
        let destination = LibraryLocations.managedOriginalURL(
            assetID: assetID,
            fileExtension: source.pathExtension
        )
        var promoted = false
        defer {
            if !promoted { try? fm.removeItem(at: stagingDirectory) }
        }

        try fm.createDirectory(at: LibraryLocations.incoming, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: staged)
        try Task.checkCancellation()
        guard try ContentDigest.sha256(of: staged) == expectedDigest else {
            throw ImportError.digestMismatch
        }

        guard !fm.fileExists(atPath: finalDirectory.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.createDirectory(at: LibraryLocations.originals, withIntermediateDirectories: true)
        try fm.moveItem(at: stagingDirectory, to: finalDirectory)
        promoted = true
        return destination
    }

    nonisolated private static func runDetached<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Metadata and enumeration

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

    nonisolated private static func imageFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard !Task.isCancelled else { break }
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            result.append(url)
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "tif", "tiff", "png", "dng",
        "raf", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
        "orf", "rw2", "pef", "raw", "rwl", "3fr", "fff", "iiq", "x3f", "gpr"
    ]
}

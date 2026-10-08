//
//  ImageAsset.swift
//  RawLight
//
//  The catalog record for a single imported RAW (or other) image.
//
//  Responsibilities
//  ----------------
//  * Hold everything needed to locate the original bytes again (bookmark /
//    relative path + fingerprint for re-linking).
//  * Cache the immutable capture metadata (EXIF) so the grid/filter UI is fast
//    and works even when the original file is offline.
//  * Carry the user's mutable library metadata (rating, flag, label).
//  * Own the non-destructive `DevelopSettings` recipe.
//
//  What it deliberately does NOT do
//  --------------------------------
//  * Decode pixels. That is the `RawPipeline`'s job.
//  * Touch the filesystem. Importers/services own all I/O; the model is a dumb,
//    persisted value container so it stays easy to reason about and test.
//

import Foundation
import SwiftData

@Model
final class ImageAsset {

    // MARK: Identity
    @Attribute(.unique) var id: UUID

    /// Original file name including extension (e.g. `DSCF1234.RAF`).
    var originalFilename: String

    // MARK: Locating the original bytes
    var storageMode: StorageMode

    /// Path of the file relative to the managed library root.
    /// Set only when `storageMode == .managed`.
    var managedRelativePath: String?

    /// Security-scoped bookmark to the original file.
    /// Set only when `storageMode == .referenced`.
    var bookmarkData: Data?

    /// `true` once we failed to resolve the file; drives the "missing" badge and
    /// the re-link flow (matched via `fingerprint`).
    var isMissing: Bool

    // MARK: Re-link fingerprint (flattened for SwiftData query-ability)
    var fingerprintFilename: String
    var fingerprintSize: Int64
    var fingerprintCaptureDate: Date?
    var fingerprintHeaderHash: String?

    // MARK: Cached capture metadata (immutable; read once at import)
    var captureDate: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var isoValue: Int?
    var focalLength: Double?
    var aperture: Double?
    var shutterSpeed: String?
    var pixelWidth: Int
    var pixelHeight: Int
    /// EXIF orientation (1...8). The pipeline applies this before user geometry.
    var exifOrientation: Int

    // MARK: Library bookkeeping
    var importedAt: Date
    var fileSizeBytes: Int64

    // MARK: User metadata
    var rating: Int                 // 0...5 stars
    var flagRaw: Int                // PickFlag raw value
    var colorLabel: Int             // 0 = none, 1...5 = colours

    // MARK: Non-destructive edit recipe
    var develop: DevelopSettings

    /// File name of the cached thumbnail in the Caches directory, if generated.
    var thumbnailFileName: String?

    // MARK: Relationships
    var folder: LibraryFolder?
    @Relationship(inverse: \AssetCollection.assets)
    var collections: [AssetCollection]

    // MARK: Init
    init(
        id: UUID = UUID(),
        originalFilename: String,
        storageMode: StorageMode,
        fingerprint: ImageFingerprint,
        importedAt: Date = .now,
        fileSizeBytes: Int64 = 0
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.storageMode = storageMode
        self.managedRelativePath = nil
        self.bookmarkData = nil
        self.isMissing = false

        self.fingerprintFilename = fingerprint.filename
        self.fingerprintSize = fingerprint.fileSizeBytes
        self.fingerprintCaptureDate = fingerprint.captureDate
        self.fingerprintHeaderHash = fingerprint.headerHash

        self.captureDate = fingerprint.captureDate
        self.pixelWidth = 0
        self.pixelHeight = 0
        self.exifOrientation = 1

        self.importedAt = importedAt
        self.fileSizeBytes = fileSizeBytes

        self.rating = 0
        self.flagRaw = PickFlag.unflagged.rawValue
        self.colorLabel = 0

        self.develop = DevelopSettings()
        self.thumbnailFileName = nil
        self.collections = []
    }
}

// MARK: - Convenience

extension ImageAsset {

    /// Typed accessor for the pick/reject flag.
    var flag: PickFlag {
        get { PickFlag(rawValue: flagRaw) ?? .unflagged }
        set { flagRaw = newValue.rawValue }
    }

    /// Rebuilds the value-type fingerprint from the flattened stored fields.
    var fingerprint: ImageFingerprint {
        ImageFingerprint(
            filename: fingerprintFilename,
            fileSizeBytes: fingerprintSize,
            captureDate: fingerprintCaptureDate,
            headerHash: fingerprintHeaderHash
        )
    }

    /// Aspect ratio (w/h) using cached pixel dimensions; falls back to 3:2.
    var aspectRatio: Double {
        guard pixelWidth > 0, pixelHeight > 0 else { return 1.5 }
        return Double(pixelWidth) / Double(pixelHeight)
    }

    /// `true` when the user has made at least one develop adjustment.
    var hasEdits: Bool { !develop.isIdentity }
}

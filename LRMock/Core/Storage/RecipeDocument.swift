//
//  RecipeDocument.swift
//  RawLight
//
//  The canonical, portable edit "recipe" saved next to each managed original in
//  the library's `Recipes/` folder. Shape follows the RawLight design
//  (docs/architecture/catalog-and-persistence.md: "Recipe Document"): pipeline
//  identity, working colour, geometry, and parameter values — plus the user's
//  culling metadata (rating/flag/label).
//
//  For exact, lossless reconstruction we also embed the full `DevelopSettings`
//  under `develop`; the `parameters` dictionary is a stable, human-readable
//  projection for interop/debugging. On read we prefer `develop`.
//

import Foundation

nonisolated struct RecipeDocument: Codable, Sendable {

    static let formatIdentifier = "com.rawlight.recipe"
    static let currentSchemaVersion = 1

    struct Pipeline: Codable, Equatable, Sendable {
        var id = "com.rawlight.apple-coreimage"
        var semanticVersion = "1.0.0"
        var decoderFamily = "apple-raw"
        var decoderVersion = "runtime-recorded"
    }
    struct WorkingColor: Codable, Equatable, Sendable {
        var space = "extended-linear-display-p3"
        var intent = "relative-colorimetric"
    }
    struct Crop: Codable, Sendable { var x, y, width, height: Double }
    struct Geometry: Codable, Sendable {
        var orientation = 1
        var crop = Crop(x: 0, y: 0, width: 1, height: 1)
        var rotationDegrees = 0.0
        var flipHorizontal = false
        var flipVertical = false
    }

    var format = RecipeDocument.formatIdentifier
    var schemaVersion = RecipeDocument.currentSchemaVersion
    var recipeID: UUID
    var assetID: UUID
    var editablePrimaryResourceID: UUID
    var sourceContentDigest: String?
    var pipeline = Pipeline()
    var workingColor = WorkingColor()
    var geometry = Geometry()
    var parameters: [String: Double] = [:]
    var develop: DevelopSettings
    var rating: Int
    var flag: Int
    var colorLabel: Int
    var createdAt: Date
    var modifiedAt: Date
}

extension RecipeDocument {

    nonisolated private static func projectedGeometry(
        from develop: DevelopSettings,
        orientation: Int
    ) -> Geometry {
        Geometry(
            orientation: min(max(orientation, 1), 8),
            crop: Crop(
                x: develop.cropX,
                y: develop.cropY,
                width: develop.cropW,
                height: develop.cropH
            ),
            rotationDegrees: Double(develop.rotationQuarterTurns) * 90 + develop.straighten,
            flipHorizontal: develop.flipH,
            flipVertical: develop.flipV
        )
    }

    nonisolated private static func projectedParameters(from develop: DevelopSettings) -> [String: Double] {
        [
            "foundation.exposureEV": develop.exposure * 2.5,
            "foundation.contrast": develop.contrast,
            "foundation.highlights": develop.highlights,
            "foundation.shadows": develop.shadows,
            "foundation.whites": develop.whites,
            "foundation.blacks": develop.blacks,
            "foundation.whiteBalance.temperature": develop.temperature,
            "foundation.whiteBalance.tint": develop.tint,
            "color.vibrance": develop.vibrance,
            "color.saturation": develop.saturation,
            "surface.texture": develop.texture,
            "surface.clarity": develop.clarity,
            "surface.dehaze": develop.dehaze,
            "effects.vignette": develop.vignette,
            "effects.grain": develop.grain,
            "detail.sharpness": develop.sharpness,
            "detail.noiseReduction": develop.noiseReduction
        ]
    }

    /// Builds a recipe document from a catalog asset.
    @MainActor
    init(asset: ImageAsset) {
        let d = asset.develop.normalizedForPersistence()
        self.recipeID = asset.id
        self.assetID = asset.id
        self.editablePrimaryResourceID = asset.id
        self.sourceContentDigest = asset.contentDigest
        self.develop = d
        self.rating = asset.rating
        self.flag = asset.flagRaw
        self.colorLabel = asset.colorLabel
        self.createdAt = asset.importedAt
        self.modifiedAt = .now
        self.geometry = Self.projectedGeometry(from: d, orientation: asset.exifOrientation)
        self.parameters = Self.projectedParameters(from: d)
    }

    nonisolated func normalizedForPersistence() -> RecipeDocument {
        var normalized = self
        let develop = develop.normalizedForPersistence()
        normalized.format = Self.formatIdentifier
        normalized.schemaVersion = Self.currentSchemaVersion
        normalized.recipeID = assetID
        normalized.editablePrimaryResourceID = assetID
        normalized.pipeline = Pipeline()
        normalized.workingColor = WorkingColor()
        normalized.develop = develop
        normalized.rating = min(max(rating, 0), 5)
        normalized.flag = PickFlag(rawValue: flag)?.rawValue ?? PickFlag.unflagged.rawValue
        normalized.colorLabel = min(max(colorLabel, 0), 5)
        normalized.geometry = Self.projectedGeometry(
            from: develop,
            orientation: geometry.orientation
        )
        normalized.parameters = Self.projectedParameters(from: develop)
        return normalized
    }

    /// Applies a decoded recipe back onto an asset (exact reconstruction).
    @MainActor
    func apply(to asset: ImageAsset) {
        asset.develop = develop.normalizedForPersistence()
        asset.rating = min(max(rating, 0), 5)
        asset.flagRaw = PickFlag(rawValue: flag)?.rawValue ?? PickFlag.unflagged.rawValue
        asset.colorLabel = min(max(colorLabel, 0), 5)
    }
}

/// Reads/writes recipe documents in the library's `Recipes/` folder.
nonisolated enum RecipeStore {

    enum RecipeError: LocalizedError, Equatable {
        case unsupportedFormat(String)
        case unsupportedVersion(Int)
        case unsupportedPipeline
        case unsupportedWorkingColor
        case assetMismatch
        case sourceMismatch
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format):
                return "The recipe format is unsupported: \(format)."
            case .unsupportedVersion(let version):
                return "The recipe uses unsupported version \(version)."
            case .unsupportedPipeline:
                return "The recipe uses an unsupported processing pipeline."
            case .unsupportedWorkingColor:
                return "The recipe uses an unsupported working color configuration."
            case .assetMismatch:
                return "The recipe belongs to a different asset."
            case .sourceMismatch:
                return "The recipe belongs to different source bytes."
            case .fileTooLarge:
                return "The recipe is larger than the supported limit."
            }
        }
    }

    private static let format = RecipeDocument.formatIdentifier
    private static let schemaVersion = RecipeDocument.currentSchemaVersion
    private static let maximumFileSize = 4 * 1024 * 1024
    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Writes the asset's recipe into `Recipes/<assetID>.rawlight.json`.
    @MainActor
    static func write(for asset: ImageAsset) throws {
        try write(RecipeDocument(asset: asset))
    }

    /// Writes an already-snapshotted document. Safe to call from background
    /// persistence work because it does not access a SwiftData model.
    static func write(_ document: RecipeDocument) throws {
        let normalized = document.normalizedForPersistence()
        _ = try validate(normalized, assetID: normalized.assetID)
        let url = LibraryLocations.recipeURL(assetID: normalized.assetID)
        let data = try makeEncoder().encode(normalized)
        guard data.count <= maximumFileSize else {
            throw RecipeError.fileTooLarge
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Reads a recipe document for an asset ID, if present.
    static func read(assetID: UUID, sourceContentDigest: String? = nil) throws -> RecipeDocument? {
        let url = LibraryLocations.recipeURL(assetID: assetID)
        let data: Data
        do {
            guard let contents = try BoundedFileReader.readRegularFile(
                at: url,
                maximumByteCount: maximumFileSize
            ) else {
                return nil
            }
            data = contents
        } catch BoundedFileReader.ReadError.fileTooLarge {
            throw RecipeError.fileTooLarge
        } catch {
            if BoundedFileReader.isMissingFile(error) { return nil }
            throw error
        }
        let document = try makeDecoder().decode(RecipeDocument.self, from: data)
        return try validate(
            document,
            assetID: assetID,
            sourceContentDigest: sourceContentDigest
        )
    }

    /// Validates decoded identity before any recipe is applied to catalog state.
    /// Schema-v1 documents predate source digests, so a missing digest is
    /// accepted only after all three asset identity fields match.
    static func validate(
        _ document: RecipeDocument,
        assetID: UUID,
        sourceContentDigest: String? = nil
    ) throws -> RecipeDocument {
        guard document.format == format else {
            throw RecipeError.unsupportedFormat(document.format)
        }
        guard document.schemaVersion == schemaVersion else {
            throw RecipeError.unsupportedVersion(document.schemaVersion)
        }
        guard document.pipeline == RecipeDocument.Pipeline() else {
            throw RecipeError.unsupportedPipeline
        }
        guard document.workingColor == RecipeDocument.WorkingColor() else {
            throw RecipeError.unsupportedWorkingColor
        }
        guard document.assetID == assetID,
              document.recipeID == assetID,
              document.editablePrimaryResourceID == assetID
        else {
            throw RecipeError.assetMismatch
        }
        if let sourceContentDigest,
           let documentDigest = document.sourceContentDigest,
           documentDigest != sourceContentDigest {
            throw RecipeError.sourceMismatch
        }
        return document.normalizedForPersistence()
    }

    static func remove(assetID: UUID) throws {
        let url = LibraryLocations.recipeURL(assetID: assetID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

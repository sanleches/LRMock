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

    struct Pipeline: Codable, Sendable {
        var id = "com.rawlight.apple-coreimage"
        var semanticVersion = "1.0.0"
        var decoderFamily = "apple-raw"
        var decoderVersion = "runtime-recorded"
    }
    struct WorkingColor: Codable, Sendable {
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

    var format = "com.rawlight.recipe"
    var schemaVersion = 1
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

    /// Builds a recipe document from a catalog asset.
    @MainActor
    init(asset: ImageAsset) {
        let d = asset.develop
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
        self.geometry = Geometry(
            orientation: asset.exifOrientation,
            crop: Crop(x: d.cropX, y: d.cropY, width: d.cropW, height: d.cropH),
            rotationDegrees: Double(d.rotationQuarterTurns) * 90 + d.straighten,
            flipHorizontal: d.flipH, flipVertical: d.flipV)
        self.parameters = [
            "foundation.exposureEV": d.exposure * 2.5,
            "foundation.contrast": d.contrast,
            "foundation.highlights": d.highlights,
            "foundation.shadows": d.shadows,
            "foundation.whites": d.whites,
            "foundation.blacks": d.blacks,
            "foundation.whiteBalance.temperature": d.temperature,
            "foundation.whiteBalance.tint": d.tint,
            "color.vibrance": d.vibrance,
            "color.saturation": d.saturation,
            "surface.texture": d.texture,
            "surface.clarity": d.clarity,
            "surface.dehaze": d.dehaze,
            "effects.vignette": d.vignette,
            "effects.grain": d.grain,
            "detail.sharpness": d.sharpness,
            "detail.noiseReduction": d.noiseReduction
        ]
    }

    /// Applies a decoded recipe back onto an asset (exact reconstruction).
    @MainActor
    func apply(to asset: ImageAsset) {
        asset.develop = develop
        asset.rating = rating
        asset.flagRaw = flag
        asset.colorLabel = colorLabel
    }
}

/// Reads/writes recipe documents in the library's `Recipes/` folder.
nonisolated enum RecipeStore {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes the asset's recipe into `Recipes/<assetID>.rawlight.json`.
    @MainActor
    static func write(for asset: ImageAsset) throws {
        let url = LibraryLocations.recipeURL(assetID: asset.id)
        let data = try encoder.encode(RecipeDocument(asset: asset))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Reads a recipe document for an asset ID, if present.
    static func read(assetID: UUID) throws -> RecipeDocument? {
        let url = LibraryLocations.recipeURL(assetID: assetID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(RecipeDocument.self, from: data)
    }

    static func remove(assetID: UUID) throws {
        let url = LibraryLocations.recipeURL(assetID: assetID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

//
//  CatalogSchemaV1.swift
//  RawLight
//
//  Frozen persistence model for the original pre-generation catalog release.
//  It is used only to read an immutable SQLite snapshot during migration.
//

import Foundation
import SwiftData

nonisolated enum CatalogSchemaV1 {

    static let schema = Schema([
        ImageAsset.self,
        LibraryFolder.self,
        AssetCollection.self,
    ])

    enum StorageMode: String, Codable, Sendable {
        case managed
        case referenced
    }

    enum FolderKind: String, Codable, Sendable {
        case managed
        case external
    }

    struct DevelopSettings: Codable, Equatable, Sendable {
        var schemaVersion = 1
        var temperature = 0.0
        var tint = 0.0
        var exposure = 0.0
        var contrast = 0.0
        var highlights = 0.0
        var shadows = 0.0
        var whites = 0.0
        var blacks = 0.0
        var vibrance = 0.0
        var saturation = 0.0
        var sharpness = 0.0
        var noiseReduction = 0.0
        var rotationQuarterTurns = 0
    }

    @Model
    final class ImageAsset {
        @Attribute(.unique) var id: UUID
        var originalFilename: String

        var storageMode: StorageMode
        var managedRelativePath: String?
        var bookmarkData: Data?
        var isMissing: Bool

        var fingerprintFilename: String
        var fingerprintSize: Int64
        var fingerprintCaptureDate: Date?
        var fingerprintHeaderHash: String?

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
        var exifOrientation: Int

        var importedAt: Date
        var fileSizeBytes: Int64
        var rating: Int
        var flagRaw: Int
        var colorLabel: Int
        var develop: DevelopSettings
        var thumbnailFileName: String?

        var folder: LibraryFolder?
        @Relationship(inverse: \AssetCollection.assets)
        var collections: [AssetCollection]

        init(
            id: UUID = UUID(),
            originalFilename: String,
            storageMode: StorageMode,
            fingerprintFilename: String,
            fingerprintSize: Int64,
            fingerprintCaptureDate: Date? = nil,
            fingerprintHeaderHash: String? = nil,
            importedAt: Date = .now,
            fileSizeBytes: Int64 = 0
        ) {
            self.id = id
            self.originalFilename = originalFilename
            self.storageMode = storageMode
            self.managedRelativePath = nil
            self.bookmarkData = nil
            self.isMissing = false
            self.fingerprintFilename = fingerprintFilename
            self.fingerprintSize = fingerprintSize
            self.fingerprintCaptureDate = fingerprintCaptureDate
            self.fingerprintHeaderHash = fingerprintHeaderHash
            self.captureDate = fingerprintCaptureDate
            self.pixelWidth = 0
            self.pixelHeight = 0
            self.exifOrientation = 1
            self.importedAt = importedAt
            self.fileSizeBytes = fileSizeBytes
            self.rating = 0
            self.flagRaw = 0
            self.colorLabel = 0
            self.develop = DevelopSettings()
            self.thumbnailFileName = nil
            self.collections = []
        }
    }

    @Model
    final class LibraryFolder {
        @Attribute(.unique) var id: UUID
        var name: String
        var kind: FolderKind
        var bookmarkData: Data?
        var sortIndex: Int
        var createdAt: Date

        @Relationship(deleteRule: .nullify, inverse: \ImageAsset.folder)
        var assets: [ImageAsset]

        init(
            id: UUID = UUID(),
            name: String,
            kind: FolderKind = .managed,
            sortIndex: Int = 0,
            createdAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.bookmarkData = nil
            self.sortIndex = sortIndex
            self.createdAt = createdAt
            self.assets = []
        }
    }

    @Model
    final class AssetCollection {
        @Attribute(.unique) var id: UUID
        var name: String
        var symbol: String
        var sortIndex: Int
        var createdAt: Date
        var assets: [ImageAsset]

        init(
            id: UUID = UUID(),
            name: String,
            symbol: String = "rectangle.stack",
            sortIndex: Int = 0,
            createdAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.symbol = symbol
            self.sortIndex = sortIndex
            self.createdAt = createdAt
            self.assets = []
        }
    }
}

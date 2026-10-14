//
//  CatalogV4Migration.swift
//  RawLight
//
//  Copies a schema-v4 catalog into a separately validated current-schema store
//  before atomically promoting it. The source store is always retained as a
//  sibling backup.
//

import Foundation
import CryptoKit
import Darwin
import SQLite3
import SwiftData

nonisolated enum CatalogV4Migration {

    static let backupDirectoryPrefix = "Catalog.v4-backup-"
    static let stagingDirectoryPrefix = "Catalog.migrating-"
    static let temporaryWorkspaceDirectoryPrefix = "RawLight-CatalogScratch-"
    private static let migrationMarkerName = "CatalogMigration.json"
    private static let artifactQuarantineName = "CatalogArtifactQuarantine.json"
    private static let temporaryMigrationDirectoryPrefix = "RawLight-CatalogMigration-"
    private static let temporaryRecoveryDirectoryPrefix = "RawLight-CatalogRecovery-"
    private static let metadataMaximumByteCount = 16 * 1024
    private static let legacySidecarMaximumByteCount = 2 * 1024 * 1024
    private static let v1ModelChecksum = "0wOU7VUgplIVqUD8Qp52nAG+tOOx99x17ws2qqBE8AY="
    private static let v4ModelChecksum = "G2jB6Go5v/b/T/7eLJKm1x6mcr7QZp2oQ0+BvlMXWO8="
    private static let currentModelChecksum = "xJVl3cWR/18+CFerTqcIbDnZsYn2iub5b5wDuLre31o="

    private static let promotionObservationLock = NSLock()
    nonisolated(unsafe) private static var promotionObservationCount = 0
    private static let temporaryWorkspaceLock = NSLock()
    nonisolated(unsafe) private static var temporaryWorkspaceRoot: URL?

    enum StoreFormat: Equatable {
        case current
        case v1
        case v4

        var isLegacy: Bool { self != .current }

        var schemaVersion: Int {
            switch self {
            case .current: return DevelopSettings.currentSchemaVersion
            case .v1: return 1
            case .v4: return 4
            }
        }
    }

    struct StoreProbe: Equatable {
        let format: StoreFormat
        let assetCount: Int
        let folderCount: Int
        let collectionCount: Int

        var isEmpty: Bool {
            assetCount == 0 && folderCount == 0 && collectionCount == 0
        }
    }

    struct MigrationResult {
        let preparation: LibraryLocations.CatalogPreparation
        let legacySourceIdentity: SourceIdentity?
        let sourceLease: SourceLease?
    }

    final class SourceLease {
        private let source: ExclusiveSQLiteSource

        fileprivate init(at sourceURL: URL) throws {
            source = try ExclusiveSQLiteSource(at: sourceURL)
        }

        fileprivate func backup(to destinationURL: URL) throws {
            try source.backup(to: destinationURL)
        }
    }

    struct SourceIdentity: Codable, Equatable {
        let schemaVersion: Int
        let sha256: String
        let byteCount: Int64
    }

    private struct ManagedFilesIdentity: Codable, Equatable {
        let managedAssetCount: Int
        let sha256: String
    }

    private struct ManagedFileManifestEntry: Codable {
        let assetID: UUID
        let relativePath: String
        let originalByteCount: Int64
        let originalSHA256: String
        let sidecarByteCount: Int64?
        let sidecarSHA256: String?
    }

    private struct ManagedFileMigration {
        let relativePaths: [UUID: String]
        let identity: ManagedFilesIdentity
    }

    private struct LegacyManagedSource {
        let originalURL: URL
        let sidecarURL: URL?
        let originalFile: ContentDigest.PinnedRegularFile
        let sidecarFile: ContentDigest.PinnedRegularFile?
        let relativePath: String
        let originalByteCount: Int64
        let originalSHA256: String
        let sidecarByteCount: Int64?
        let sidecarSHA256: String?
    }

    private struct PendingLegacyMigration {
        let sourceIdentity: SourceIdentity
        let managedFilesIdentity: ManagedFilesIdentity
    }

    private struct MigrationMarker: Codable {
        enum Role: String, Codable {
            case v4Backup
            case currentStaging
        }

        enum SourceKind: String, Codable {
            case generation
            case legacyDefault
        }

        let schemaVersion: Int
        let migrationID: UUID
        let generationID: UUID
        let sourceIdentity: SourceIdentity
        let legacySourceIdentity: SourceIdentity?
        let role: Role
        let sourceKind: SourceKind
        let managedFilesIdentity: ManagedFilesIdentity?
    }

    private struct MigrationArtifact {
        let directory: URL
        let marker: MigrationMarker
    }

    private struct MigrationArtifacts {
        var backups: [UUID: MigrationArtifact] = [:]
        var staging: [UUID: MigrationArtifact] = [:]
        var invalidBackups: [(directory: URL, reason: String)] = []
    }

    private struct ArtifactQuarantine: Codable {
        struct Entry: Codable {
            let directoryName: String
            let reason: String
        }

        let schemaVersion: Int
        let generationID: UUID
        let entries: [Entry]
    }

    private enum SQLiteHandleTracker {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var count = 0

        static func opened() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        static func closed() {
            lock.lock()
            count -= 1
            lock.unlock()
        }

        static var openCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    static func resetPromotionObservationForTesting() {
        promotionObservationLock.lock()
        promotionObservationCount = 0
        promotionObservationLock.unlock()
    }

    static var promotionObservationCountForTesting: Int {
        promotionObservationLock.lock()
        defer { promotionObservationLock.unlock() }
        return promotionObservationCount
    }

    static var openSQLiteHandleCountForTesting: Int {
        SQLiteHandleTracker.openCount
    }

    /// SwiftData does not expose a reliable close operation, so temporary stores
    /// remain intact for their owning process. A later process can safely remove
    /// them after the owner PID no longer exists.
    static func cleanupStaleTemporaryWorkspaces() {
        temporaryWorkspaceLock.lock()
        defer { temporaryWorkspaceLock.unlock() }
        cleanupStaleTemporaryWorkspacesLocked()
    }

    private static func cleanupStaleTemporaryWorkspacesLocked() {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let currentWorkspaceName = temporaryWorkspaceRoot?.lastPathComponent
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(temporaryWorkspaceDirectoryPrefix),
                  name != currentWorkspaceName,
                  let ownerPID = temporaryWorkspaceOwnerPID(from: name),
                  ownerPID == getpid() || !processIsRunning(ownerPID),
                  let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func temporaryWorkspaceOwnerPID(from name: String) -> pid_t? {
        let suffix = name.dropFirst(temporaryWorkspaceDirectoryPrefix.count)
        guard let separator = suffix.firstIndex(of: "-") else { return nil }
        let identifier = suffix[suffix.index(after: separator)...]
        guard UUID(uuidString: String(identifier)) != nil else { return nil }
        return pid_t(String(suffix[..<separator]))
    }

    private static func processIsRunning(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private static func makeTemporaryWorkspaceDirectory(prefix: String) throws -> URL {
        temporaryWorkspaceLock.lock()
        defer { temporaryWorkspaceLock.unlock() }

        let fileManager = FileManager.default
        let root: URL
        if let existing = temporaryWorkspaceRoot,
           (try? existing.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            root = existing
        } else {
            cleanupStaleTemporaryWorkspacesLocked()
            root = fileManager.temporaryDirectory.appendingPathComponent(
                temporaryWorkspaceDirectoryPrefix
                    + "\(getpid())-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
            temporaryWorkspaceRoot = root
        }

        let directory = root.appendingPathComponent(
            prefix + UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private enum MigrationError: LocalizedError {
        case unsafeCatalog(URL)
        case invalidSource(String)
        case validationFailed(String)
        case sourceInUse(URL, String)
        case sqliteSnapshotFailed(URL, String)
        case interruptedMigration(String)

        var errorDescription: String? {
            switch self {
            case .unsafeCatalog(let url):
                return "The catalog migration path is unsafe: \(url.path)"
            case .invalidSource(let message):
                return "The schema-v4 catalog is inconsistent: \(message)"
            case .validationFailed(let message):
                return "The migrated catalog failed validation: \(message)"
            case .sourceInUse(let url, let message):
                return "The schema-v4 catalog at \(url.path) is open or cannot be exclusively coordinated. Close every older RawLight process and retry. SQLite reported: \(message)"
            case .sqliteSnapshotFailed(let url, let message):
                return "A coherent SQLite snapshot of the schema-v4 catalog at \(url.path) could not be created: \(message)"
            case .interruptedMigration(let message):
                return "An interrupted catalog migration could not be recovered safely: \(message)"
            }
        }
    }

    private struct CurvePointSnapshot: Equatable {
        let x: Double
        let y: Double
    }

    private struct DevelopSnapshot: Equatable {
        let doubles: [String: Double]
        let booleans: [String: Bool]
        let integers: [String: Int]
        let curves: [String: [CurvePointSnapshot]]
        let colorMixHue: [Double]
        let colorMixSaturation: [Double]
        let colorMixLuminance: [Double]
        let grade: [String: Double]

        init(_ settings: CatalogSchemaV4.DevelopSettings) {
            doubles = Self.doubles(
                temperature: settings.temperature,
                tint: settings.tint,
                exposure: settings.exposure,
                contrast: settings.contrast,
                highlights: settings.highlights,
                shadows: settings.shadows,
                whites: settings.whites,
                blacks: settings.blacks,
                texture: settings.texture,
                clarity: settings.clarity,
                dehaze: settings.dehaze,
                vibrance: settings.vibrance,
                saturation: settings.saturation,
                bwRed: settings.bwRed,
                bwGreen: settings.bwGreen,
                bwBlue: settings.bwBlue,
                sharpness: settings.sharpness,
                sharpenRadius: settings.sharpenRadius,
                noiseReduction: settings.noiseReduction,
                colorNoiseReduction: settings.colorNoiseReduction,
                grain: settings.grain,
                vignette: settings.vignette,
                cropX: settings.cropX,
                cropY: settings.cropY,
                cropW: settings.cropW,
                cropH: settings.cropH,
                straighten: settings.straighten
            )
            booleans = [
                "blackWhite": settings.blackWhite,
                "flipH": settings.flipH,
                "flipV": settings.flipV,
            ]
            integers = ["rotationQuarterTurns": settings.rotationQuarterTurns]
            curves = [
                "toneCurve": settings.toneCurve.map { .init(x: $0.x, y: $0.y) },
                "toneCurveRed": settings.toneCurveRed.map { .init(x: $0.x, y: $0.y) },
                "toneCurveGreen": settings.toneCurveGreen.map { .init(x: $0.x, y: $0.y) },
                "toneCurveBlue": settings.toneCurveBlue.map { .init(x: $0.x, y: $0.y) },
            ]
            colorMixHue = settings.colorMix.hue
            colorMixSaturation = settings.colorMix.saturation
            colorMixLuminance = settings.colorMix.luminance
            grade = Self.grade(
                shadowHue: settings.grade.shadowHue,
                shadowSat: settings.grade.shadowSat,
                midHue: settings.grade.midHue,
                midSat: settings.grade.midSat,
                highHue: settings.grade.highHue,
                highSat: settings.grade.highSat
            )
        }

        init(_ settings: CatalogSchemaV1.DevelopSettings) {
            doubles = Self.doubles(
                temperature: settings.temperature,
                tint: settings.tint,
                exposure: settings.exposure,
                contrast: settings.contrast,
                highlights: settings.highlights,
                shadows: settings.shadows,
                whites: settings.whites,
                blacks: settings.blacks,
                texture: 0,
                clarity: 0,
                dehaze: 0,
                vibrance: settings.vibrance,
                saturation: settings.saturation,
                bwRed: 0,
                bwGreen: 0,
                bwBlue: 0,
                sharpness: settings.sharpness,
                sharpenRadius: 0,
                noiseReduction: settings.noiseReduction,
                colorNoiseReduction: 0,
                grain: 0,
                vignette: 0,
                cropX: 0,
                cropY: 0,
                cropW: 1,
                cropH: 1,
                straighten: 0
            )
            booleans = ["blackWhite": false, "flipH": false, "flipV": false]
            integers = ["rotationQuarterTurns": settings.rotationQuarterTurns]
            let linear = [0.0, 0.25, 0.5, 0.75, 1.0].map {
                CurvePointSnapshot(x: $0, y: $0)
            }
            curves = [
                "toneCurve": linear,
                "toneCurveRed": linear,
                "toneCurveGreen": linear,
                "toneCurveBlue": linear,
            ]
            colorMixHue = Array(repeating: 0, count: 8)
            colorMixSaturation = Array(repeating: 0, count: 8)
            colorMixLuminance = Array(repeating: 0, count: 8)
            grade = Self.grade(
                shadowHue: 0,
                shadowSat: 0,
                midHue: 0,
                midSat: 0,
                highHue: 0,
                highSat: 0
            )
        }

        init(_ settings: DevelopSettings) {
            doubles = Self.doubles(
                temperature: settings.temperature,
                tint: settings.tint,
                exposure: settings.exposure,
                contrast: settings.contrast,
                highlights: settings.highlights,
                shadows: settings.shadows,
                whites: settings.whites,
                blacks: settings.blacks,
                texture: settings.texture,
                clarity: settings.clarity,
                dehaze: settings.dehaze,
                vibrance: settings.vibrance,
                saturation: settings.saturation,
                bwRed: settings.bwRed,
                bwGreen: settings.bwGreen,
                bwBlue: settings.bwBlue,
                sharpness: settings.sharpness,
                sharpenRadius: settings.sharpenRadius,
                noiseReduction: settings.noiseReduction,
                colorNoiseReduction: settings.colorNoiseReduction,
                grain: settings.grain,
                vignette: settings.vignette,
                cropX: settings.cropX,
                cropY: settings.cropY,
                cropW: settings.cropW,
                cropH: settings.cropH,
                straighten: settings.straighten
            )
            booleans = [
                "blackWhite": settings.blackWhite,
                "flipH": settings.flipH,
                "flipV": settings.flipV,
            ]
            integers = ["rotationQuarterTurns": settings.rotationQuarterTurns]
            curves = [
                "toneCurve": settings.toneCurve.map { .init(x: $0.x, y: $0.y) },
                "toneCurveRed": settings.toneCurveRed.map { .init(x: $0.x, y: $0.y) },
                "toneCurveGreen": settings.toneCurveGreen.map { .init(x: $0.x, y: $0.y) },
                "toneCurveBlue": settings.toneCurveBlue.map { .init(x: $0.x, y: $0.y) },
            ]
            colorMixHue = settings.colorMix.hue
            colorMixSaturation = settings.colorMix.saturation
            colorMixLuminance = settings.colorMix.luminance
            grade = Self.grade(
                shadowHue: settings.grade.shadowHue,
                shadowSat: settings.grade.shadowSat,
                midHue: settings.grade.midHue,
                midSat: settings.grade.midSat,
                highHue: settings.grade.highHue,
                highSat: settings.grade.highSat
            )
        }

        private static func doubles(
            temperature: Double,
            tint: Double,
            exposure: Double,
            contrast: Double,
            highlights: Double,
            shadows: Double,
            whites: Double,
            blacks: Double,
            texture: Double,
            clarity: Double,
            dehaze: Double,
            vibrance: Double,
            saturation: Double,
            bwRed: Double,
            bwGreen: Double,
            bwBlue: Double,
            sharpness: Double,
            sharpenRadius: Double,
            noiseReduction: Double,
            colorNoiseReduction: Double,
            grain: Double,
            vignette: Double,
            cropX: Double,
            cropY: Double,
            cropW: Double,
            cropH: Double,
            straighten: Double
        ) -> [String: Double] {
            [
                "temperature": temperature,
                "tint": tint,
                "exposure": exposure,
                "contrast": contrast,
                "highlights": highlights,
                "shadows": shadows,
                "whites": whites,
                "blacks": blacks,
                "texture": texture,
                "clarity": clarity,
                "dehaze": dehaze,
                "vibrance": vibrance,
                "saturation": saturation,
                "bwRed": bwRed,
                "bwGreen": bwGreen,
                "bwBlue": bwBlue,
                "sharpness": sharpness,
                "sharpenRadius": sharpenRadius,
                "noiseReduction": noiseReduction,
                "colorNoiseReduction": colorNoiseReduction,
                "grain": grain,
                "vignette": vignette,
                "cropX": cropX,
                "cropY": cropY,
                "cropW": cropW,
                "cropH": cropH,
                "straighten": straighten,
            ]
        }

        private static func grade(
            shadowHue: Double,
            shadowSat: Double,
            midHue: Double,
            midSat: Double,
            highHue: Double,
            highSat: Double
        ) -> [String: Double] {
            [
                "shadowHue": shadowHue,
                "shadowSat": shadowSat,
                "midHue": midHue,
                "midSat": midSat,
                "highHue": highHue,
                "highSat": highSat,
            ]
        }
    }

    private struct AssetSnapshot: Equatable {
        let id: UUID
        let originalFilename: String
        let storageMode: String
        var managedRelativePath: String?
        let bookmarkData: Data?
        let isMissing: Bool
        let fingerprintFilename: String
        let fingerprintSize: Int64
        let fingerprintCaptureDate: Date?
        let fingerprintHeaderHash: String?
        let contentDigest: String?
        let captureDate: Date?
        let cameraMake: String?
        let cameraModel: String?
        let lensModel: String?
        let isoValue: Int?
        let focalLength: Double?
        let aperture: Double?
        let shutterSpeed: String?
        let pixelWidth: Int
        let pixelHeight: Int
        let exifOrientation: Int
        let importedAt: Date
        let fileSizeBytes: Int64
        let rating: Int
        let flagRaw: Int
        let colorLabel: Int
        let develop: DevelopSnapshot
        let thumbnailFileName: String?
        let folderID: UUID?
        let collectionIDs: Set<UUID>

        init(_ asset: CatalogSchemaV4.ImageAsset) {
            id = asset.id
            originalFilename = asset.originalFilename
            storageMode = asset.storageMode.rawValue
            managedRelativePath = asset.managedRelativePath
            bookmarkData = asset.bookmarkData
            isMissing = asset.isMissing
            fingerprintFilename = asset.fingerprintFilename
            fingerprintSize = asset.fingerprintSize
            fingerprintCaptureDate = asset.fingerprintCaptureDate
            fingerprintHeaderHash = asset.fingerprintHeaderHash
            contentDigest = asset.contentDigest
            captureDate = asset.captureDate
            cameraMake = asset.cameraMake
            cameraModel = asset.cameraModel
            lensModel = asset.lensModel
            isoValue = asset.isoValue
            focalLength = asset.focalLength
            aperture = asset.aperture
            shutterSpeed = asset.shutterSpeed
            pixelWidth = asset.pixelWidth
            pixelHeight = asset.pixelHeight
            exifOrientation = asset.exifOrientation
            importedAt = asset.importedAt
            fileSizeBytes = asset.fileSizeBytes
            rating = asset.rating
            flagRaw = asset.flagRaw
            colorLabel = asset.colorLabel
            develop = DevelopSnapshot(asset.develop)
            thumbnailFileName = asset.thumbnailFileName
            folderID = asset.folder?.id
            collectionIDs = Set(asset.collections.map(\.id))
        }

        init(_ asset: CatalogSchemaV1.ImageAsset) {
            id = asset.id
            originalFilename = asset.originalFilename
            storageMode = asset.storageMode.rawValue
            managedRelativePath = asset.managedRelativePath
            bookmarkData = asset.bookmarkData
            isMissing = asset.isMissing
            fingerprintFilename = asset.fingerprintFilename
            fingerprintSize = asset.fingerprintSize
            fingerprintCaptureDate = asset.fingerprintCaptureDate
            fingerprintHeaderHash = asset.fingerprintHeaderHash
            contentDigest = nil
            captureDate = asset.captureDate
            cameraMake = asset.cameraMake
            cameraModel = asset.cameraModel
            lensModel = asset.lensModel
            isoValue = asset.isoValue
            focalLength = asset.focalLength
            aperture = asset.aperture
            shutterSpeed = asset.shutterSpeed
            pixelWidth = asset.pixelWidth
            pixelHeight = asset.pixelHeight
            exifOrientation = asset.exifOrientation
            importedAt = asset.importedAt
            fileSizeBytes = asset.fileSizeBytes
            rating = asset.rating
            flagRaw = asset.flagRaw
            colorLabel = asset.colorLabel
            develop = DevelopSnapshot(asset.develop)
            thumbnailFileName = asset.thumbnailFileName
            folderID = asset.folder?.id
            collectionIDs = Set(asset.collections.map(\.id))
        }

        init(_ asset: ImageAsset) {
            id = asset.id
            originalFilename = asset.originalFilename
            storageMode = asset.storageMode.rawValue
            managedRelativePath = asset.managedRelativePath
            bookmarkData = asset.bookmarkData
            isMissing = asset.isMissing
            fingerprintFilename = asset.fingerprintFilename
            fingerprintSize = asset.fingerprintSize
            fingerprintCaptureDate = asset.fingerprintCaptureDate
            fingerprintHeaderHash = asset.fingerprintHeaderHash
            contentDigest = asset.contentDigest
            captureDate = asset.captureDate
            cameraMake = asset.cameraMake
            cameraModel = asset.cameraModel
            lensModel = asset.lensModel
            isoValue = asset.isoValue
            focalLength = asset.focalLength
            aperture = asset.aperture
            shutterSpeed = asset.shutterSpeed
            pixelWidth = asset.pixelWidth
            pixelHeight = asset.pixelHeight
            exifOrientation = asset.exifOrientation
            importedAt = asset.importedAt
            fileSizeBytes = asset.fileSizeBytes
            rating = asset.rating
            flagRaw = asset.flagRaw
            colorLabel = asset.colorLabel
            develop = DevelopSnapshot(asset.develop)
            thumbnailFileName = asset.thumbnailFileName
            folderID = asset.folder?.id
            collectionIDs = Set(asset.collections.map(\.id))
        }
    }

    private struct FolderSnapshot: Equatable {
        let id: UUID
        let name: String
        let kind: String
        let bookmarkData: Data?
        let sortIndex: Int
        let createdAt: Date
        let assetIDs: Set<UUID>

        init(_ folder: CatalogSchemaV4.LibraryFolder) {
            id = folder.id
            name = folder.name
            kind = folder.kind.rawValue
            bookmarkData = folder.bookmarkData
            sortIndex = folder.sortIndex
            createdAt = folder.createdAt
            assetIDs = Set(folder.assets.map(\.id))
        }

        init(_ folder: CatalogSchemaV1.LibraryFolder) {
            id = folder.id
            name = folder.name
            kind = folder.kind.rawValue
            bookmarkData = folder.bookmarkData
            sortIndex = folder.sortIndex
            createdAt = folder.createdAt
            assetIDs = Set(folder.assets.map(\.id))
        }

        init(_ folder: LibraryFolder) {
            id = folder.id
            name = folder.name
            kind = folder.kind.rawValue
            bookmarkData = folder.bookmarkData
            sortIndex = folder.sortIndex
            createdAt = folder.createdAt
            assetIDs = Set(folder.assets.map(\.id))
        }
    }

    private struct CollectionSnapshot: Equatable {
        let id: UUID
        let name: String
        let symbol: String
        let sortIndex: Int
        let createdAt: Date
        let assetIDs: Set<UUID>

        init(_ collection: CatalogSchemaV4.AssetCollection) {
            id = collection.id
            name = collection.name
            symbol = collection.symbol
            sortIndex = collection.sortIndex
            createdAt = collection.createdAt
            assetIDs = Set(collection.assets.map(\.id))
        }

        init(_ collection: CatalogSchemaV1.AssetCollection) {
            id = collection.id
            name = collection.name
            symbol = collection.symbol
            sortIndex = collection.sortIndex
            createdAt = collection.createdAt
            assetIDs = Set(collection.assets.map(\.id))
        }

        init(_ collection: AssetCollection) {
            id = collection.id
            name = collection.name
            symbol = collection.symbol
            sortIndex = collection.sortIndex
            createdAt = collection.createdAt
            assetIDs = Set(collection.assets.map(\.id))
        }
    }

    private struct CatalogSnapshot: Equatable {
        var assets: [UUID: AssetSnapshot]
        let folders: [UUID: FolderSnapshot]
        let collections: [UUID: CollectionSnapshot]

        mutating func rewriteManagedPaths(_ paths: [UUID: String]) throws {
            for (assetID, relativePath) in paths {
                guard var asset = assets[assetID], asset.storageMode == "managed" else {
                    throw MigrationError.validationFailed(
                        "managed-file migration references unknown asset \(assetID)"
                    )
                }
                asset.managedRelativePath = relativePath
                assets[assetID] = asset
            }
        }

        init(
            assets sourceAssets: [CatalogSchemaV4.ImageAsset],
            folders sourceFolders: [CatalogSchemaV4.LibraryFolder],
            collections sourceCollections: [CatalogSchemaV4.AssetCollection]
        ) throws {
            var assets: [UUID: AssetSnapshot] = [:]
            for source in sourceAssets {
                guard assets.updateValue(AssetSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.invalidSource("duplicate asset ID \(source.id)")
                }
            }

            var folders: [UUID: FolderSnapshot] = [:]
            for source in sourceFolders {
                guard folders.updateValue(FolderSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.invalidSource("duplicate folder ID \(source.id)")
                }
            }

            var collections: [UUID: CollectionSnapshot] = [:]
            for source in sourceCollections {
                guard collections.updateValue(CollectionSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.invalidSource("duplicate collection ID \(source.id)")
                }
            }

            self.assets = assets
            self.folders = folders
            self.collections = collections
        }

        init(
            assets sourceAssets: [CatalogSchemaV1.ImageAsset],
            folders sourceFolders: [CatalogSchemaV1.LibraryFolder],
            collections sourceCollections: [CatalogSchemaV1.AssetCollection]
        ) throws {
            var assets: [UUID: AssetSnapshot] = [:]
            for source in sourceAssets {
                guard assets.updateValue(AssetSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.invalidSource("duplicate asset ID \(source.id)")
                }
            }

            var folders: [UUID: FolderSnapshot] = [:]
            for source in sourceFolders {
                guard folders.updateValue(FolderSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.invalidSource("duplicate folder ID \(source.id)")
                }
            }

            var collections: [UUID: CollectionSnapshot] = [:]
            for source in sourceCollections {
                guard collections.updateValue(CollectionSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.invalidSource("duplicate collection ID \(source.id)")
                }
            }

            self.assets = assets
            self.folders = folders
            self.collections = collections
        }

        init(
            assets sourceAssets: [ImageAsset],
            folders sourceFolders: [LibraryFolder],
            collections sourceCollections: [AssetCollection]
        ) throws {
            var assets: [UUID: AssetSnapshot] = [:]
            for source in sourceAssets {
                guard assets.updateValue(AssetSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.validationFailed("duplicate migrated asset ID \(source.id)")
                }
                guard CatalogV4Migration.newControlsAreNeutral(source.develop) else {
                    throw MigrationError.validationFailed(
                        "new develop controls are not neutral for asset \(source.id)"
                    )
                }
            }

            var folders: [UUID: FolderSnapshot] = [:]
            for source in sourceFolders {
                guard folders.updateValue(FolderSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.validationFailed("duplicate migrated folder ID \(source.id)")
                }
            }

            var collections: [UUID: CollectionSnapshot] = [:]
            for source in sourceCollections {
                guard collections.updateValue(CollectionSnapshot(source), forKey: source.id) == nil else {
                    throw MigrationError.validationFailed(
                        "duplicate migrated collection ID \(source.id)"
                    )
                }
            }

            self.assets = assets
            self.folders = folders
            self.collections = collections
        }
    }

    /// Migrates an in-generation v4 catalog into a different generation while
    /// preserving the source generation byte-for-byte. Current stores are left
    /// at their existing immutable path.
    static func migrateStoreIfNeeded(
        _ preparation: LibraryLocations.CatalogPreparation
    ) throws -> MigrationResult {
        try LibraryLocations.requireGenerationLock(preparation)
        let storeURL = preparation.migrationSourceURL ?? preparation.catalogURL
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return MigrationResult(
                preparation: preparation,
                legacySourceIdentity: nil,
                sourceLease: nil
            )
        }

        guard try storeFormat(at: storeURL) != .current else {
            return MigrationResult(
                preparation: preparation,
                legacySourceIdentity: try pendingLegacyMigration(
                    at: storeURL,
                    generationID: preparation.generationID
                )?.sourceIdentity,
                sourceLease: nil
            )
        }
        let inheritedLegacyMigration = try pendingLegacyMigration(
            at: storeURL,
            generationID: preparation.generationID
        )
        let sourceLease = try SourceLease(at: storeURL)
        let target = try LibraryLocations.prepareMigrationTarget(
            from: preparation,
            sourceLease: sourceLease
        )
        if FileManager.default.fileExists(atPath: target.catalogURL.path),
           try storeFormat(at: target.catalogURL) == .current,
           try isValidatedInterruptedCurrentCatalog(
               at: target.catalogURL,
               generationID: target.generationID,
               sourceLease: sourceLease
           ) {
            return MigrationResult(
                preparation: target,
                legacySourceIdentity: try pendingLegacyMigration(
                    at: target.catalogURL,
                    generationID: target.generationID
                )?.sourceIdentity,
                sourceLease: sourceLease
            )
        }
        let sourceIdentity = try migrateV4Store(
            at: storeURL,
            into: target,
            sourceKind: inheritedLegacyMigration == nil ? .generation : .legacyDefault,
            markerSourceIdentity: inheritedLegacyMigration?.sourceIdentity,
            markerManagedFilesIdentity: inheritedLegacyMigration?.managedFilesIdentity,
            legacyLibraryRoot: nil,
            sourceLease: sourceLease
        )
        return MigrationResult(
            preparation: target,
            legacySourceIdentity: inheritedLegacyMigration?.sourceIdentity
                ?? (inheritedLegacyMigration == nil ? nil : sourceIdentity),
            sourceLease: sourceLease
        )
    }

    /// Imports the old default SwiftData store only when no generation catalog
    /// already exists. A valid active generation always has precedence.
    static func migrateLegacyStore(
        at sourceURL: URL,
        legacyLibraryRoot: URL?,
        into preparation: LibraryLocations.CatalogPreparation
    ) throws -> MigrationResult {
        try LibraryLocations.requireGenerationLock(preparation)
        guard try storeFormat(at: sourceURL) != .current else {
            throw MigrationError.invalidSource(
                "the default legacy store is not a supported released catalog"
            )
        }
        let sourceLease = try SourceLease(at: sourceURL)
        return try migrateLegacyStore(
            at: sourceURL,
            legacyLibraryRoot: legacyLibraryRoot,
            into: preparation,
            sourceLease: sourceLease
        )
    }

    static func migrateLegacyStore(
        at sourceURL: URL,
        legacyLibraryRoot: URL?,
        replacing preparation: LibraryLocations.CatalogPreparation
    ) throws -> MigrationResult {
        try LibraryLocations.requireGenerationLock(preparation)
        guard try storeFormat(at: sourceURL) != .current else {
            throw MigrationError.invalidSource(
                "the default legacy store is not a supported released catalog"
            )
        }
        let sourceLease = try SourceLease(at: sourceURL)
        let target = try LibraryLocations.prepareMigrationTarget(
            from: preparation,
            sourceLease: sourceLease,
            copiesSourceGenerationContent: !preparation.requiresLegacySourceRevalidation,
            abandonSourceOnCommit: preparation.requiresLegacySourceRevalidation
        )
        return try migrateLegacyStore(
            at: sourceURL,
            legacyLibraryRoot: legacyLibraryRoot,
            into: target,
            sourceLease: sourceLease
        )
    }

    private static func migrateLegacyStore(
        at sourceURL: URL,
        legacyLibraryRoot: URL?,
        into preparation: LibraryLocations.CatalogPreparation,
        sourceLease: SourceLease
    ) throws -> MigrationResult {
        if FileManager.default.fileExists(atPath: preparation.catalogURL.path) {
            guard try storeFormat(at: preparation.catalogURL) == .current,
                  try isValidatedInterruptedCurrentCatalog(
                    at: preparation.catalogURL,
                    generationID: preparation.generationID,
                    sourceLease: sourceLease
                  ),
                  let pending = try pendingLegacyMigration(
                    at: preparation.catalogURL,
                    generationID: preparation.generationID
                  )
            else {
                throw MigrationError.invalidSource(
                    "an active generation catalog already exists and was not replaced"
                )
            }
            return MigrationResult(
                preparation: preparation,
                legacySourceIdentity: pending.sourceIdentity,
                sourceLease: sourceLease
            )
        }
        let sourceIdentity = try migrateV4Store(
            at: sourceURL,
            into: preparation,
            sourceKind: .legacyDefault,
            markerSourceIdentity: nil,
            markerManagedFilesIdentity: nil,
            legacyLibraryRoot: legacyLibraryRoot,
            sourceLease: sourceLease
        )
        return MigrationResult(
            preparation: preparation,
            legacySourceIdentity: sourceIdentity,
            sourceLease: sourceLease
        )
    }

    /// Reads Core Data's model checksum through an immutable SQLite connection.
    /// This avoids both an incompatible SwiftData open and WAL-index writes.
    static func storeFormat(at url: URL) throws -> StoreFormat {
        try validateStoreFile(url)
        var database: OpaquePointer?
        let uri = try immutableSQLiteURI(for: url)
        let openResult = sqlite3_open_v2(
            uri,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(openResult))
            if let database { sqlite3_close(database) }
            throw MigrationError.invalidSource(
                "the catalog metadata could not be read at \(url.path): \(message)"
            )
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT Z_PLIST FROM Z_METADATA LIMIT 1",
            -1,
            &statement,
            nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw MigrationError.invalidSource(
                "the catalog metadata table is unavailable at \(url.path)"
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0)
        else {
            throw MigrationError.invalidSource(
                "the catalog metadata row is missing at \(url.path)"
            )
        }
        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        guard byteCount <= metadataMaximumByteCount else {
            throw MigrationError.invalidSource(
                "the catalog metadata exceeds the supported size at \(url.path)"
            )
        }
        let data = Data(bytes: bytes, count: byteCount)
        guard let metadata = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let checksum = metadata["NSStoreModelVersionChecksumKey"] as? String
        else {
            throw MigrationError.invalidSource(
                "the catalog model checksum is missing at \(url.path)"
            )
        }
        switch checksum {
        case currentModelChecksum:
            return .current
        case v1ModelChecksum:
            return .v1
        case v4ModelChecksum:
            return .v4
        default:
            throw MigrationError.invalidSource(
                "the catalog at \(url.path) uses an unsupported model checksum"
            )
        }
    }

    private static func immutableSQLiteURI(for url: URL) throws -> String {
        guard var components = URLComponents(
            url: url.standardizedFileURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw MigrationError.unsafeCatalog(url)
        }
        components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
        guard let uri = components.string else {
            throw MigrationError.unsafeCatalog(url)
        }
        return uri
    }

    static func probeStore(at url: URL) throws -> StoreProbe {
        switch try storeFormat(at: url) {
        case .current:
            return try probeCurrentStore(at: url)
        case .v1:
            return try probeV1Store(at: url)
        case .v4:
            return try probeV4Store(at: url)
        }
    }

    /// Restores only marker-bound migration artifacts. A staged current store
    /// is trusted only when it has the same migration identity as its v4 backup
    /// and validates as that backup's exact logical contents. Invalid backup
    /// directories are quarantined only after the canonical current catalog is
    /// independently known to be authoritative and staging is absent.
    static func recoverInterruptedMigration(
        in generationDirectory: URL,
        generationID: UUID,
        canonicalCurrentIsAuthoritative: Bool
    ) throws {
        let catalogDirectory = generationDirectory.appendingPathComponent(
            "Catalog",
            isDirectory: true
        )
        let canonicalStore = catalogDirectory.appendingPathComponent("catalog.store")
        let canonicalFormat = FileManager.default.fileExists(atPath: canonicalStore.path)
            ? try? storeFormat(at: canonicalStore)
            : nil
        let artifacts = try migrationArtifacts(
            in: generationDirectory,
            generationID: generationID
        )

        if canonicalFormat == .current {
            guard artifacts.staging.isEmpty else {
                throw MigrationError.interruptedMigration(
                    "a readable current catalog and a separate current staging catalog both exist"
                )
            }
            if let invalidBackup = artifacts.invalidBackups.first,
               !canonicalCurrentIsAuthoritative {
                throw MigrationError.interruptedMigration(invalidBackup.reason)
            }
            var quarantined = artifacts.invalidBackups
            if !artifacts.backups.isEmpty {
                var catalogMarker = try readMigrationMarker(in: catalogDirectory)
                if catalogMarker == nil && !canonicalCurrentIsAuthoritative {
                    guard artifacts.backups.count == 1,
                          let backup = artifacts.backups.values.first
                    else {
                        throw MigrationError.interruptedMigration(
                            "multiple retained backups cannot identify the current catalog"
                        )
                    }
                    try validateArtifactStore(
                        backup,
                        expectedFormat: try legacyFormat(for: backup.marker.sourceIdentity)
                    )
                    var expectedSnapshot = try snapshotLegacyStoreCopy(
                        at: backup.directory.appendingPathComponent("catalog.store")
                    )
                    if backup.marker.sourceKind == .legacyDefault {
                        guard let managedFilesIdentity = backup.marker.managedFilesIdentity else {
                            throw MigrationError.interruptedMigration(
                                "the retained legacy backup has no managed-file identity"
                            )
                        }
                        let managedFiles = try validateMigratedManagedFiles(
                            snapshot: expectedSnapshot,
                            in: generationDirectory,
                            expectedIdentity: managedFilesIdentity
                        )
                        try expectedSnapshot.rewriteManagedPaths(managedFiles.relativePaths)
                    }
                    try validateCurrentStore(at: canonicalStore, matches: expectedSnapshot)
                    try writeMigrationMarker(
                        in: catalogDirectory,
                        migrationID: backup.marker.migrationID,
                        generationID: backup.marker.generationID,
                        sourceIdentity: backup.marker.sourceIdentity,
                        legacySourceIdentity: backup.marker.legacySourceIdentity,
                        role: .currentStaging,
                        sourceKind: backup.marker.sourceKind,
                        managedFilesIdentity: backup.marker.managedFilesIdentity
                    )
                    catalogMarker = MigrationMarker(
                        schemaVersion: backup.marker.schemaVersion,
                        migrationID: backup.marker.migrationID,
                        generationID: backup.marker.generationID,
                        sourceIdentity: backup.marker.sourceIdentity,
                        legacySourceIdentity: backup.marker.legacySourceIdentity,
                        role: .currentStaging,
                        sourceKind: backup.marker.sourceKind,
                        managedFilesIdentity: backup.marker.managedFilesIdentity
                    )
                }

                for backup in artifacts.backups.values {
                    guard let catalogMarker,
                          markersMatch(backup.marker, catalogMarker)
                    else {
                        if canonicalCurrentIsAuthoritative {
                            quarantined.append((
                                backup.directory,
                                "the retained backup is not bound to the authoritative catalog"
                            ))
                            continue
                        }
                        throw MigrationError.interruptedMigration(
                            "a retained migration backup is not bound to the current catalog"
                        )
                    }
                    do {
                        try validateArtifactStore(
                            backup,
                            expectedFormat: try legacyFormat(
                                for: backup.marker.sourceIdentity
                            )
                        )
                    } catch {
                        guard canonicalCurrentIsAuthoritative else { throw error }
                        quarantined.append((
                            backup.directory,
                            "the retained backup is unreadable: \(errorDetails(error))"
                        ))
                    }
                }
            }
            if !quarantined.isEmpty {
                try recordArtifactQuarantine(
                    quarantined,
                    in: generationDirectory,
                    generationID: generationID
                )
            }
            return
        }

        if let invalidBackup = artifacts.invalidBackups.first {
            throw MigrationError.interruptedMigration(invalidBackup.reason)
        }

        try validateArtifactStores(artifacts)
        guard artifacts.backups.count <= 1,
              artifacts.staging.count <= 1
        else {
            throw MigrationError.interruptedMigration(
                "multiple marker-bound backup or staging candidates exist in \(generationDirectory.path)"
            )
        }
        guard let (migrationID, backup) = artifacts.backups.first else {
            if artifacts.staging.isEmpty { return }
            throw MigrationError.interruptedMigration(
                "a current-schema staging catalog exists without its legacy backup"
            )
        }
        let staged = artifacts.staging.first
        if let staged {
            guard staged.key == migrationID,
                  markersMatch(backup.marker, staged.value.marker)
            else {
                throw MigrationError.interruptedMigration(
                    "the staging catalog does not match the retained legacy backup"
                )
            }
        }
        // Old releases promoted this pair by renaming directories. A recovery
        // pass now only validates it; CatalogStore will copy its legacy source into
        // a new immutable generation instead.
    }

    static func recoverableV4Store(
        in generationDirectory: URL,
        generationID: UUID
    ) throws -> URL? {
        let canonicalStore = generationDirectory
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.store")
        if FileManager.default.fileExists(atPath: canonicalStore.path) {
            let format = try storeFormat(at: canonicalStore)
            if format.isLegacy { return canonicalStore }
        }

        let artifacts = try migrationArtifacts(
            in: generationDirectory,
            generationID: generationID
        )
        guard artifacts.invalidBackups.isEmpty,
              artifacts.backups.count <= 1,
              artifacts.staging.count <= 1
        else {
            throw MigrationError.interruptedMigration(
                "the retained migration source is ambiguous"
            )
        }
        guard let (migrationID, backup) = artifacts.backups.first else { return nil }
        if let staged = artifacts.staging.first {
            guard staged.key == migrationID,
                  markersMatch(backup.marker, staged.value.marker)
            else {
                throw MigrationError.interruptedMigration(
                    "the retained migration artifacts do not share an identity"
                )
            }
        }
        try validateArtifactStore(
            backup,
            expectedFormat: try legacyFormat(for: backup.marker.sourceIdentity)
        )
        return backup.directory.appendingPathComponent("catalog.store")
    }

    private static func migrationArtifacts(
        in generationDirectory: URL,
        generationID: UUID
    ) throws -> MigrationArtifacts {
        let entries = try FileManager.default.contentsOfDirectory(
            at: generationDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var artifacts = MigrationArtifacts()

        for entry in entries {
            let name = entry.lastPathComponent
            let prefix: String
            let role: MigrationMarker.Role
            if name.hasPrefix(backupDirectoryPrefix) {
                prefix = backupDirectoryPrefix
                role = .v4Backup
            } else if name.hasPrefix(stagingDirectoryPrefix) {
                prefix = stagingDirectoryPrefix
                role = .currentStaging
            } else {
                continue
            }

            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw MigrationError.interruptedMigration(
                    "candidate \(entry.path) is not a regular directory"
                )
            }
            let suffix = String(name.dropFirst(prefix.count))
            guard let migrationID = UUID(uuidString: suffix),
                  name == prefix + migrationID.uuidString
            else {
                if role == .v4Backup {
                    artifacts.invalidBackups.append((
                        entry,
                        "backup candidate \(entry.path) has an invalid migration identifier"
                    ))
                    continue
                }
                throw MigrationError.interruptedMigration(
                    "candidate \(entry.path) has an invalid migration identifier"
                )
            }
            let marker: MigrationMarker?
            do {
                marker = try readMigrationMarker(in: entry)
            } catch {
                if role == .v4Backup {
                    artifacts.invalidBackups.append((
                        entry,
                        "backup candidate \(entry.path) has invalid migration metadata: \(errorDetails(error))"
                    ))
                    continue
                }
                throw error
            }
            guard let marker else {
                continue
            }
            guard marker.schemaVersion == 1,
                  marker.migrationID == migrationID,
                  marker.generationID == generationID,
                  marker.role == role,
                  validSourceIdentity(marker.sourceIdentity),
                  validManagedFilesMetadata(marker)
            else {
                if role == .v4Backup {
                    artifacts.invalidBackups.append((
                        entry,
                        "backup candidate \(entry.path) has mismatched migration metadata"
                    ))
                    continue
                }
                throw MigrationError.interruptedMigration(
                    "candidate \(entry.path) has mismatched migration metadata"
                )
            }

            let artifact = MigrationArtifact(directory: entry, marker: marker)
            let previous: MigrationArtifact?
            if role == .v4Backup {
                previous = artifacts.backups.updateValue(artifact, forKey: migrationID)
            } else {
                previous = artifacts.staging.updateValue(artifact, forKey: migrationID)
            }
            guard previous == nil else {
                throw MigrationError.interruptedMigration(
                    "duplicate migration candidate \(migrationID.uuidString) exists"
                )
            }
        }
        return artifacts
    }

    private static func recordArtifactQuarantine(
        _ artifacts: [(directory: URL, reason: String)],
        in generationDirectory: URL,
        generationID: UUID
    ) throws {
        let canonicalGeneration = generationDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var entries: [ArtifactQuarantine.Entry] = []
        for artifact in artifacts {
            let values = try artifact.directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            let canonicalParent = artifact.directory
                .deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  canonicalParent.path == canonicalGeneration.path,
                  artifact.directory.lastPathComponent.hasPrefix(backupDirectoryPrefix)
            else {
                throw MigrationError.interruptedMigration(
                    "backup candidate \(artifact.directory.path) changed before quarantine"
                )
            }
            entries.append(.init(
                directoryName: artifact.directory.lastPathComponent,
                reason: artifact.reason
            ))
        }
        let payload = ArtifactQuarantine(
            schemaVersion: 1,
            generationID: generationID,
            entries: entries.sorted { $0.directoryName < $1.directoryName }
        )
        try JSONEncoder().encode(payload).write(
            to: generationDirectory.appendingPathComponent(artifactQuarantineName),
            options: [.atomic]
        )
    }

    private static func validateArtifactStores(_ artifacts: MigrationArtifacts) throws {
        for artifact in artifacts.backups.values {
            try validateArtifactStore(
                artifact,
                expectedFormat: try legacyFormat(for: artifact.marker.sourceIdentity)
            )
        }
        for artifact in artifacts.staging.values {
            try validateArtifactStore(artifact, expectedFormat: .current)
        }
    }

    private static func validateArtifactStore(
        _ artifact: MigrationArtifact,
        expectedFormat: StoreFormat
    ) throws {
        let storeURL = artifact.directory.appendingPathComponent("catalog.store")
        if artifact.marker.role == .v4Backup {
            let sidecarNames = Set([
                storeURL.lastPathComponent + "-journal",
                storeURL.lastPathComponent + "-shm",
                storeURL.lastPathComponent + "-wal",
            ])
            let entries = try FileManager.default.contentsOfDirectory(
                at: artifact.directory,
                includingPropertiesForKeys: nil
            )
            if let sidecar = entries.first(where: { sidecarNames.contains($0.lastPathComponent) }) {
                throw MigrationError.interruptedMigration(
                    "the retained backup has unexpected SQLite sidecar state at \(sidecar.path)"
                )
            }

            let format: StoreFormat
            do {
                format = try storeFormat(at: storeURL)
            } catch {
                throw MigrationError.interruptedMigration(
                    "marker-bound candidate \(artifact.directory.path) is unreadable: \(errorDetails(error))"
                )
            }
            guard format == expectedFormat else {
                throw MigrationError.interruptedMigration(
                    "candidate \(artifact.directory.path) has the wrong catalog schema"
                )
            }
            let identity = try sourceIdentity(at: storeURL)
            guard identity == artifact.marker.sourceIdentity else {
                throw MigrationError.interruptedMigration(
                    "the retained backup no longer matches its recorded identity"
                )
            }
            return
        }

        let probe: StoreProbe
        do {
            probe = try probeStore(at: storeURL)
        } catch {
            throw MigrationError.interruptedMigration(
                "marker-bound candidate \(artifact.directory.path) is unreadable: \(errorDetails(error))"
            )
        }
        guard probe.format == expectedFormat else {
            throw MigrationError.interruptedMigration(
                "candidate \(artifact.directory.path) has the wrong catalog schema"
            )
        }
    }

    private static func markersMatch(
        _ backup: MigrationMarker,
        _ staging: MigrationMarker
    ) -> Bool {
        return backup.schemaVersion == staging.schemaVersion
            && backup.migrationID == staging.migrationID
            && backup.generationID == staging.generationID
            && backup.sourceIdentity == staging.sourceIdentity
            && backup.legacySourceIdentity == staging.legacySourceIdentity
            && backup.sourceKind == staging.sourceKind
            && backup.managedFilesIdentity == staging.managedFilesIdentity
            && backup.role == .v4Backup
            && staging.role == .currentStaging
    }

    static func validSourceIdentity(_ identity: SourceIdentity) -> Bool {
        (identity.schemaVersion == 1 || identity.schemaVersion == 4)
            && identity.byteCount >= 0
            && identity.sha256.count == 64
            && identity.sha256.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }

    private static func legacyFormat(for identity: SourceIdentity) throws -> StoreFormat {
        switch identity.schemaVersion {
        case 1: return .v1
        case 4: return .v4
        default:
            throw MigrationError.interruptedMigration(
                "the retained backup uses an unsupported schema identity"
            )
        }
    }

    private static func validManagedFilesMetadata(_ marker: MigrationMarker) -> Bool {
        switch marker.sourceKind {
        case .generation:
            return marker.managedFilesIdentity == nil
                && marker.legacySourceIdentity == nil
        case .legacyDefault:
            guard let managedIdentity = marker.managedFilesIdentity,
                  let legacyIdentity = marker.legacySourceIdentity
            else { return false }
            return validManagedFilesIdentity(managedIdentity)
                && validSourceIdentity(legacyIdentity)
        }
    }

    static func isValidatedInterruptedCurrentCatalog(
        at storeURL: URL,
        generationID: UUID,
        sourceLease: SourceLease? = nil
    ) throws -> Bool {
        let catalogDirectory = storeURL.deletingLastPathComponent()
        guard let currentMarker = try readMigrationMarker(in: catalogDirectory),
              currentMarker.schemaVersion == 1,
              currentMarker.generationID == generationID,
              currentMarker.role == .currentStaging,
              validSourceIdentity(currentMarker.sourceIdentity),
              validManagedFilesMetadata(currentMarker)
        else { return false }

        let backupDirectory = catalogDirectory.deletingLastPathComponent().appendingPathComponent(
            backupDirectoryPrefix + currentMarker.migrationID.uuidString,
            isDirectory: true
        )
        guard let backupMarker = try readMigrationMarker(in: backupDirectory),
              backupMarker.schemaVersion == 1,
              backupMarker.migrationID == currentMarker.migrationID,
              backupMarker.generationID == generationID,
              backupMarker.sourceIdentity == currentMarker.sourceIdentity,
              backupMarker.legacySourceIdentity == currentMarker.legacySourceIdentity,
              backupMarker.sourceKind == currentMarker.sourceKind,
              backupMarker.managedFilesIdentity == currentMarker.managedFilesIdentity,
              backupMarker.role == .v4Backup
        else { return false }

        let backupStoreURL = backupDirectory.appendingPathComponent("catalog.store")
        guard try sourceIdentity(at: backupStoreURL) == backupMarker.sourceIdentity else {
            return false
        }
        if let sourceLease,
           try sourceIdentity(from: sourceLease) != backupMarker.sourceIdentity {
            return false
        }

        var expectedSnapshot = try snapshotLegacyStoreCopy(
            at: backupStoreURL
        )
        switch backupMarker.sourceKind {
        case .generation:
            guard backupMarker.managedFilesIdentity == nil else { return false }
        case .legacyDefault:
            guard let managedFilesIdentity = backupMarker.managedFilesIdentity else {
                return false
            }
            let managedFiles = try validateMigratedManagedFiles(
                snapshot: expectedSnapshot,
                in: catalogDirectory.deletingLastPathComponent(),
                expectedIdentity: managedFilesIdentity
            )
            try expectedSnapshot.rewriteManagedPaths(managedFiles.relativePaths)
        }
        try validateCurrentStore(at: storeURL, matches: expectedSnapshot)
        return true
    }

    private static func migrateV4Store(
        at sourceURL: URL,
        into preparation: LibraryLocations.CatalogPreparation,
        sourceKind: MigrationMarker.SourceKind,
        markerSourceIdentity: SourceIdentity?,
        markerManagedFilesIdentity: ManagedFilesIdentity?,
        legacyLibraryRoot: URL?,
        sourceLease: SourceLease
    ) throws -> SourceIdentity {
        try validateStoreFile(sourceURL)
        let fileManager = FileManager.default
        let migrationID = UUID()
        let generationDirectory = preparation.generationURL
        let catalogDirectory = preparation.catalogURL.deletingLastPathComponent()
        let backupDirectory = generationDirectory.appendingPathComponent(
            backupDirectoryPrefix + migrationID.uuidString,
            isDirectory: true
        )
        let backupStoreURL = backupDirectory.appendingPathComponent("catalog.store")
        guard !fileManager.fileExists(atPath: preparation.catalogURL.path) else {
            throw MigrationError.validationFailed(
                "the immutable migration destination already contains a catalog"
            )
        }

        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
        try sourceLease.backup(to: backupStoreURL)

        let snapshotIdentity = try sourceIdentity(at: backupStoreURL)
        let workingDirectory = try makeTemporaryWorkspaceDirectory(
            prefix: temporaryMigrationDirectoryPrefix
        )
        // SwiftData can retain SQLite descriptors after ModelContainer leaves
        // scope. The OS temporary directory may reclaim this disposable copy;
        // unlinking it here would invalidate Core Data's still-open vnode.
        let workingStoreURL = workingDirectory.appendingPathComponent("catalog.store")
        try fileManager.copyItem(at: backupStoreURL, to: workingStoreURL)

        let legacySourceIdentity = sourceKind == .legacyDefault
            ? markerSourceIdentity ?? snapshotIdentity
            : nil
        let sourceSnapshot: CatalogSnapshot
        do {
            sourceSnapshot = try autoreleasepool {
                try snapshotLegacyStore(at: workingStoreURL)
            }
        } catch {
            throw MigrationError.invalidSource(
                "the logical SQLite backup could not be opened with the released schema: \(errorDetails(error))"
            )
        }

        let managedFiles: ManagedFileMigration?
        if sourceKind == .legacyDefault {
            if let legacyLibraryRoot {
                managedFiles = try copyLegacyManagedFiles(
                    from: legacyLibraryRoot,
                    snapshot: sourceSnapshot,
                    into: generationDirectory
                )
            } else if let markerManagedFilesIdentity {
                managedFiles = try validateMigratedManagedFiles(
                    snapshot: sourceSnapshot,
                    in: generationDirectory,
                    expectedIdentity: markerManagedFilesIdentity
                )
            } else if sourceSnapshot.assets.values.contains(where: {
                $0.storageMode == StorageMode.managed.rawValue
            }) {
                throw MigrationError.invalidSource(
                    "the legacy managed-file root is unavailable"
                )
            } else {
                managedFiles = ManagedFileMigration(
                    relativePaths: [:],
                    identity: try managedFilesIdentity(for: [])
                )
            }
        } else {
            guard markerManagedFilesIdentity == nil else {
                throw MigrationError.invalidSource(
                    "an in-generation migration unexpectedly contains legacy managed-file metadata"
                )
            }
            managedFiles = nil
        }

        if let markerManagedFilesIdentity,
           markerManagedFilesIdentity != managedFiles?.identity {
            throw MigrationError.invalidSource(
                "the migrated managed files no longer match their recorded identity"
            )
        }
        var expectedSnapshot = sourceSnapshot
        try expectedSnapshot.rewriteManagedPaths(managedFiles?.relativePaths ?? [:])

        try writeMigrationMarker(
            in: backupDirectory,
            migrationID: migrationID,
            generationID: preparation.generationID,
            sourceIdentity: snapshotIdentity,
            legacySourceIdentity: legacySourceIdentity,
            role: .v4Backup,
            sourceKind: sourceKind,
            managedFilesIdentity: managedFiles?.identity
        )
        do {
            _ = try autoreleasepool {
                try copyLegacyStore(
                    at: workingStoreURL,
                    to: preparation.catalogURL,
                    managedRelativePaths: managedFiles?.relativePaths ?? [:]
                )
            }
            try validateCurrentStore(
                at: preparation.catalogURL,
                matches: expectedSnapshot
            )
        } catch {
            throw MigrationError.validationFailed(
                "the final current catalog could not be written or reopened: \(errorDetails(error))"
            )
        }
        try writeMigrationMarker(
            in: catalogDirectory,
            migrationID: migrationID,
            generationID: preparation.generationID,
            sourceIdentity: snapshotIdentity,
            legacySourceIdentity: legacySourceIdentity,
            role: .currentStaging,
            sourceKind: sourceKind,
            managedFilesIdentity: managedFiles?.identity
        )
        recordCatalogPromotion()
        return legacySourceIdentity ?? snapshotIdentity
    }

    private static func errorDetails(_ error: Error) -> String {
        let nsError = error as NSError
        guard !nsError.userInfo.isEmpty else { return String(reflecting: error) }
        return "\(String(reflecting: error)); \(nsError.userInfo)"
    }

    private static func recordCatalogPromotion() {
        let openHandleCount = SQLiteHandleTracker.openCount
        precondition(
            openHandleCount == 1,
            "Catalog promotion expected one coordinated source handle; found \(openHandleCount) migration SQLite handle(s)"
        )
        promotionObservationLock.lock()
        promotionObservationCount += 1
        promotionObservationLock.unlock()
    }

    private static func probeCurrentStore(at url: URL) throws -> StoreProbe {
        let container = try makeContainer(
            schema: CatalogStore.schema,
            url: url,
            allowsSave: false
        )
        let context = ModelContext(container)
        let assets = try context.fetch(FetchDescriptor<ImageAsset>())
        for asset in assets {
            _ = asset.develop.schemaVersion
        }
        return StoreProbe(
            format: .current,
            assetCount: assets.count,
            folderCount: try context.fetchCount(FetchDescriptor<LibraryFolder>()),
            collectionCount: try context.fetchCount(FetchDescriptor<AssetCollection>())
        )
    }

    private static func probeV1Store(at url: URL) throws -> StoreProbe {
        let container = try makeContainer(
            schema: CatalogSchemaV1.schema,
            url: url,
            allowsSave: false
        )
        let context = ModelContext(container)
        let assets = try context.fetch(FetchDescriptor<CatalogSchemaV1.ImageAsset>())
        for asset in assets {
            _ = asset.develop.schemaVersion
        }
        return StoreProbe(
            format: .v1,
            assetCount: assets.count,
            folderCount: try context.fetchCount(
                FetchDescriptor<CatalogSchemaV1.LibraryFolder>()
            ),
            collectionCount: try context.fetchCount(
                FetchDescriptor<CatalogSchemaV1.AssetCollection>()
            )
        )
    }

    private static func probeV4Store(at url: URL) throws -> StoreProbe {
        let container = try makeContainer(
            schema: CatalogSchemaV4.schema,
            url: url,
            allowsSave: false
        )
        let context = ModelContext(container)
        let assets = try context.fetch(FetchDescriptor<CatalogSchemaV4.ImageAsset>())
        for asset in assets {
            _ = asset.develop.schemaVersion
        }
        return StoreProbe(
            format: .v4,
            assetCount: assets.count,
            folderCount: try context.fetchCount(
                FetchDescriptor<CatalogSchemaV4.LibraryFolder>()
            ),
            collectionCount: try context.fetchCount(
                FetchDescriptor<CatalogSchemaV4.AssetCollection>()
            )
        )
    }

    private static func snapshotLegacyStore(at sourceURL: URL) throws -> CatalogSnapshot {
        switch try storeFormat(at: sourceURL) {
        case .v1:
            return try snapshotV1Store(at: sourceURL)
        case .v4:
            return try snapshotV4Store(at: sourceURL)
        case .current:
            throw MigrationError.invalidSource(
                "a current catalog cannot be read as a legacy migration source"
            )
        }
    }

    private static func snapshotLegacyStoreCopy(at sourceURL: URL) throws -> CatalogSnapshot {
        let fileManager = FileManager.default
        let directory = try makeTemporaryWorkspaceDirectory(
            prefix: temporaryRecoveryDirectoryPrefix
        )
        // Do not unlink a store that SwiftData may still have open. This copy
        // contains only catalog data and lives in the OS temporary directory.
        let copiedStore = directory.appendingPathComponent("catalog.store")
        try fileManager.copyItem(at: sourceURL, to: copiedStore)
        return try autoreleasepool {
            try snapshotLegacyStore(at: copiedStore)
        }
    }

    private static func copyLegacyStore(
        at sourceURL: URL,
        to destinationURL: URL,
        managedRelativePaths: [UUID: String]
    ) throws -> CatalogSnapshot {
        switch try storeFormat(at: sourceURL) {
        case .v1:
            return try copyV1Store(
                at: sourceURL,
                to: destinationURL,
                managedRelativePaths: managedRelativePaths
            )
        case .v4:
            return try copyV4Store(
                at: sourceURL,
                to: destinationURL,
                managedRelativePaths: managedRelativePaths
            )
        case .current:
            throw MigrationError.invalidSource(
                "a current catalog cannot be copied as a legacy migration source"
            )
        }
    }

    private static func snapshotV1Store(at sourceURL: URL) throws -> CatalogSnapshot {
        let sourceContainer = try makeContainer(
            schema: CatalogSchemaV1.schema,
            url: sourceURL,
            allowsSave: true
        )
        let sourceContext = ModelContext(sourceContainer)
        var assetDescriptor = FetchDescriptor<CatalogSchemaV1.ImageAsset>()
        assetDescriptor.relationshipKeyPathsForPrefetching = [\.folder, \.collections]
        var folderDescriptor = FetchDescriptor<CatalogSchemaV1.LibraryFolder>()
        folderDescriptor.relationshipKeyPathsForPrefetching = [\.assets]
        var collectionDescriptor = FetchDescriptor<CatalogSchemaV1.AssetCollection>()
        collectionDescriptor.relationshipKeyPathsForPrefetching = [\.assets]
        return try CatalogSnapshot(
            assets: sourceContext.fetch(assetDescriptor),
            folders: sourceContext.fetch(folderDescriptor),
            collections: sourceContext.fetch(collectionDescriptor)
        )
    }

    private static func snapshotV4Store(at sourceURL: URL) throws -> CatalogSnapshot {
        let sourceContainer = try makeContainer(
            schema: CatalogSchemaV4.schema,
            url: sourceURL,
            allowsSave: true
        )
        let sourceContext = ModelContext(sourceContainer)
        var assetDescriptor = FetchDescriptor<CatalogSchemaV4.ImageAsset>()
        assetDescriptor.relationshipKeyPathsForPrefetching = [\.folder, \.collections]
        var folderDescriptor = FetchDescriptor<CatalogSchemaV4.LibraryFolder>()
        folderDescriptor.relationshipKeyPathsForPrefetching = [\.assets]
        var collectionDescriptor = FetchDescriptor<CatalogSchemaV4.AssetCollection>()
        collectionDescriptor.relationshipKeyPathsForPrefetching = [\.assets]
        return try CatalogSnapshot(
            assets: sourceContext.fetch(assetDescriptor),
            folders: sourceContext.fetch(folderDescriptor),
            collections: sourceContext.fetch(collectionDescriptor)
        )
    }

    private static func copyV1Store(
        at sourceURL: URL,
        to destinationURL: URL,
        managedRelativePaths: [UUID: String]
    ) throws -> CatalogSnapshot {
        let sourceContainer = try makeContainer(
            schema: CatalogSchemaV1.schema,
            url: sourceURL,
            allowsSave: false
        )
        let sourceContext = ModelContext(sourceContainer)

        var assetDescriptor = FetchDescriptor<CatalogSchemaV1.ImageAsset>()
        assetDescriptor.relationshipKeyPathsForPrefetching = [\.folder, \.collections]
        var folderDescriptor = FetchDescriptor<CatalogSchemaV1.LibraryFolder>()
        folderDescriptor.relationshipKeyPathsForPrefetching = [\.assets]
        var collectionDescriptor = FetchDescriptor<CatalogSchemaV1.AssetCollection>()
        collectionDescriptor.relationshipKeyPathsForPrefetching = [\.assets]

        let sourceAssets = try sourceContext.fetch(assetDescriptor)
        let sourceFolders = try sourceContext.fetch(folderDescriptor)
        let sourceCollections = try sourceContext.fetch(collectionDescriptor)
        let snapshot = try CatalogSnapshot(
            assets: sourceAssets,
            folders: sourceFolders,
            collections: sourceCollections
        )

        let destinationContainer = try makeContainer(
            schema: CatalogStore.schema,
            url: destinationURL,
            allowsSave: true
        )
        let destinationContext = ModelContext(destinationContainer)
        destinationContext.autosaveEnabled = false

        var foldersByID: [UUID: LibraryFolder] = [:]
        for source in sourceFolders {
            guard let kind = FolderKind(rawValue: source.kind.rawValue) else {
                throw MigrationError.invalidSource(
                    "folder \(source.id) has unsupported kind \(source.kind.rawValue)"
                )
            }
            let destination = LibraryFolder(
                id: source.id,
                name: source.name,
                kind: kind,
                sortIndex: source.sortIndex,
                createdAt: source.createdAt
            )
            destination.bookmarkData = source.bookmarkData
            destinationContext.insert(destination)
            foldersByID[source.id] = destination
        }

        var collectionsByID: [UUID: AssetCollection] = [:]
        for source in sourceCollections {
            let destination = AssetCollection(
                id: source.id,
                name: source.name,
                symbol: source.symbol,
                sortIndex: source.sortIndex,
                createdAt: source.createdAt
            )
            destinationContext.insert(destination)
            collectionsByID[source.id] = destination
        }

        var assetsByID: [UUID: ImageAsset] = [:]
        for source in sourceAssets {
            guard let storageMode = StorageMode(rawValue: source.storageMode.rawValue) else {
                throw MigrationError.invalidSource(
                    "asset \(source.id) has unsupported storage mode \(source.storageMode.rawValue)"
                )
            }
            let destination = ImageAsset(
                id: source.id,
                originalFilename: source.originalFilename,
                storageMode: storageMode,
                fingerprint: ImageFingerprint(
                    filename: source.fingerprintFilename,
                    fileSizeBytes: source.fingerprintSize,
                    captureDate: source.fingerprintCaptureDate,
                    headerHash: source.fingerprintHeaderHash
                ),
                importedAt: source.importedAt,
                fileSizeBytes: source.fileSizeBytes
            )
            copyScalarValues(
                from: source,
                to: destination,
                managedRelativePath: managedRelativePaths[source.id]
            )
            destinationContext.insert(destination)
            assetsByID[source.id] = destination
        }

        for source in sourceAssets {
            guard let destination = assetsByID[source.id] else {
                throw MigrationError.invalidSource("missing copied asset \(source.id)")
            }
            if let sourceFolder = source.folder {
                guard let folder = foldersByID[sourceFolder.id] else {
                    throw MigrationError.invalidSource(
                        "asset \(source.id) references missing folder \(sourceFolder.id)"
                    )
                }
                destination.folder = folder
            }
            destination.collections = try source.collections.map { sourceCollection in
                guard let collection = collectionsByID[sourceCollection.id] else {
                    throw MigrationError.invalidSource(
                        "asset \(source.id) references missing collection \(sourceCollection.id)"
                    )
                }
                return collection
            }
        }

        try destinationContext.save()
        return snapshot
    }

    private static func copyV4Store(
        at sourceURL: URL,
        to destinationURL: URL,
        managedRelativePaths: [UUID: String] = [:]
    ) throws -> CatalogSnapshot {
        let sourceContainer = try makeContainer(
            schema: CatalogSchemaV4.schema,
            url: sourceURL,
            allowsSave: false
        )
        let sourceContext = ModelContext(sourceContainer)

        var assetDescriptor = FetchDescriptor<CatalogSchemaV4.ImageAsset>()
        assetDescriptor.relationshipKeyPathsForPrefetching = [\.folder, \.collections]
        var folderDescriptor = FetchDescriptor<CatalogSchemaV4.LibraryFolder>()
        folderDescriptor.relationshipKeyPathsForPrefetching = [\.assets]
        var collectionDescriptor = FetchDescriptor<CatalogSchemaV4.AssetCollection>()
        collectionDescriptor.relationshipKeyPathsForPrefetching = [\.assets]

        let sourceAssets = try sourceContext.fetch(assetDescriptor)
        let sourceFolders = try sourceContext.fetch(folderDescriptor)
        let sourceCollections = try sourceContext.fetch(collectionDescriptor)
        let snapshot = try CatalogSnapshot(
            assets: sourceAssets,
            folders: sourceFolders,
            collections: sourceCollections
        )

        let destinationContainer = try makeContainer(
            schema: CatalogStore.schema,
            url: destinationURL,
            allowsSave: true
        )
        let destinationContext = ModelContext(destinationContainer)
        destinationContext.autosaveEnabled = false

        var foldersByID: [UUID: LibraryFolder] = [:]
        for source in sourceFolders {
            guard let kind = FolderKind(rawValue: source.kind.rawValue) else {
                throw MigrationError.invalidSource(
                    "folder \(source.id) has unsupported kind \(source.kind.rawValue)"
                )
            }
            let destination = LibraryFolder(
                id: source.id,
                name: source.name,
                kind: kind,
                sortIndex: source.sortIndex,
                createdAt: source.createdAt
            )
            destination.bookmarkData = source.bookmarkData
            destinationContext.insert(destination)
            foldersByID[source.id] = destination
        }

        var collectionsByID: [UUID: AssetCollection] = [:]
        for source in sourceCollections {
            let destination = AssetCollection(
                id: source.id,
                name: source.name,
                symbol: source.symbol,
                sortIndex: source.sortIndex,
                createdAt: source.createdAt
            )
            destinationContext.insert(destination)
            collectionsByID[source.id] = destination
        }

        var assetsByID: [UUID: ImageAsset] = [:]
        for source in sourceAssets {
            guard let storageMode = StorageMode(rawValue: source.storageMode.rawValue) else {
                throw MigrationError.invalidSource(
                    "asset \(source.id) has unsupported storage mode \(source.storageMode.rawValue)"
                )
            }
            let destination = ImageAsset(
                id: source.id,
                originalFilename: source.originalFilename,
                storageMode: storageMode,
                fingerprint: ImageFingerprint(
                    filename: source.fingerprintFilename,
                    fileSizeBytes: source.fingerprintSize,
                    captureDate: source.fingerprintCaptureDate,
                    headerHash: source.fingerprintHeaderHash
                ),
                importedAt: source.importedAt,
                fileSizeBytes: source.fileSizeBytes
            )
            copyScalarValues(
                from: source,
                to: destination,
                managedRelativePath: managedRelativePaths[source.id]
            )
            destinationContext.insert(destination)
            assetsByID[source.id] = destination
        }

        for source in sourceAssets {
            guard let destination = assetsByID[source.id] else {
                throw MigrationError.invalidSource("missing copied asset \(source.id)")
            }
            if let sourceFolder = source.folder {
                guard let folder = foldersByID[sourceFolder.id] else {
                    throw MigrationError.invalidSource(
                        "asset \(source.id) references missing folder \(sourceFolder.id)"
                    )
                }
                destination.folder = folder
            }
            destination.collections = try source.collections.map { sourceCollection in
                guard let collection = collectionsByID[sourceCollection.id] else {
                    throw MigrationError.invalidSource(
                        "asset \(source.id) references missing collection \(sourceCollection.id)"
                    )
                }
                return collection
            }
        }

        try destinationContext.save()
        return snapshot
    }

    private static func copyScalarValues(
        from source: CatalogSchemaV1.ImageAsset,
        to destination: ImageAsset,
        managedRelativePath: String?
    ) {
        destination.managedRelativePath = managedRelativePath ?? source.managedRelativePath
        destination.bookmarkData = source.bookmarkData
        destination.isMissing = source.isMissing
        destination.fingerprintFilename = source.fingerprintFilename
        destination.fingerprintSize = source.fingerprintSize
        destination.fingerprintCaptureDate = source.fingerprintCaptureDate
        destination.fingerprintHeaderHash = source.fingerprintHeaderHash
        destination.contentDigest = nil
        destination.captureDate = source.captureDate
        destination.cameraMake = source.cameraMake
        destination.cameraModel = source.cameraModel
        destination.lensModel = source.lensModel
        destination.isoValue = source.isoValue
        destination.focalLength = source.focalLength
        destination.aperture = source.aperture
        destination.shutterSpeed = source.shutterSpeed
        destination.pixelWidth = source.pixelWidth
        destination.pixelHeight = source.pixelHeight
        destination.exifOrientation = source.exifOrientation
        destination.importedAt = source.importedAt
        destination.fileSizeBytes = source.fileSizeBytes
        destination.rating = source.rating
        destination.flagRaw = source.flagRaw
        destination.colorLabel = source.colorLabel
        destination.develop = migratedSettings(from: source.develop)
        destination.thumbnailFileName = source.thumbnailFileName
    }

    private static func copyScalarValues(
        from source: CatalogSchemaV4.ImageAsset,
        to destination: ImageAsset,
        managedRelativePath: String?
    ) {
        destination.managedRelativePath = managedRelativePath ?? source.managedRelativePath
        destination.bookmarkData = source.bookmarkData
        destination.isMissing = source.isMissing
        destination.fingerprintFilename = source.fingerprintFilename
        destination.fingerprintSize = source.fingerprintSize
        destination.fingerprintCaptureDate = source.fingerprintCaptureDate
        destination.fingerprintHeaderHash = source.fingerprintHeaderHash
        destination.contentDigest = source.contentDigest
        destination.captureDate = source.captureDate
        destination.cameraMake = source.cameraMake
        destination.cameraModel = source.cameraModel
        destination.lensModel = source.lensModel
        destination.isoValue = source.isoValue
        destination.focalLength = source.focalLength
        destination.aperture = source.aperture
        destination.shutterSpeed = source.shutterSpeed
        destination.pixelWidth = source.pixelWidth
        destination.pixelHeight = source.pixelHeight
        destination.exifOrientation = source.exifOrientation
        destination.importedAt = source.importedAt
        destination.fileSizeBytes = source.fileSizeBytes
        destination.rating = source.rating
        destination.flagRaw = source.flagRaw
        destination.colorLabel = source.colorLabel
        destination.develop = migratedSettings(from: source.develop)
        destination.thumbnailFileName = source.thumbnailFileName
    }

    private static func copyLegacyManagedFiles(
        from legacyLibraryRoot: URL,
        snapshot: CatalogSnapshot,
        into generationDirectory: URL
    ) throws -> ManagedFileMigration {
        let managedAssets = snapshot.assets.values
            .filter { $0.storageMode == StorageMode.managed.rawValue }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard !managedAssets.isEmpty else {
            return ManagedFileMigration(
                relativePaths: [:],
                identity: try managedFilesIdentity(for: [])
            )
        }

        let rootValues = try legacyLibraryRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw MigrationError.invalidSource(
                "the legacy managed-file root is not a regular directory: \(legacyLibraryRoot.path)"
            )
        }
        let canonicalRoot = legacyLibraryRoot.resolvingSymlinksInPath().standardizedFileURL
        let fileManager = FileManager.default

        var paths: [UUID: String] = [:]
        var entries: [ManagedFileManifestEntry] = []
        for asset in managedAssets {
            let source = try legacyManagedSource(
                for: asset,
                root: legacyLibraryRoot,
                canonicalRoot: canonicalRoot
            )
            let targetOriginal = generationDirectory.appendingPathComponent(source.relativePath)
            let targetDirectory = targetOriginal.deletingLastPathComponent()
            let targetExists = try itemExistsWithoutFollowingSymlinks(at: targetDirectory)

            if !targetExists {
                try fileManager.createDirectory(
                    at: targetDirectory,
                    withIntermediateDirectories: false
                )
                try fileManager.copyItem(at: source.originalURL, to: targetOriginal)
                if let sourceSidecar = source.sidecarURL {
                    try fileManager.copyItem(
                        at: sourceSidecar,
                        to: targetOriginal.appendingPathExtension(
                            SidecarService.fileExtension
                        )
                    )
                }

                let copiedEntry = try managedFileManifestEntry(
                    for: asset,
                    originalURL: targetOriginal,
                    relativePath: source.relativePath,
                    expectedSidecarPresence: source.sidecarURL != nil
                )
                try requireSameManagedBytes(copiedEntry, source: source, assetID: asset.id)
                guard try source.originalFile.stillMatchesFile(at: source.originalURL),
                      try source.sidecarFile?.stillMatchesFile(
                        at: source.sidecarURL ?? source.originalURL
                      ) ?? true
                else {
                    throw MigrationError.invalidSource(
                        "managed bytes changed while asset \(asset.id) was copied"
                    )
                }
            }

            let finalEntry = try managedFileManifestEntry(
                for: asset,
                originalURL: targetOriginal,
                relativePath: source.relativePath,
                expectedSidecarPresence: source.sidecarURL != nil
            )
            try requireSameManagedBytes(finalEntry, source: source, assetID: asset.id)
            guard try source.originalFile.stillMatchesFile(at: source.originalURL),
                  try source.sidecarFile?.stillMatchesFile(
                    at: source.sidecarURL ?? source.originalURL
                  ) ?? true
            else {
                throw MigrationError.invalidSource(
                    "managed bytes changed while asset \(asset.id) was verified"
                )
            }
            paths[asset.id] = source.relativePath
            entries.append(finalEntry)
        }
        return ManagedFileMigration(
            relativePaths: paths,
            identity: try managedFilesIdentity(for: entries)
        )
    }

    private static func validateMigratedManagedFiles(
        snapshot: CatalogSnapshot,
        in generationDirectory: URL,
        expectedIdentity: ManagedFilesIdentity
    ) throws -> ManagedFileMigration {
        guard validManagedFilesIdentity(expectedIdentity) else {
            throw MigrationError.interruptedMigration(
                "the managed-file manifest identity is invalid"
            )
        }
        let managedAssets = snapshot.assets.values
            .filter { $0.storageMode == StorageMode.managed.rawValue }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var paths: [UUID: String] = [:]
        var entries: [ManagedFileManifestEntry] = []
        for asset in managedAssets {
            let relativePath = migratedManagedRelativePath(for: asset)
            let originalURL = generationDirectory.appendingPathComponent(relativePath)
            entries.append(try managedFileManifestEntry(
                for: asset,
                originalURL: originalURL,
                relativePath: relativePath,
                expectedSidecarPresence: nil
            ))
            paths[asset.id] = relativePath
        }
        let actualIdentity = try managedFilesIdentity(for: entries)
        guard actualIdentity == expectedIdentity else {
            throw MigrationError.interruptedMigration(
                "the migrated managed files do not match their recorded identity"
            )
        }
        return ManagedFileMigration(relativePaths: paths, identity: actualIdentity)
    }

    private static func legacyManagedSource(
        for asset: AssetSnapshot,
        root: URL,
        canonicalRoot: URL
    ) throws -> LegacyManagedSource {
        guard let legacyRelativePath = asset.managedRelativePath else {
            throw MigrationError.invalidSource(
                "managed asset \(asset.id) has no legacy relative path"
            )
        }
        let sourceURL = try validatedLegacyURL(
            relativePath: legacyRelativePath,
            root: root,
            canonicalRoot: canonicalRoot
        )
        let originalFile: ContentDigest.PinnedRegularFile
        do {
            originalFile = try ContentDigest.openPinnedRegularFile(at: sourceURL)
        } catch {
            throw MigrationError.invalidSource(
                "managed original for asset \(asset.id) is missing or unsafe: \(errorDetails(error))"
            )
        }
        let originalByteCount = try regularFileByteCount(at: sourceURL)
        let originalSHA256 = try originalFile.sha256()
        guard try originalFile.stillMatchesFile(at: sourceURL) else {
            throw MigrationError.invalidSource(
                "managed original for asset \(asset.id) changed while it was validated"
            )
        }
        guard originalByteCount == asset.fileSizeBytes,
              originalByteCount == asset.fingerprintSize
        else {
            throw MigrationError.invalidSource(
                "managed original metadata does not match asset \(asset.id)"
            )
        }
        if let contentDigest = asset.contentDigest,
           contentDigest != originalSHA256 {
            throw MigrationError.invalidSource(
                "managed original digest does not match asset \(asset.id)"
            )
        }

        let sidecarRelativePath = legacyRelativePath + "." + SidecarService.fileExtension
        let sidecarCandidate = try validatedLegacyURL(
            relativePath: sidecarRelativePath,
            root: root,
            canonicalRoot: canonicalRoot
        )
        let sidecarURL: URL?
        let sidecarFile: ContentDigest.PinnedRegularFile?
        let sidecarByteCount: Int64?
        let sidecarSHA256: String?
        if try itemExistsWithoutFollowingSymlinks(at: sidecarCandidate) {
            let pinned: ContentDigest.PinnedRegularFile
            do {
                pinned = try ContentDigest.openPinnedRegularFile(at: sidecarCandidate)
            } catch {
                throw MigrationError.invalidSource(
                    "sidecar for managed asset \(asset.id) is unsafe: \(errorDetails(error))"
                )
            }
            let byteCount = try regularFileByteCount(at: sidecarCandidate)
            guard byteCount <= legacySidecarMaximumByteCount,
                  let sidecar = try SidecarService.read(at: sidecarCandidate),
                  legacySidecar(sidecar, matches: asset)
            else {
                throw MigrationError.invalidSource(
                    "sidecar metadata does not match managed asset \(asset.id)"
                )
            }
            let digest = try pinned.sha256()
            guard try pinned.stillMatchesFile(at: sidecarCandidate) else {
                throw MigrationError.invalidSource(
                    "sidecar for managed asset \(asset.id) changed while it was validated"
                )
            }
            sidecarURL = sidecarCandidate
            sidecarFile = pinned
            sidecarByteCount = byteCount
            sidecarSHA256 = digest
        } else {
            sidecarURL = nil
            sidecarFile = nil
            sidecarByteCount = nil
            sidecarSHA256 = nil
        }

        return LegacyManagedSource(
            originalURL: sourceURL,
            sidecarURL: sidecarURL,
            originalFile: originalFile,
            sidecarFile: sidecarFile,
            relativePath: migratedManagedRelativePath(for: asset),
            originalByteCount: originalByteCount,
            originalSHA256: originalSHA256,
            sidecarByteCount: sidecarByteCount,
            sidecarSHA256: sidecarSHA256
        )
    }

    private static func managedFileManifestEntry(
        for asset: AssetSnapshot,
        originalURL: URL,
        relativePath: String,
        expectedSidecarPresence: Bool?
    ) throws -> ManagedFileManifestEntry {
        let directory = originalURL.deletingLastPathComponent()
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw MigrationError.validationFailed(
                "the migrated managed directory is unsafe for asset \(asset.id)"
            )
        }
        let originalFile = try ContentDigest.openPinnedRegularFile(at: originalURL)
        let originalByteCount = try regularFileByteCount(at: originalURL)
        let originalSHA256 = try originalFile.sha256()
        guard try originalFile.stillMatchesFile(at: originalURL),
              originalByteCount == asset.fileSizeBytes,
              originalByteCount == asset.fingerprintSize,
              asset.contentDigest == nil || asset.contentDigest == originalSHA256
        else {
            throw MigrationError.validationFailed(
                "migrated managed bytes or metadata differ for asset \(asset.id)"
            )
        }

        let sidecarURL = originalURL.appendingPathExtension(SidecarService.fileExtension)
        let hasSidecar = try itemExistsWithoutFollowingSymlinks(at: sidecarURL)
        if let expectedSidecarPresence, expectedSidecarPresence != hasSidecar {
            throw MigrationError.validationFailed(
                "the migrated sidecar presence differs for asset \(asset.id)"
            )
        }
        let sidecarByteCount: Int64?
        let sidecarSHA256: String?
        if hasSidecar {
            let sidecarFile = try ContentDigest.openPinnedRegularFile(at: sidecarURL)
            let byteCount = try regularFileByteCount(at: sidecarURL)
            guard byteCount <= legacySidecarMaximumByteCount,
                  let sidecar = try SidecarService.read(at: sidecarURL),
                  legacySidecar(sidecar, matches: asset)
            else {
                throw MigrationError.validationFailed(
                    "migrated sidecar metadata differs for asset \(asset.id)"
                )
            }
            sidecarByteCount = byteCount
            sidecarSHA256 = try sidecarFile.sha256()
            guard try sidecarFile.stillMatchesFile(at: sidecarURL) else {
                throw MigrationError.validationFailed(
                    "migrated sidecar changed while asset \(asset.id) was validated"
                )
            }
        } else {
            sidecarByteCount = nil
            sidecarSHA256 = nil
        }

        let expectedNames: Set<String> = hasSidecar
            ? [originalURL.lastPathComponent, sidecarURL.lastPathComponent]
            : [originalURL.lastPathComponent]
        let actualNames = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        guard actualNames == expectedNames else {
            throw MigrationError.validationFailed(
                "the migrated managed directory contains unexpected files for asset \(asset.id)"
            )
        }
        return ManagedFileManifestEntry(
            assetID: asset.id,
            relativePath: relativePath,
            originalByteCount: originalByteCount,
            originalSHA256: originalSHA256,
            sidecarByteCount: sidecarByteCount,
            sidecarSHA256: sidecarSHA256
        )
    }

    private static func requireSameManagedBytes(
        _ entry: ManagedFileManifestEntry,
        source: LegacyManagedSource,
        assetID: UUID
    ) throws {
        guard entry.originalByteCount == source.originalByteCount,
              entry.originalSHA256 == source.originalSHA256,
              entry.sidecarByteCount == source.sidecarByteCount,
              entry.sidecarSHA256 == source.sidecarSHA256
        else {
            throw MigrationError.validationFailed(
                "copied managed bytes differ for asset \(assetID)"
            )
        }
    }

    private static func legacySidecar(
        _ sidecar: Sidecar,
        matches asset: AssetSnapshot
    ) -> Bool {
        sidecar.fingerprint.filename == asset.fingerprintFilename
            && sidecar.fingerprint.fileSizeBytes == asset.fingerprintSize
            && sidecar.fingerprint.captureDate == asset.fingerprintCaptureDate
            && sidecar.fingerprint.headerHash == asset.fingerprintHeaderHash
            && (asset.contentDigest == nil
                || sidecar.sourceContentDigest == nil
                || sidecar.sourceContentDigest == asset.contentDigest)
    }

    private static func managedFilesIdentity(
        for entries: [ManagedFileManifestEntry]
    ) throws -> ManagedFilesIdentity {
        let sorted = entries.sorted { $0.assetID.uuidString < $1.assetID.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sorted)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ManagedFilesIdentity(managedAssetCount: entries.count, sha256: hash)
    }

    private static func migratedManagedRelativePath(for asset: AssetSnapshot) -> String {
        let legacyExtension = asset.managedRelativePath
            .map { URL(fileURLWithPath: $0).pathExtension }
            ?? ""
        let fileExtension = legacyExtension.isEmpty
            ? URL(fileURLWithPath: asset.originalFilename).pathExtension
            : legacyExtension
        let filename = fileExtension.isEmpty
            ? "primary"
            : "primary.\(fileExtension.lowercased())"
        return "Originals/\(asset.id.uuidString)/\(filename)"
    }

    private static func validatedLegacyURL(
        relativePath: String,
        root: URL,
        canonicalRoot: URL
    ) throws -> URL {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw MigrationError.invalidSource(
                "legacy managed path is unsafe: \(relativePath)"
            )
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let expected = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == expected.path,
              resolved.path.hasPrefix(canonicalRoot.path + "/")
        else {
            throw MigrationError.invalidSource(
                "legacy managed path escapes its library root: \(relativePath)"
            )
        }
        return candidate
    }

    private static func regularFileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw MigrationError.invalidSource("file is not regular: \(url.path)")
        }
        return Int64(size)
    }

    private static func itemExistsWithoutFollowingSymlinks(at url: URL) throws -> Bool {
        var status = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                errno = EINVAL
                return -1
            }
            return lstat(path, &status)
        }
        if result == 0 { return true }
        let code = errno
        if code == ENOENT || code == ENOTDIR { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func validManagedFilesIdentity(_ identity: ManagedFilesIdentity) -> Bool {
        identity.managedAssetCount >= 0
            && identity.sha256.count == 64
            && identity.sha256.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
    }

    private static func migratedSettings(
        from source: CatalogSchemaV1.DevelopSettings
    ) -> DevelopSettings {
        var destination = DevelopSettings()
        destination.temperature = source.temperature
        destination.tint = source.tint
        destination.exposure = source.exposure
        destination.contrast = source.contrast
        destination.highlights = source.highlights
        destination.shadows = source.shadows
        destination.whites = source.whites
        destination.blacks = source.blacks
        destination.vibrance = source.vibrance
        destination.saturation = source.saturation
        destination.sharpness = source.sharpness
        destination.noiseReduction = source.noiseReduction
        destination.rotationQuarterTurns = source.rotationQuarterTurns
        return destination
    }

    private static func migratedSettings(
        from source: CatalogSchemaV4.DevelopSettings
    ) -> DevelopSettings {
        var destination = DevelopSettings()
        destination.temperature = source.temperature
        destination.tint = source.tint
        destination.exposure = source.exposure
        destination.contrast = source.contrast
        destination.highlights = source.highlights
        destination.shadows = source.shadows
        destination.whites = source.whites
        destination.blacks = source.blacks
        destination.texture = source.texture
        destination.clarity = source.clarity
        destination.dehaze = source.dehaze
        destination.vibrance = source.vibrance
        destination.saturation = source.saturation
        destination.toneCurve = source.toneCurve.map { CurvePoint($0.x, $0.y) }
        destination.toneCurveRed = source.toneCurveRed.map { CurvePoint($0.x, $0.y) }
        destination.toneCurveGreen = source.toneCurveGreen.map { CurvePoint($0.x, $0.y) }
        destination.toneCurveBlue = source.toneCurveBlue.map { CurvePoint($0.x, $0.y) }
        destination.colorMix.hue = source.colorMix.hue
        destination.colorMix.saturation = source.colorMix.saturation
        destination.colorMix.luminance = source.colorMix.luminance
        destination.grade.shadowHue = source.grade.shadowHue
        destination.grade.shadowSat = source.grade.shadowSat
        destination.grade.midHue = source.grade.midHue
        destination.grade.midSat = source.grade.midSat
        destination.grade.highHue = source.grade.highHue
        destination.grade.highSat = source.grade.highSat
        destination.blackWhite = source.blackWhite
        destination.bwRed = source.bwRed
        destination.bwGreen = source.bwGreen
        destination.bwBlue = source.bwBlue
        destination.sharpness = source.sharpness
        destination.sharpenRadius = source.sharpenRadius
        destination.noiseReduction = source.noiseReduction
        destination.colorNoiseReduction = source.colorNoiseReduction
        destination.grain = source.grain
        destination.vignette = source.vignette
        destination.cropX = source.cropX
        destination.cropY = source.cropY
        destination.cropW = source.cropW
        destination.cropH = source.cropH
        destination.straighten = source.straighten
        destination.flipH = source.flipH
        destination.flipV = source.flipV
        destination.rotationQuarterTurns = source.rotationQuarterTurns
        return destination
    }

    private static func validateCurrentStore(
        at url: URL,
        matches sourceSnapshot: CatalogSnapshot
    ) throws {
        let container = try makeContainer(
            schema: CatalogStore.schema,
            url: url,
            allowsSave: false
        )
        let context = ModelContext(container)

        var assetDescriptor = FetchDescriptor<ImageAsset>()
        assetDescriptor.relationshipKeyPathsForPrefetching = [\.folder, \.collections]
        var folderDescriptor = FetchDescriptor<LibraryFolder>()
        folderDescriptor.relationshipKeyPathsForPrefetching = [\.assets]
        var collectionDescriptor = FetchDescriptor<AssetCollection>()
        collectionDescriptor.relationshipKeyPathsForPrefetching = [\.assets]

        let destinationSnapshot = try CatalogSnapshot(
            assets: context.fetch(assetDescriptor),
            folders: context.fetch(folderDescriptor),
            collections: context.fetch(collectionDescriptor)
        )
        guard destinationSnapshot == sourceSnapshot else {
            throw MigrationError.validationFailed(
                "assets, folders, collections, metadata, settings, or relationships differ"
            )
        }
    }

    private static func newControlsAreNeutral(_ settings: DevelopSettings) -> Bool {
        let defaults = DevelopSettings()
        return settings.schemaVersion == DevelopSettings.currentSchemaVersion
            && settings.profileAmount == defaults.profileAmount
            && settings.curveHighlights == defaults.curveHighlights
            && settings.curveLights == defaults.curveLights
            && settings.curveDarks == defaults.curveDarks
            && settings.curveShadows == defaults.curveShadows
            && settings.curveSplitShadows == defaults.curveSplitShadows
            && settings.curveSplitMid == defaults.curveSplitMid
            && settings.curveSplitHighlights == defaults.curveSplitHighlights
            && settings.curveRefineSaturation == defaults.curveRefineSaturation
            && settings.grade.shadowLum == defaults.grade.shadowLum
            && settings.grade.midLum == defaults.grade.midLum
            && settings.grade.highLum == defaults.grade.highLum
            && settings.grade.globalHue == defaults.grade.globalHue
            && settings.grade.globalSat == defaults.grade.globalSat
            && settings.grade.globalLum == defaults.grade.globalLum
            && settings.grade.blending == defaults.grade.blending
            && settings.grade.balance == defaults.grade.balance
            && settings.pointColors.isEmpty
            && settings.masks.isEmpty
            && settings.spots.isEmpty
            && settings.redEyes.isEmpty
            && settings.bwOrange == defaults.bwOrange
            && settings.bwYellow == defaults.bwYellow
            && settings.bwAqua == defaults.bwAqua
            && settings.bwPurple == defaults.bwPurple
            && settings.bwMagenta == defaults.bwMagenta
            && settings.sharpenDetail == defaults.sharpenDetail
            && settings.sharpenMasking == defaults.sharpenMasking
            && settings.noiseReductionDetail == defaults.noiseReductionDetail
            && settings.noiseReductionContrast == defaults.noiseReductionContrast
            && settings.colorNoiseReductionDetail == defaults.colorNoiseReductionDetail
            && settings.colorNoiseReductionSmoothness == defaults.colorNoiseReductionSmoothness
            && settings.grainSize == defaults.grainSize
            && settings.grainRoughness == defaults.grainRoughness
            && settings.vignetteMidpoint == defaults.vignetteMidpoint
            && settings.vignetteRoundness == defaults.vignetteRoundness
            && settings.vignetteFeather == defaults.vignetteFeather
            && settings.vignetteHighlights == defaults.vignetteHighlights
            && settings.opticsDistortion == defaults.opticsDistortion
            && settings.opticsVignetting == defaults.opticsVignetting
            && settings.opticsVignettingMidpoint == defaults.opticsVignettingMidpoint
            && settings.opticsProfileDistortion == defaults.opticsProfileDistortion
            && settings.opticsProfileVignetting == defaults.opticsProfileVignetting
            && settings.opticsDefringePurple == defaults.opticsDefringePurple
            && settings.opticsDefringePurpleHueLo == defaults.opticsDefringePurpleHueLo
            && settings.opticsDefringePurpleHueHi == defaults.opticsDefringePurpleHueHi
            && settings.opticsDefringeGreen == defaults.opticsDefringeGreen
            && settings.opticsDefringeGreenHueLo == defaults.opticsDefringeGreenHueLo
            && settings.opticsDefringeGreenHueHi == defaults.opticsDefringeGreenHueHi
            && settings.opticsCARed == defaults.opticsCARed
            && settings.opticsCABlue == defaults.opticsCABlue
            && settings.geometryVertical == defaults.geometryVertical
            && settings.geometryHorizontal == defaults.geometryHorizontal
            && settings.geometryAspect == defaults.geometryAspect
            && settings.geometryScale == defaults.geometryScale
            && settings.geometryOffsetX == defaults.geometryOffsetX
            && settings.geometryOffsetY == defaults.geometryOffsetY
            && settings.calibrationShadowsTint == defaults.calibrationShadowsTint
            && settings.calibrationRedHue == defaults.calibrationRedHue
            && settings.calibrationRedSat == defaults.calibrationRedSat
            && settings.calibrationGreenHue == defaults.calibrationGreenHue
            && settings.calibrationGreenSat == defaults.calibrationGreenSat
            && settings.calibrationBlueHue == defaults.calibrationBlueHue
            && settings.calibrationBlueSat == defaults.calibrationBlueSat
    }

    private static func writeMigrationMarker(
        in directory: URL,
        migrationID: UUID,
        generationID: UUID,
        sourceIdentity: SourceIdentity,
        legacySourceIdentity: SourceIdentity?,
        role: MigrationMarker.Role,
        sourceKind: MigrationMarker.SourceKind,
        managedFilesIdentity: ManagedFilesIdentity?
    ) throws {
        let marker = MigrationMarker(
            schemaVersion: 1,
            migrationID: migrationID,
            generationID: generationID,
            sourceIdentity: sourceIdentity,
            legacySourceIdentity: legacySourceIdentity,
            role: role,
            sourceKind: sourceKind,
            managedFilesIdentity: managedFilesIdentity
        )
        try JSONEncoder().encode(marker).write(
            to: directory.appendingPathComponent(migrationMarkerName),
            options: [.atomic]
        )
    }

    private static func pendingLegacyMigration(
        at storeURL: URL,
        generationID: UUID
    ) throws -> PendingLegacyMigration? {
        let directory = storeURL.deletingLastPathComponent()
        guard let marker = try readMigrationMarker(in: directory),
              marker.schemaVersion == 1,
              marker.generationID == generationID,
              (marker.role == .currentStaging || marker.role == .v4Backup),
              validSourceIdentity(marker.sourceIdentity)
        else { return nil }
        switch marker.sourceKind {
        case .generation:
            guard marker.managedFilesIdentity == nil else {
                throw MigrationError.interruptedMigration(
                    "an in-generation current catalog contains legacy managed-file metadata"
                )
            }
            return nil
        case .legacyDefault:
            guard let managedFilesIdentity = marker.managedFilesIdentity,
                  validManagedFilesIdentity(managedFilesIdentity),
                  let legacySourceIdentity = marker.legacySourceIdentity,
                  validSourceIdentity(legacySourceIdentity)
            else {
                throw MigrationError.interruptedMigration(
                    "the current catalog's legacy managed-file identity is invalid"
                )
            }
            return PendingLegacyMigration(
                sourceIdentity: legacySourceIdentity,
                managedFilesIdentity: managedFilesIdentity
            )
        }
    }

    private static func readMigrationMarker(in directory: URL) throws -> MigrationMarker? {
        let markerURL = directory.appendingPathComponent(migrationMarkerName)
        let data: Data?
        do {
            data = try BoundedFileReader.readRegularFile(
                at: markerURL,
                maximumByteCount: metadataMaximumByteCount
            )
        } catch {
            if BoundedFileReader.isMissingFile(error) { return nil }
            throw MigrationError.unsafeCatalog(markerURL)
        }
        guard let data else { throw MigrationError.unsafeCatalog(markerURL) }
        do {
            return try JSONDecoder().decode(MigrationMarker.self, from: data)
        } catch {
            throw MigrationError.interruptedMigration(
                "migration marker \(markerURL.path) is invalid: \(errorDetails(error))"
            )
        }
    }

    private static func sourceIdentity(at url: URL) throws -> SourceIdentity {
        let format = try storeFormat(at: url)
        guard format.isLegacy else {
            throw MigrationError.invalidSource(
                "a current catalog cannot be used as a legacy migration source"
            )
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let byteCount = (attributes[.size] as? NSNumber)?.int64Value else {
            throw MigrationError.sqliteSnapshotFailed(
                url,
                "the snapshot size is unavailable"
            )
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return SourceIdentity(
            schemaVersion: format.schemaVersion,
            sha256: hash,
            byteCount: byteCount
        )
    }

    private static func sourceIdentity(from sourceLease: SourceLease) throws -> SourceIdentity {
        let directory = try makeTemporaryWorkspaceDirectory(
            prefix: temporaryRecoveryDirectoryPrefix
        )
        let snapshot = directory.appendingPathComponent("catalog.store")
        try sourceLease.backup(to: snapshot)
        return try sourceIdentity(at: snapshot)
    }

    private static func makeContainer(
        schema: Schema,
        url: URL,
        allowsSave: Bool
    ) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            url: url,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func validateStoreFile(_ storeURL: URL) throws {
        let directory = storeURL.deletingLastPathComponent()
        let storeValues = try storeURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard storeValues.isRegularFile == true,
              storeValues.isSymbolicLink != true,
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true
        else {
            throw MigrationError.unsafeCatalog(storeURL)
        }
    }

    /// SQLite's online backup API copies one committed database snapshot and
    /// folds committed WAL pages into the standalone destination. The exclusive
    /// transaction is retained by the catalog session so an older process cannot
    /// write to the source generation after its snapshot has been published.
    private final class ExclusiveSQLiteSource {
        private let sourceURL: URL
        private var database: OpaquePointer?
        private var transactionStarted = false

        init(at sourceURL: URL) throws {
            self.sourceURL = sourceURL
            var opened: OpaquePointer?
            let result = sqlite3_open_v2(
                sourceURL.path,
                &opened,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard result == SQLITE_OK, let opened else {
                let message = Self.message(from: opened, fallbackCode: result)
                if let opened { sqlite3_close(opened) }
                throw MigrationError.sqliteSnapshotFailed(sourceURL, message)
            }
            database = opened
            SQLiteHandleTracker.opened()
            sqlite3_busy_timeout(opened, 0)

            do {
                let mode = try querySingleText("PRAGMA locking_mode=EXCLUSIVE")
                guard mode.lowercased() == "exclusive" else {
                    throw MigrationError.sourceInUse(
                        sourceURL,
                        "exclusive locking mode was not granted"
                    )
                }
                try execute("BEGIN EXCLUSIVE")
                transactionStarted = true
                try execute("ROLLBACK")
                transactionStarted = false
                try execute("BEGIN")
                transactionStarted = true
                _ = try querySingleText("SELECT count(*) FROM sqlite_master")
            } catch {
                release()
                throw error
            }
        }

        deinit {
            release()
        }

        func close() throws {
            guard let database else { return }
            var rollbackFailure: String?
            if transactionStarted {
                let result = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                if result != SQLITE_OK {
                    rollbackFailure = Self.message(from: database, fallbackCode: result)
                }
                transactionStarted = false
            }
            let closeResult = sqlite3_close(database)
            guard closeResult == SQLITE_OK else {
                throw MigrationError.sqliteSnapshotFailed(
                    sourceURL,
                    "the coordinated source connection could not be closed: "
                        + Self.message(from: database, fallbackCode: closeResult)
                )
            }
            self.database = nil
            SQLiteHandleTracker.closed()
            if let rollbackFailure {
                throw MigrationError.sqliteSnapshotFailed(
                    sourceURL,
                    "the coordinated source transaction could not be ended: \(rollbackFailure)"
                )
            }
        }

        func backup(to destinationURL: URL) throws {
            guard let database else {
                throw MigrationError.sqliteSnapshotFailed(
                    sourceURL,
                    "the coordinated source connection is closed"
                )
            }
            var destination: OpaquePointer?
            let openResult = sqlite3_open_v2(
                destinationURL.path,
                &destination,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard openResult == SQLITE_OK, let destination else {
                let message = Self.message(from: destination, fallbackCode: openResult)
                if let destination { sqlite3_close(destination) }
                throw MigrationError.sqliteSnapshotFailed(destinationURL, message)
            }
            SQLiteHandleTracker.opened()
            defer {
                sqlite3_close_v2(destination)
                SQLiteHandleTracker.closed()
            }

            guard let backup = sqlite3_backup_init(destination, "main", database, "main") else {
                throw MigrationError.sqliteSnapshotFailed(
                    sourceURL,
                    Self.message(from: destination, fallbackCode: sqlite3_errcode(destination))
                )
            }
            let stepResult = sqlite3_backup_step(backup, -1)
            let finishResult = sqlite3_backup_finish(backup)
            guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
                let code = stepResult == SQLITE_DONE ? finishResult : stepResult
                if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                    throw MigrationError.sourceInUse(
                        sourceURL,
                        Self.message(from: database, fallbackCode: code)
                    )
                }
                throw MigrationError.sqliteSnapshotFailed(
                    sourceURL,
                    Self.message(from: database, fallbackCode: code)
                )
            }
        }

        private func execute(_ sql: String) throws {
            guard let database else {
                throw MigrationError.sqliteSnapshotFailed(sourceURL, "SQLite is closed")
            }
            var errorMessage: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
            defer { sqlite3_free(errorMessage) }
            guard result == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) }
                    ?? Self.message(from: database, fallbackCode: result)
                if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                    throw MigrationError.sourceInUse(sourceURL, message)
                }
                throw MigrationError.sqliteSnapshotFailed(sourceURL, message)
            }
        }

        private func querySingleText(_ sql: String) throws -> String {
            guard let database else {
                throw MigrationError.sqliteSnapshotFailed(sourceURL, "SQLite is closed")
            }
            var statement: OpaquePointer?
            let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
            guard prepareResult == SQLITE_OK, let statement else {
                throw MigrationError.sqliteSnapshotFailed(
                    sourceURL,
                    Self.message(from: database, fallbackCode: prepareResult)
                )
            }
            defer { sqlite3_finalize(statement) }
            let stepResult = sqlite3_step(statement)
            guard stepResult == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0)
            else {
                throw MigrationError.sqliteSnapshotFailed(
                    sourceURL,
                    Self.message(from: database, fallbackCode: stepResult)
                )
            }
            return String(cString: value)
        }

        private func release() {
            do {
                try close()
            } catch {
                guard let database else { return }
                sqlite3_close_v2(database)
                self.database = nil
                transactionStarted = false
                SQLiteHandleTracker.closed()
            }
        }

        private static func message(
            from database: OpaquePointer?,
            fallbackCode: Int32
        ) -> String {
            if let database, let message = sqlite3_errmsg(database) {
                return String(cString: message)
            }
            return String(cString: sqlite3_errstr(fallbackCode))
        }
    }
}

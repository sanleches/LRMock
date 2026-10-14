//
//  ReleasedCatalogSchemaV4Fixture.swift
//  LRMockTests
//
//  Independent fixture writer copied from the persisted definitions at git
//  commit 8b11a44. Do not share composite or model types with the production
//  compatibility reader: this file is the compatibility oracle for tests.
//

import Foundation
import SwiftData

nonisolated enum ReleasedCatalogSchemaV4Fixture {

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

    struct CurvePoint: Codable, Equatable, Sendable, Identifiable {
        var x: Double
        var y: Double
        var id: Double { x }

        init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    struct ColorMix: Codable, Equatable, Sendable {
        var hue: [Double]
        var saturation: [Double]
        var luminance: [Double]
        static let bandCount = 8

        init() {
            hue = Array(repeating: 0, count: Self.bandCount)
            saturation = Array(repeating: 0, count: Self.bandCount)
            luminance = Array(repeating: 0, count: Self.bandCount)
        }

        enum CodingKeys: String, CodingKey {
            case hue, saturation, luminance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hue = Self.normalized(
                try container.decodeIfPresent([Double].self, forKey: .hue) ?? []
            )
            saturation = Self.normalized(
                try container.decodeIfPresent([Double].self, forKey: .saturation) ?? []
            )
            luminance = Self.normalized(
                try container.decodeIfPresent([Double].self, forKey: .luminance) ?? []
            )
        }

        private static func normalized(_ values: [Double]) -> [Double] {
            var result = values.prefix(bandCount).map { value in
                value.isFinite ? min(max(value, -1), 1) : 0
            }
            if result.count < bandCount {
                result.append(contentsOf: repeatElement(0, count: bandCount - result.count))
            }
            return result
        }
    }

    struct ColorGrade: Codable, Equatable, Sendable {
        var shadowHue = 0.0
        var shadowSat = 0.0
        var midHue = 0.0
        var midSat = 0.0
        var highHue = 0.0
        var highSat = 0.0
    }

    struct DevelopSettings: Codable, Equatable, Sendable {
        var schemaVersion = 4
        var temperature = 0.0
        var tint = 0.0
        var exposure = 0.0
        var contrast = 0.0
        var highlights = 0.0
        var shadows = 0.0
        var whites = 0.0
        var blacks = 0.0
        var texture = 0.0
        var clarity = 0.0
        var dehaze = 0.0
        var vibrance = 0.0
        var saturation = 0.0
        var toneCurve = DevelopSettings.linearCurve
        var toneCurveRed = DevelopSettings.linearCurve
        var toneCurveGreen = DevelopSettings.linearCurve
        var toneCurveBlue = DevelopSettings.linearCurve
        var colorMix = ColorMix()
        var grade = ColorGrade()
        var blackWhite = false
        var bwRed = 0.0
        var bwGreen = 0.0
        var bwBlue = 0.0
        var sharpness = 0.0
        var sharpenRadius = 0.0
        var noiseReduction = 0.0
        var colorNoiseReduction = 0.0
        var grain = 0.0
        var vignette = 0.0
        var cropX = 0.0
        var cropY = 0.0
        var cropW = 1.0
        var cropH = 1.0
        var straighten = 0.0
        var flipH = false
        var flipV = false
        var rotationQuarterTurns = 0

        init() {}

        static let linearCurve = [
            CurvePoint(0, 0),
            CurvePoint(0.25, 0.25),
            CurvePoint(0.5, 0.5),
            CurvePoint(0.75, 0.75),
            CurvePoint(1, 1),
        ]

        enum CodingKeys: String, CodingKey {
            case schemaVersion, temperature, tint, exposure, contrast, highlights
            case shadows, whites, blacks, texture, clarity, dehaze, vibrance, saturation
            case toneCurve, toneCurveRed, toneCurveGreen, toneCurveBlue
            case colorMix, grade, blackWhite, bwRed, bwGreen, bwBlue
            case sharpness, sharpenRadius, noiseReduction, colorNoiseReduction, grain
            case vignette, cropX, cropY, cropW, cropH, straighten, flipH, flipV
            case rotationQuarterTurns
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func double(_ key: CodingKeys, _ fallback: Double) -> Double {
                (try? container.decodeIfPresent(Double.self, forKey: key)) ?? nil ?? fallback
            }
            func boolean(_ key: CodingKeys, _ fallback: Bool) -> Bool {
                (try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil ?? fallback
            }
            func curve(_ key: CodingKeys) -> [CurvePoint] {
                (try? container.decodeIfPresent([CurvePoint].self, forKey: key))
                    ?? nil
                    ?? Self.linearCurve
            }

            schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion))
                ?? nil
                ?? 4
            temperature = double(.temperature, 0)
            tint = double(.tint, 0)
            exposure = double(.exposure, 0)
            contrast = double(.contrast, 0)
            highlights = double(.highlights, 0)
            shadows = double(.shadows, 0)
            whites = double(.whites, 0)
            blacks = double(.blacks, 0)
            texture = double(.texture, 0)
            clarity = double(.clarity, 0)
            dehaze = double(.dehaze, 0)
            vibrance = double(.vibrance, 0)
            saturation = double(.saturation, 0)
            toneCurve = curve(.toneCurve)
            toneCurveRed = curve(.toneCurveRed)
            toneCurveGreen = curve(.toneCurveGreen)
            toneCurveBlue = curve(.toneCurveBlue)
            colorMix = (try? container.decodeIfPresent(ColorMix.self, forKey: .colorMix))
                ?? nil
                ?? ColorMix()
            grade = (try? container.decodeIfPresent(ColorGrade.self, forKey: .grade))
                ?? nil
                ?? ColorGrade()
            blackWhite = boolean(.blackWhite, false)
            bwRed = double(.bwRed, 0)
            bwGreen = double(.bwGreen, 0)
            bwBlue = double(.bwBlue, 0)
            sharpness = double(.sharpness, 0)
            sharpenRadius = double(.sharpenRadius, 0)
            noiseReduction = double(.noiseReduction, 0)
            colorNoiseReduction = double(.colorNoiseReduction, 0)
            grain = double(.grain, 0)
            vignette = double(.vignette, 0)
            cropX = double(.cropX, 0)
            cropY = double(.cropY, 0)
            cropW = double(.cropW, 1)
            cropH = double(.cropH, 1)
            straighten = double(.straighten, 0)
            flipH = boolean(.flipH, false)
            flipV = boolean(.flipV, false)
            rotationQuarterTurns = (
                try? container.decodeIfPresent(Int.self, forKey: .rotationQuarterTurns)
            ) ?? nil ?? 0
            normalizeDecodedValues()
        }

        private mutating func normalizeDecodedValues() {
            schemaVersion = 4
            temperature = Self.clampedFinite(temperature, -1...1)
            tint = Self.clampedFinite(tint, -1...1)
            exposure = Self.clampedFinite(exposure, -1...1)
            contrast = Self.clampedFinite(contrast, -1...1)
            highlights = Self.clampedFinite(highlights, -1...1)
            shadows = Self.clampedFinite(shadows, -1...1)
            whites = Self.clampedFinite(whites, -1...1)
            blacks = Self.clampedFinite(blacks, -1...1)
            texture = Self.clampedFinite(texture, -1...1)
            clarity = Self.clampedFinite(clarity, -1...1)
            dehaze = Self.clampedFinite(dehaze, -1...1)
            vibrance = Self.clampedFinite(vibrance, -1...1)
            saturation = Self.clampedFinite(saturation, -1...1)
            bwRed = Self.clampedFinite(bwRed, -1...1)
            bwGreen = Self.clampedFinite(bwGreen, -1...1)
            bwBlue = Self.clampedFinite(bwBlue, -1...1)
            sharpness = Self.clampedFinite(sharpness, 0...1)
            sharpenRadius = Self.clampedFinite(sharpenRadius, 0...1)
            noiseReduction = Self.clampedFinite(noiseReduction, 0...1)
            colorNoiseReduction = Self.clampedFinite(colorNoiseReduction, 0...1)
            grain = Self.clampedFinite(grain, 0...1)
            vignette = Self.clampedFinite(vignette, -1...1)
            grade.shadowHue = Self.clampedFinite(grade.shadowHue, 0...1)
            grade.midHue = Self.clampedFinite(grade.midHue, 0...1)
            grade.highHue = Self.clampedFinite(grade.highHue, 0...1)
            grade.shadowSat = Self.clampedFinite(grade.shadowSat, 0...1)
            grade.midSat = Self.clampedFinite(grade.midSat, 0...1)
            grade.highSat = Self.clampedFinite(grade.highSat, 0...1)
            toneCurve = Self.normalizedCurve(toneCurve)
            toneCurveRed = Self.normalizedCurve(toneCurveRed)
            toneCurveGreen = Self.normalizedCurve(toneCurveGreen)
            toneCurveBlue = Self.normalizedCurve(toneCurveBlue)
            cropW = Self.clampedFinite(cropW, 0.01...1)
            cropH = Self.clampedFinite(cropH, 0.01...1)
            cropX = Self.clampedFinite(cropX, 0...(1 - cropW))
            cropY = Self.clampedFinite(cropY, 0...(1 - cropH))
            straighten = Self.clampedFinite(straighten, -45...45)
            rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
        }

        private static func clampedFinite(
            _ value: Double,
            _ range: ClosedRange<Double>
        ) -> Double {
            guard value.isFinite else {
                return min(max(0, range.lowerBound), range.upperBound)
            }
            return min(max(value, range.lowerBound), range.upperBound)
        }

        private static func normalizedCurve(_ points: [CurvePoint]) -> [CurvePoint] {
            let sorted = points
                .filter { $0.x.isFinite && $0.y.isFinite }
                .map {
                    CurvePoint(
                        clampedFinite($0.x, 0...1),
                        clampedFinite($0.y, 0...1)
                    )
                }
                .sorted { $0.x < $1.x }
            var unique: [CurvePoint] = []
            for point in sorted {
                if let last = unique.last, abs(last.x - point.x) < 0.000_001 {
                    unique[unique.count - 1] = point
                } else {
                    unique.append(point)
                }
            }
            guard unique.count >= 2 else { return linearCurve }
            if unique[0].x > 0 {
                unique.insert(CurvePoint(0, unique[0].y), at: 0)
            }
            if unique[unique.count - 1].x < 1 {
                unique.append(CurvePoint(1, unique[unique.count - 1].y))
            }
            return unique
        }
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
        var contentDigest: String?
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
            self.contentDigest = nil
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

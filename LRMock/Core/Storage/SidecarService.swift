//
//  SidecarService.swift
//  RawLight
//
//  Reads and writes the `.rawlight` sidecar file that lives next to each RAW.
//
//  Why sidecars (in addition to the catalog)?
//  ------------------------------------------
//  The SwiftData catalog is the fast, queryable source of truth for the running
//  app. The sidecar is the *portable* source of truth: it travels with the RAW,
//  survives a catalog rebuild, and lets edits move between devices or be read by
//  a future desktop companion. On import we prefer an existing sidecar so a
//  previously-edited file re-links with its edits intact.
//
//  Format: compact JSON, mirroring RawTherapee's `.pp3`-next-to-RAW idea but
//  using our own schema. Example file name: `DSCF1234.RAF.rawlight`.
//

import Foundation

/// The serialisable contents of a `.rawlight` sidecar.
nonisolated struct Sidecar: Codable, Sendable {
    var schemaVersion: Int = 1
    var fingerprint: ImageFingerprint
    var sourceContentDigest: String? = nil
    var develop: DevelopSettings
    var rating: Int
    var flag: Int
    var colorLabel: Int
}

nonisolated enum SidecarService {

    static let fileExtension = "rawlight"
    private static let schemaVersion = 1
    static let maximumFileSize = 2 * 1024 * 1024

    enum SidecarError: LocalizedError {
        case unsupportedVersion(Int)
        case fileTooLarge
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "The sidecar uses unsupported version \(version)."
            case .fileTooLarge:
                return "The sidecar is larger than the supported limit."
            case .accessDenied:
                return "The adjacent sidecar could not be accessed with the current file permission."
            }
        }
    }

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

    /// Sidecar URL for a given original file, e.g. `…/DSCF1234.RAF.rawlight`.
    static func sidecarURL(for originalURL: URL) -> URL {
        originalURL.appendingPathExtension(fileExtension)
    }

    /// Writes (or overwrites) the sidecar next to the original file.
    /// Caller is responsible for holding security-scoped access when the
    /// original lives outside the sandbox.
    static func write(_ sidecar: Sidecar, for originalURL: URL) throws {
        var normalized = sidecar
        normalized.schemaVersion = schemaVersion
        normalized.fingerprint.fileSizeBytes = max(0, sidecar.fingerprint.fileSizeBytes)
        normalized.develop = sidecar.develop.normalizedForPersistence()
        normalized.rating = min(max(sidecar.rating, 0), 5)
        normalized.flag = PickFlag(rawValue: sidecar.flag)?.rawValue ?? PickFlag.unflagged.rawValue
        normalized.colorLabel = min(max(sidecar.colorLabel, 0), 5)
        let data = try makeEncoder().encode(normalized)
        guard data.count <= maximumFileSize else {
            throw SidecarError.fileTooLarge
        }
        try data.write(to: sidecarURL(for: originalURL), options: .atomic)
    }

    /// Reads the sidecar if one exists next to the original file.
    static func read(for originalURL: URL) throws -> Sidecar? {
        try read(at: sidecarURL(for: originalURL))
    }

    /// Reads a sidecar selected explicitly by the user. This is separate from
    /// `read(for:)` because a file-scoped picker grant may not cover siblings.
    static func read(at url: URL) throws -> Sidecar? {
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
            throw SidecarError.fileTooLarge
        } catch {
            if BoundedFileReader.isMissingFile(error) { return nil }
            if isAccessDenied(error) { throw SidecarError.accessDenied }
            throw error
        }
        let sidecar = try makeDecoder().decode(Sidecar.self, from: data)
        guard sidecar.schemaVersion == schemaVersion else {
            throw SidecarError.unsupportedVersion(sidecar.schemaVersion)
        }
        return sidecar
    }

    static func isAccessDenied(_ error: Error) -> Bool {
        if case SidecarError.accessDenied = error { return true }
        return BoundedFileReader.isAccessDenied(error)
    }

    /// Builds a `Sidecar` snapshot from a catalog asset.
    @MainActor
    static func snapshot(of asset: ImageAsset) -> Sidecar {
        Sidecar(
            fingerprint: asset.fingerprint,
            sourceContentDigest: asset.contentDigest,
            develop: asset.develop.normalizedForPersistence(),
            rating: asset.rating,
            flag: asset.flagRaw,
            colorLabel: asset.colorLabel
        )
    }
}

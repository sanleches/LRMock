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
//  Format: pretty-printed JSON, mirroring RawTherapee's `.pp3`-next-to-RAW idea
//  but using our own schema. Example file name: `DSCF1234.RAF.rawlight`.
//

import Foundation

/// The serialisable contents of a `.rawlight` sidecar.
nonisolated struct Sidecar: Codable, Sendable {
    var schemaVersion: Int = 1
    var fingerprint: ImageFingerprint
    var develop: DevelopSettings
    var rating: Int
    var flag: Int
    var colorLabel: Int
}

nonisolated enum SidecarService {

    static let fileExtension = "rawlight"
    private static let schemaVersion = 1
    private static let maximumFileSize = 2 * 1024 * 1024

    enum SidecarError: LocalizedError {
        case unsupportedVersion(Int)
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "The sidecar uses unsupported version \(version)."
            case .fileTooLarge:
                return "The sidecar is larger than the supported limit."
            }
        }
    }

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

    /// Sidecar URL for a given original file, e.g. `…/DSCF1234.RAF.rawlight`.
    static func sidecarURL(for originalURL: URL) -> URL {
        originalURL.appendingPathExtension(fileExtension)
    }

    /// Writes (or overwrites) the sidecar next to the original file.
    /// Caller is responsible for holding security-scoped access when the
    /// original lives outside the sandbox.
    static func write(_ sidecar: Sidecar, for originalURL: URL) throws {
        let data = try encoder.encode(sidecar)
        try data.write(to: sidecarURL(for: originalURL), options: .atomic)
    }

    /// Reads the sidecar if one exists next to the original file.
    static func read(for originalURL: URL) throws -> Sidecar? {
        let url = sidecarURL(for: originalURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumFileSize else {
            throw SidecarError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let sidecar = try decoder.decode(Sidecar.self, from: data)
        guard sidecar.schemaVersion == schemaVersion else {
            throw SidecarError.unsupportedVersion(sidecar.schemaVersion)
        }
        return sidecar
    }

    /// Builds a `Sidecar` snapshot from a catalog asset.
    @MainActor
    static func snapshot(of asset: ImageAsset) -> Sidecar {
        Sidecar(
            fingerprint: asset.fingerprint,
            develop: asset.develop,
            rating: asset.rating,
            flag: asset.flagRaw,
            colorLabel: asset.colorLabel
        )
    }
}

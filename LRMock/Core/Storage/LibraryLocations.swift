//
//  LibraryLocations.swift
//  RawLight
//
//  On-disk layout of the managed Library, aligned with the RawLight design
//  (docs/architecture/catalog-and-persistence.md). All canonical stores for one
//  active library live under a single generation root, so a future restore can
//  build a new generation and atomically switch `CurrentLibrary.json`:
//
//      Application Support/RawLight/
//        CurrentLibrary.json                     ← checksummed pointer to a generation
//        Libraries/<generation UUID>/
//          Catalog/catalog.store                 ← SwiftData (catalog index)
//          Originals/<asset UUID>/primary.<ext>  ← immutable managed originals
//          Recipes/<asset UUID>.rawlight.json    ← canonical edit recipe + metadata
//          Trash/                                ← recoverable deletes
//      Library/Caches/RawLight/Thumbnails/       ← disposable render cache
//
//  This is the Lightroom-style "catalog folder": importing copies the RAW into
//  `Originals/` and the edit recipe/metadata is saved next to it in `Recipes/`.
//  It is user-revealable in Finder on macOS and visible in Files on iPadOS.
//

import Foundation
import CryptoKit

nonisolated enum LibraryLocations {

    /// `{ "schemaVersion": 1, "generationID": "<uuid>", "checksum": "..." }`
    private struct CurrentLibrary: Codable {
        var schemaVersion: Int
        var generationID: UUID
        var checksum: String?
    }

    enum LocationError: LocalizedError {
        case corruptLibraryPointer
        case unsupportedPointerVersion(Int)
        case pointerWriteFailed(Error)
        case pathOutsideLibrary(URL)
        case invalidRelativePath(String)

        var errorDescription: String? {
            switch self {
            case .corruptLibraryPointer:
                return "The active library pointer is damaged and no existing library could be recovered."
            case .unsupportedPointerVersion(let version):
                return "This library pointer uses unsupported version \(version)."
            case .pointerWriteFailed(let error):
                return "The active library pointer could not be saved: \(error.localizedDescription)"
            case .pathOutsideLibrary(let url):
                return "The managed file is outside the active library: \(url.path)"
            case .invalidRelativePath(let path):
                return "The managed path is invalid: \(path)"
            }
        }
    }

    private static let schemaVersion = 1
    private static let lock = NSLock()
    private static var cachedGeneration: UUID?
    private static var configuredAppRoot: URL?
    private static var configuredCacheRoot: URL?

    // MARK: Roots

    /// `Application Support/RawLight` — the library container.
    static var appRoot: URL {
        lock.lock()
        let configured = configuredAppRoot
        lock.unlock()
        if let configured { return configured }
        if let path = ProcessInfo.processInfo.environment["RAWLIGHT_LIBRARY_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        else { preconditionFailure("Application Support is unavailable") }
        return base.appendingPathComponent("RawLight", isDirectory: true)
    }

    /// The active generation directory, `Libraries/<generation UUID>`.
    static var currentGeneration: URL {
        appRoot
            .appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(generationID().uuidString, isDirectory: true)
    }

    static var originals: URL { currentGeneration.appendingPathComponent("Originals", isDirectory: true) }
    static var incoming: URL { currentGeneration.appendingPathComponent("Incoming", isDirectory: true) }
    static var recipes: URL { currentGeneration.appendingPathComponent("Recipes", isDirectory: true) }
    static var trash: URL { currentGeneration.appendingPathComponent("Trash", isDirectory: true) }
    static var catalogStoreURL: URL {
        currentGeneration
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.store")
    }

    /// Disposable thumbnail cache (safe to purge; never canonical).
    static var thumbnailsCache: URL {
        lock.lock()
        let configured = configuredCacheRoot
        lock.unlock()
        if let configured { return configured.appendingPathComponent("Thumbnails", isDirectory: true) }
        if let path = ProcessInfo.processInfo.environment["RAWLIGHT_CACHE_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
                .appendingPathComponent("Thumbnails", isDirectory: true)
        }
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { preconditionFailure("Caches directory is unavailable") }
        return caches.appendingPathComponent("RawLight/Thumbnails", isDirectory: true)
    }

    // MARK: Lifecycle

    /// Creates the library tree and resolves/creates the current generation.
    /// Idempotent; call once at launch (and safe to call again).
    @discardableResult
    static func bootstrap() throws -> UUID {
        let generation = try resolveGenerationID()
        for url in [originals, incoming, recipes, trash,
                    catalogStoreURL.deletingLastPathComponent(), thumbnailsCache] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return generation
    }

    /// Overrides all persistent roots for hermetic tests and previews.
    /// Call before accessing any other location, then call `resetConfiguredRoots()`.
    static func configureRoots(appRoot: URL, cacheRoot: URL) {
        lock.lock()
        configuredAppRoot = appRoot.standardizedFileURL
        configuredCacheRoot = cacheRoot.standardizedFileURL
        cachedGeneration = nil
        lock.unlock()
    }

    static func resetConfiguredRoots() {
        lock.lock()
        configuredAppRoot = nil
        configuredCacheRoot = nil
        cachedGeneration = nil
        lock.unlock()
    }

    // MARK: Managed paths

    /// Directory that holds one asset's managed original(s).
    static func managedOriginalDirectory(assetID: UUID) -> URL {
        originals.appendingPathComponent(assetID.uuidString, isDirectory: true)
    }

    /// `Originals/<assetID>/primary.<ext>`
    static func managedOriginalURL(assetID: UUID, fileExtension ext: String) -> URL {
        let name = ext.isEmpty ? "primary" : "primary.\(ext.lowercased())"
        return managedOriginalDirectory(assetID: assetID).appendingPathComponent(name)
    }

    /// `Recipes/<assetID>.rawlight.json`
    static func recipeURL(assetID: UUID) -> URL {
        recipes.appendingPathComponent("\(assetID.uuidString).rawlight.json")
    }

    /// Path relative to the current generation (what we persist on the asset).
    static func relativePath(of url: URL) throws -> String {
        let root = currentGeneration.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(root + "/") else {
            throw LocationError.pathOutsideLibrary(url)
        }
        return String(candidate.dropFirst(root.count + 1))
    }

    /// Resolves a stored relative path back to an absolute URL.
    static func url(forManagedRelativePath relative: String) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~") else {
            throw LocationError.invalidRelativePath(relative)
        }
        let components = NSString(string: relative).pathComponents
        guard !components.contains(".."), !components.contains(".") else {
            throw LocationError.invalidRelativePath(relative)
        }

        let root = currentGeneration.standardizedFileURL
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw LocationError.invalidRelativePath(relative)
        }
        return candidate
    }

    // MARK: Generation resolution

    private static func generationID() -> UUID {
        do {
            return try resolveGenerationID()
        } catch {
            preconditionFailure("Unable to resolve RawLight library: \(error.localizedDescription)")
        }
    }

    private static func resolveGenerationID() throws -> UUID {
        // Resolve the configurable root before taking the generation lock.
        // `appRoot` briefly takes the same lock to snapshot test configuration.
        let root = appRoot
        lock.lock(); defer { lock.unlock() }
        if let cached = cachedGeneration { return cached }

        let pointer = root.appendingPathComponent("CurrentLibrary.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: pointer.path) {
            do {
                let data = try Data(contentsOf: pointer)
                let current = try JSONDecoder().decode(CurrentLibrary.self, from: data)
                guard current.schemaVersion == schemaVersion else {
                    throw LocationError.unsupportedPointerVersion(current.schemaVersion)
                }
                if let checksum = current.checksum,
                   checksum != pointerChecksum(generationID: current.generationID) {
                    throw LocationError.corruptLibraryPointer
                }
                if current.checksum == nil {
                    try writePointer(generationID: current.generationID, to: pointer)
                }
                cachedGeneration = current.generationID
                return current.generationID
            } catch let error as LocationError {
                if case .unsupportedPointerVersion = error { throw error }
                if let recovered = try recoverGenerationID(appRoot: root) {
                    try writePointer(generationID: recovered, to: pointer)
                    cachedGeneration = recovered
                    return recovered
                }
                throw error
            } catch {
                if let recovered = try recoverGenerationID(appRoot: root) {
                    try writePointer(generationID: recovered, to: pointer)
                    cachedGeneration = recovered
                    return recovered
                }
                throw LocationError.corruptLibraryPointer
            }
        }

        if let recovered = try recoverGenerationID(appRoot: root) {
            try writePointer(generationID: recovered, to: pointer)
            cachedGeneration = recovered
            return recovered
        }

        let fresh = UUID()
        try writePointer(generationID: fresh, to: pointer)
        cachedGeneration = fresh
        return fresh
    }

    private static func recoverGenerationID(appRoot: URL) throws -> UUID? {
        let libraries = appRoot.appendingPathComponent("Libraries", isDirectory: true)
        guard FileManager.default.fileExists(atPath: libraries.path) else { return nil }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: libraries,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url -> (UUID, Date)? in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (id, date)
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    private static func writePointer(generationID: UUID, to url: URL) throws {
        let payload = CurrentLibrary(
            schemaVersion: schemaVersion,
            generationID: generationID,
            checksum: pointerChecksum(generationID: generationID)
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw LocationError.pointerWriteFailed(error)
        }
    }

    private static func pointerChecksum(generationID: UUID) -> String {
        let value = "\(schemaVersion):\(generationID.uuidString.lowercased())"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

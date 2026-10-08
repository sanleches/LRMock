//
//  LibraryLocations.swift
//  RawLight
//
//  Canonical on-disk locations for the app.
//
//  Layout inside the app sandbox
//  -----------------------------
//      Documents/                 ← exposed in Files as "RawLight"
//        Managed/                 ← copied-in RAWs (StorageMode.managed)
//          <folder name>/…        ← one subdir per managed LibraryFolder
//            DSCF1234.RAF
//            DSCF1234.RAF.rawlight ← sidecar lives next to its RAW
//      Library/Caches/
//        Thumbnails/              ← generated previews (safe to purge)
//
//  `Documents` is exposed to the Files app via the `UIFileSharingEnabled` /
//  `LSSupportsOpeningDocumentsInPlace` Info.plist keys, so users can drag RAWs
//  straight into "On My iPad → RawLight". Referenced (external) files are *not*
//  copied here — only their bookmarks live in the catalog.
//

import Foundation

enum LibraryLocations {

    /// The sandbox `Documents` directory (the Files-visible "RawLight" root).
    static var documents: URL {
        // `Documents` is guaranteed to exist for every app.
        try! FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }

    /// Root for files RawLight owns (copied-in imports).
    static var managedRoot: URL {
        documents.appendingPathComponent("Managed", isDirectory: true)
    }

    /// Caches directory for regenerable thumbnails.
    static var thumbnailsCache: URL {
        let caches = try! FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return caches.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// Creates the directory tree the app relies on. Idempotent; call at launch.
    static func bootstrap() throws {
        for url in [managedRoot, thumbnailsCache] {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        }
    }

    /// Directory inside the managed root for a given folder name.
    static func managedFolder(named name: String) -> URL {
        managedRoot.appendingPathComponent(sanitize(name), isDirectory: true)
    }

    /// Strips path separators and other awkward characters from a folder name so
    /// it is safe to use as a directory component.
    static func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

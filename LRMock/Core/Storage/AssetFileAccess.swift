//
//  AssetFileAccess.swift
//  RawLight
//
//  Resolves an `ImageAsset` back to a usable file URL, transparently handling
//  the two storage modes:
//    * `.managed`    – a plain path inside our sandbox (no scoping needed).
//    * `.referenced` – an external file reached through a security-scoped
//                      bookmark (must be balanced with a stop call).
//
//  Callers use `open(_:)` to get a handle and MUST call `release()` when done
//  (or use `withAccess` for automatic balancing). Keeping this in one place
//  means no view or service has to remember the sandbox rules.
//

import Foundation

nonisolated enum AssetFileAccess {

    /// Sendable location snapshot used by background services without passing a
    /// SwiftData model across actors.
    struct Reference: Sendable {
        let storageMode: StorageMode
        let managedRelativePath: String?
        let bookmarkData: Data?

        @MainActor
        init(asset: ImageAsset) {
            storageMode = asset.storageMode
            managedRelativePath = asset.managedRelativePath
            bookmarkData = asset.bookmarkData
        }
    }

    /// A resolved, currently-accessible file. Call `release()` exactly once.
    struct Handle {
        let url: URL
        private let onRelease: () -> Void
        init(url: URL, onRelease: @escaping () -> Void) {
            self.url = url
            self.onRelease = onRelease
        }
        func release() { onRelease() }
    }

    enum AccessError: Error { case unresolved, scopeDenied }

    /// Opens the asset's original file, beginning scoped access if required.
    @MainActor
    static func open(_ asset: ImageAsset) throws -> Handle {
        try open(Reference(asset: asset))
    }

    static func open(_ reference: Reference) throws -> Handle {
        switch reference.storageMode {
        case .managed:
            guard let relative = reference.managedRelativePath else {
                throw AccessError.unresolved
            }
            let url = try LibraryLocations.url(forManagedRelativePath: relative)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AccessError.unresolved
            }
            return Handle(url: url, onRelease: {})

        case .referenced:
            guard let data = reference.bookmarkData else { throw AccessError.unresolved }
            let (url, _) = try BookmarkStore.resolve(data)
            guard url.startAccessingSecurityScopedResource() else {
                throw AccessError.scopeDenied
            }
            return Handle(url: url, onRelease: { url.stopAccessingSecurityScopedResource() })
        }
    }

    /// Convenience that opens, runs `body`, and always releases access.
    @MainActor
    static func withAccess<T>(_ asset: ImageAsset, _ body: (URL) throws -> T) throws -> T {
        let handle = try open(asset)
        defer { handle.release() }
        return try body(handle.url)
    }
}

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

enum AssetFileAccess {

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
    static func open(_ asset: ImageAsset) throws -> Handle {
        switch asset.storageMode {
        case .managed:
            guard let relative = asset.managedRelativePath else {
                throw AccessError.unresolved
            }
            let url = LibraryLocations.documents.appendingPathComponent(relative)
            return Handle(url: url, onRelease: {})

        case .referenced:
            guard let data = asset.bookmarkData else { throw AccessError.unresolved }
            let (url, _) = try BookmarkStore.resolve(data)
            guard url.startAccessingSecurityScopedResource() else {
                throw AccessError.scopeDenied
            }
            return Handle(url: url, onRelease: { url.stopAccessingSecurityScopedResource() })
        }
    }

    /// Convenience that opens, runs `body`, and always releases access.
    static func withAccess<T>(_ asset: ImageAsset, _ body: (URL) throws -> T) throws -> T {
        let handle = try open(asset)
        defer { handle.release() }
        return try body(handle.url)
    }
}

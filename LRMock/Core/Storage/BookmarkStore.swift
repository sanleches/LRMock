//
//  BookmarkStore.swift
//  RawLight
//
//  Creates and resolves security-scoped bookmarks so the app can re-open files
//  the user picked in previous launches without copying them into the sandbox.
//
//  Platform note
//  -------------
//  * On iOS/iPadOS, URLs returned by the document picker are already security
//    scoped; `bookmarkData()` with no options preserves that scope.
//  * On macOS the `.withSecurityScope` option is required.
//  We branch on the platform so the same call site works everywhere.
//
//  Scoped access is balanced: every `startAccessingSecurityScopedResource()`
//  is paired with a `stop…`. Use `withAccess(to:)` to make that automatic.
//

import Foundation

enum BookmarkStore {

    enum BookmarkError: Error { case resolutionFailed, accessDenied }

    /// Creates a persistable bookmark for a URL the user granted access to.
    static func makeBookmark(for url: URL) throws -> Data {
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }

        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope],
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
        #else
        return try url.bookmarkData(options: [],
                                    includingResourceValuesForKeys: nil,
                                    relativeTo: nil)
        #endif
    }

    /// Resolves a stored bookmark back into a URL.
    /// - Returns: the URL and whether the bookmark is stale (should be re-saved).
    static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let options: URL.BookmarkResolutionOptions = []
        #endif

        let url = try URL(resolvingBookmarkData: data,
                          options: options,
                          relativeTo: nil,
                          bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    /// Runs `body` with security-scoped access to the bookmarked file, always
    /// balancing the start/stop calls even if `body` throws.
    static func withAccess<T>(to data: Data, _ body: (URL) throws -> T) throws -> T {
        let (url, _) = try resolve(data)
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try body(url)
    }
}

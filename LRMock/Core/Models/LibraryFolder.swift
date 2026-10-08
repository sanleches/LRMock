//
//  LibraryFolder.swift
//  RawLight
//
//  A filesystem-backed grouping of imported images, shown in the left sidebar.
//
//  A folder is either:
//    * `.managed`  – a directory RawLight created inside its own library, or
//    * `.external` – a user-chosen directory accessed via a bookmark.
//
//  Folders model *where files came from*. For arbitrary user-curated groupings
//  that ignore filesystem layout, see `AssetCollection`.
//

import Foundation
import SwiftData

@Model
final class LibraryFolder {

    @Attribute(.unique) var id: UUID
    var name: String
    var kind: FolderKind

    /// Bookmark to the external directory. Set only when `kind == .external`.
    var bookmarkData: Data?

    /// Ordering within the sidebar.
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

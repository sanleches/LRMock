//
//  AssetCollection.swift
//  RawLight
//
//  A user-curated set of images, independent of filesystem layout — the
//  equivalent of a Lightroom "Collection". Membership is explicit and an image
//  can belong to many collections (many-to-many with `ImageAsset`).
//
//  Phase 0 implements manual collections only. Smart (query-driven) collections
//  are a later phase; when added they will store a predicate instead of an
//  explicit `assets` list.
//

import Foundation
import SwiftData

@Model
final class AssetCollection {

    @Attribute(.unique) var id: UUID
    var name: String

    /// SF Symbol used in the sidebar.
    var symbol: String
    var sortIndex: Int
    var createdAt: Date

    /// Explicit membership. The inverse is declared on `ImageAsset.collections`.
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

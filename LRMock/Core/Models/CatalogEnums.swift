//
//  CatalogEnums.swift
//  RawLight
//
//  Small value types shared across the catalog models.
//

import Foundation

/// Where the bytes of an imported RAW physically live.
enum StorageMode: String, Codable, Sendable {
    /// Copied into the app's managed library folder (shown in Files as RawLight).
    /// RawLight owns the file and may move/delete it.
    case managed
    /// Left in place on an external/user-chosen location and accessed through a
    /// security-scoped bookmark. RawLight never mutates these bytes.
    case referenced
}

/// Pick / reject flag, mirroring Lightroom's P / X / unflagged states.
enum PickFlag: Int, Codable, Sendable {
    case rejected = -1
    case unflagged = 0
    case picked = 1
}

/// How a sidebar folder maps onto the filesystem.
enum FolderKind: String, Codable, Sendable {
    /// A subfolder of the managed library that RawLight created.
    case managed
    /// An external directory the user granted access to (bookmarked).
    case external
}

//
//  LibrarySelection.swift
//  RawLight
//
//  Identifies what the sidebar has selected and therefore which assets the grid
//  should show. Hashable so it can drive `NavigationSplitView` selection and
//  `List(selection:)`.
//

import Foundation
import SwiftData

enum LibrarySelection: Hashable {
    /// Every asset in the catalog.
    case allPhotos
    /// A filesystem-backed folder.
    case folder(PersistentIdentifier)
    /// A user-curated collection.
    case collection(PersistentIdentifier)
}

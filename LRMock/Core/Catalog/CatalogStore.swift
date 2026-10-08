//
//  CatalogStore.swift
//  RawLight
//
//  Owns the SwiftData schema and `ModelContainer` for the whole app.
//
//  Keeping the schema definition in one place (rather than inline in the App
//  struct) means tests and previews can spin up an in-memory container with the
//  exact same model set.
//

import Foundation
import SwiftData

enum CatalogStore {

    /// Every persisted model in the catalog.
    static let schema = Schema([
        ImageAsset.self,
        LibraryFolder.self,
        AssetCollection.self,
    ])

    /// The on-disk container used by the running app.
    static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    /// An ephemeral container for previews and unit tests.
    static func makeInMemoryContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }
}

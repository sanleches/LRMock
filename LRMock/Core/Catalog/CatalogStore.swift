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

    struct LoadFailure: Identifiable {
        let id = UUID()
        let message: String
        let libraryURL: URL
    }

    struct LoadResult {
        let container: ModelContainer
        let failure: LoadFailure?
    }

    /// Every persisted model in the catalog.
    static let schema = Schema([
        ImageAsset.self,
        LibraryFolder.self,
        AssetCollection.self,
    ])

    /// The on-disk container used by the running app. The catalog store lives
    /// inside the active library generation (`Libraries/<gen>/Catalog/`) so the
    /// whole library — originals, recipes, and index — is one relocatable unit.
    ///
    /// Opens the persistent catalog without ever deleting or replacing a failed
    /// store. On failure, the app receives an in-memory container solely so it
    /// can present recovery UI; editing remains unavailable until the real store
    /// can be opened again.
    static func makeContainer() -> LoadResult {
        do {
            try LibraryLocations.bootstrap()
            let configuration = ModelConfiguration(schema: schema, url: LibraryLocations.catalogStoreURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return LoadResult(container: container, failure: nil)
        } catch {
            let fallback = makeInMemoryContainer()
            let failure = LoadFailure(
                message: error.localizedDescription,
                libraryURL: LibraryLocations.appRoot
            )
            return LoadResult(container: fallback, failure: failure)
        }
    }

    /// An ephemeral container for previews and unit tests.
    static func makeInMemoryContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }
}

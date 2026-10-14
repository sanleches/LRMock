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

    private enum StoreError: LocalizedError {
        case missingCatalog(UUID)
        case unavailableLegacyMigrationSource

        var errorDescription: String? {
            switch self {
            case .missingCatalog(let generationID):
                return "The selected library generation \(generationID.uuidString) has no recoverable catalog. An empty replacement was not created."
            case .unavailableLegacyMigrationSource:
                return "The legacy catalog required to verify an interrupted migration is unavailable. The recovered generation was not published."
            }
        }
    }

    struct LoadFailure: Identifiable {
        let id = UUID()
        let message: String
        let libraryURL: URL
    }

    struct LoadResult {
        let container: ModelContainer
        let failure: LoadFailure?
        private let catalogLease: LibraryLocations.CatalogSessionLease?

        fileprivate init(
            container: ModelContainer,
            failure: LoadFailure?,
            catalogLease: LibraryLocations.CatalogSessionLease?
        ) {
            self.container = container
            self.failure = failure
            self.catalogLease = catalogLease
        }
    }

    /// Every persisted model in the catalog.
    nonisolated static let schema = Schema([
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
        makeContainer(
            legacyStoreURL: defaultLegacyStoreURL(),
            legacyLibraryRoot: defaultLegacyLibraryRoot()
        )
    }

    /// Parameterized for migration tests so they never touch a developer's real
    /// default SwiftData store.
    static func makeContainer(
        legacyStoreURL: URL?,
        legacyLibraryRoot: URL? = nil
    ) -> LoadResult {
        var failureURL = LibraryLocations.appRoot
        var preparation: LibraryLocations.CatalogPreparation?
        do {
            var prepared = try LibraryLocations.prepareCatalog()
            preparation = prepared
            var legacySourceIdentity: CatalogV4Migration.SourceIdentity?
            var migrationSourceLease: CatalogV4Migration.SourceLease?
            if FileManager.default.fileExists(atPath: prepared.catalogURL.path)
                || prepared.migrationSourceURL != nil {
                let migration = try CatalogV4Migration.migrateStoreIfNeeded(prepared)
                prepared = migration.preparation
                preparation = prepared
                legacySourceIdentity = migration.legacySourceIdentity
                migrationSourceLease = migration.sourceLease
                if let pendingLegacySourceIdentity = legacySourceIdentity,
                   migrationSourceLease == nil,
                   prepared.requiresLegacySourceRevalidation,
                   try !LibraryLocations.legacyMigrationCompletionMatches(
                    at: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL,
                    sourceIdentity: pendingLegacySourceIdentity,
                    targetGenerationID: prepared.generationID
                   ) {
                    if let legacyStoreURL { failureURL = legacyStoreURL }
                    guard let legacyStoreURL,
                          FileManager.default.fileExists(atPath: legacyStoreURL.path)
                    else {
                        throw StoreError.unavailableLegacyMigrationSource
                    }
                    failureURL = legacyStoreURL
                    let legacyRecovery = try CatalogV4Migration.migrateLegacyStore(
                        at: legacyStoreURL,
                        legacyLibraryRoot: legacyLibraryRoot,
                        replacing: prepared
                    )
                    prepared = legacyRecovery.preparation
                    preparation = prepared
                    legacySourceIdentity = legacyRecovery.legacySourceIdentity
                    migrationSourceLease = legacyRecovery.sourceLease
                }
                // A legacy-derived current catalog remains authoritative even if
                // the user later deletes every catalog entity.
                if migrationSourceLease == nil,
                   legacySourceIdentity == nil,
                   let legacyStoreURL,
                   FileManager.default.fileExists(atPath: legacyStoreURL.path) {
                    let currentProbe = try CatalogV4Migration.probeStore(
                        at: prepared.catalogURL
                    )
                    if currentProbe.isEmpty,
                       try !LibraryLocations.legacyMigrationWasCompleted(
                        at: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL
                       ) {
                        failureURL = legacyStoreURL
                        let legacyProbe = try CatalogV4Migration.probeStore(at: legacyStoreURL)
                        if legacyProbe.format.isLegacy, !legacyProbe.isEmpty {
                            let legacyMigration = try CatalogV4Migration.migrateLegacyStore(
                                at: legacyStoreURL,
                                legacyLibraryRoot: legacyLibraryRoot,
                                replacing: prepared
                            )
                            prepared = legacyMigration.preparation
                            preparation = prepared
                            legacySourceIdentity = legacyMigration.legacySourceIdentity
                            migrationSourceLease = legacyMigration.sourceLease
                        }
                    }
                }
            } else if !prepared.allowsCatalogCreation {
                throw StoreError.missingCatalog(prepared.generationID)
            } else {
                let requiresLegacyRecovery = try LibraryLocations
                    .legacyMigrationTargetIsMissing(
                        at: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL,
                        appRoot: LibraryLocations.appRoot
                    )
                if let legacyStoreURL { failureURL = legacyStoreURL }
                if let legacyStoreURL,
                   FileManager.default.fileExists(atPath: legacyStoreURL.path) {
                    let legacyProbe = try CatalogV4Migration.probeStore(at: legacyStoreURL)
                    guard !requiresLegacyRecovery
                            || (legacyProbe.format.isLegacy && !legacyProbe.isEmpty)
                    else {
                        throw StoreError.unavailableLegacyMigrationSource
                    }
                    if legacyProbe.format.isLegacy, !legacyProbe.isEmpty {
                        let migration = try CatalogV4Migration.migrateLegacyStore(
                            at: legacyStoreURL,
                            legacyLibraryRoot: legacyLibraryRoot,
                            into: prepared
                        )
                        prepared = migration.preparation
                        preparation = prepared
                        legacySourceIdentity = migration.legacySourceIdentity
                        migrationSourceLease = migration.sourceLease
                    }
                } else if requiresLegacyRecovery {
                    throw StoreError.unavailableLegacyMigrationSource
                }
            }

            let configuration = ModelConfiguration(schema: schema, url: prepared.catalogURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let catalogLease = try LibraryLocations.completeCatalogOpen(
                prepared,
                legacySourceIdentity: legacySourceIdentity,
                migrationSourceLease: migrationSourceLease
            )
            return LoadResult(
                container: container,
                failure: nil,
                catalogLease: catalogLease
            )
        } catch {
            if let preparation {
                LibraryLocations.abandonCatalogOpen(preparation)
            }
            let fallback = makeInMemoryContainer()
            let failure = LoadFailure(
                message: error.localizedDescription,
                libraryURL: failureURL
            )
            return LoadResult(
                container: fallback,
                failure: failure,
                catalogLease: nil
            )
        }
    }

    /// An ephemeral container for previews and unit tests.
    static func makeInMemoryContainer() -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [configuration])
    }

    private static func defaultLegacyStoreURL() -> URL? {
        guard !LibraryLocations.usesCustomLibraryRoot else { return nil }
        return ModelConfiguration(schema: schema, isStoredInMemoryOnly: false).url
    }

    private static func defaultLegacyLibraryRoot() -> URL? {
        guard !LibraryLocations.usesCustomLibraryRoot else { return nil }
        return try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
    }
}

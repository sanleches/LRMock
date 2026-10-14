//
//  CatalogGenerationSafetyTests.swift
//  LRMockTests
//

import CryptoKit
import Darwin
import Foundation
import SQLite3
import SwiftData
import Testing
@testable import LRMock

@Suite(.serialized)
@MainActor
struct CatalogGenerationSafetyTests {

    private struct TestRoots {
        let app: URL
        let cache: URL
    }

    private struct V4Fixture {
        let firstAssetID: UUID
        let secondAssetID: UUID
        let externalFolderID: UUID
        let picksCollectionID: UUID
        let portfolioCollectionID: UUID
        let folderBookmark: Data
        let assetBookmark: Data
        let managedRelativePath: String
        let managedOriginalData: Data
        let managedSidecarData: Data?
        let managedContentDigest: String
    }

    private struct LegacyMigrationMarker: Decodable {
        let schemaVersion: Int
        let sourceIdentity: CatalogV4Migration.SourceIdentity
        let targetGenerationID: UUID
    }

    @Test func staleCatalogScratchWorkspaceIsReclaimedWithoutTouchingLiveOwner() throws {
        let temporary = FileManager.default.temporaryDirectory
        let deadOwner = temporary.appendingPathComponent(
            CatalogV4Migration.temporaryWorkspaceDirectoryPrefix
                + "\(Int32.max)-\(UUID().uuidString)",
            isDirectory: true
        )
        let liveOwner = temporary.appendingPathComponent(
            CatalogV4Migration.temporaryWorkspaceDirectoryPrefix
                + "\(getppid())-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: deadOwner)
            try? FileManager.default.removeItem(at: liveOwner)
        }
        try FileManager.default.createDirectory(at: deadOwner, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: liveOwner, withIntermediateDirectories: false)

        CatalogV4Migration.cleanupStaleTemporaryWorkspaces()

        #expect(!FileManager.default.fileExists(atPath: deadOwner.path))
        #expect(FileManager.default.fileExists(atPath: liveOwner.path))
    }

    @Test func pointedGenerationWithoutCatalogFailsWithoutCreatingOne() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Legacy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            remove(roots)
        }

        let generationID = UUID()
        let generation = generationURL(generationID, in: roots.app)
        try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
        let pointer = roots.app.appendingPathComponent("CurrentLibrary.json")
        let pointerData = Data("""
        { "schemaVersion": 1, "generationID": "\(generationID.uuidString)" }
        """.utf8)
        try pointerData.write(to: pointer)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            let preservedPointer = try Data(contentsOf: pointer)
            #expect(result.failure != nil)
            #expect(preservedPointer == pointerData)
            #expect(!FileManager.default.fileExists(atPath: catalogURL(in: generation).path))
            #expect(!FileManager.default.fileExists(
                atPath: completionMarkerURL(in: generation).path
            ))
        }
    }

    @Test func ambiguousRecoveryPreservesGenerationsAndPointer() throws {
        let first = makeRoots()
        let second = makeRoots()
        let target = makeRoots()
        defer {
            remove(first)
            remove(second)
            remove(target)
        }

        let firstID = try initializeFreshLibrary(first)
        let secondID = try initializeFreshLibrary(second)
        let targetLibraries = target.app.appendingPathComponent("Libraries", isDirectory: true)
        try FileManager.default.createDirectory(at: targetLibraries, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: generationURL(firstID, in: first.app),
            to: generationURL(firstID, in: target.app)
        )
        try FileManager.default.copyItem(
            at: generationURL(secondID, in: second.app),
            to: generationURL(secondID, in: target.app)
        )
        let pointer = target.app.appendingPathComponent("CurrentLibrary.json")
        let pointerData = Data("damaged pointer".utf8)
        try pointerData.write(to: pointer)

        try withConfiguredRoots(target) {
            let result = CatalogStore.makeContainer()
            let preservedPointer = try Data(contentsOf: pointer)
            #expect(result.failure != nil)
            #expect(preservedPointer == pointerData)
            #expect(FileManager.default.fileExists(
                atPath: generationURL(firstID, in: target.app).path
            ))
            #expect(FileManager.default.fileExists(
                atPath: generationURL(secondID, in: target.app).path
            ))
        }
    }

    @Test func invalidPointedCompletionDoesNotRollBackToOlderGeneration() throws {
        let roots = makeRoots()
        defer { remove(roots) }

        let olderGenerationID = try initializeFreshLibrary(roots)
        let pointedGenerationID = UUID()
        let pointedGeneration = generationURL(pointedGenerationID, in: roots.app)
        let pointedCatalog = catalogURL(in: pointedGeneration)
        try FileManager.default.createDirectory(
            at: pointedCatalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeCurrentCatalog(at: pointedCatalog)
        try Data("""
        { "schemaVersion": 1, "generationID": "\(UUID().uuidString)" }
        """.utf8).write(to: completionMarkerURL(in: pointedGeneration))

        let pointer = roots.app.appendingPathComponent("CurrentLibrary.json")
        let pointerData = Data("""
        { "schemaVersion": 1, "generationID": "\(pointedGenerationID.uuidString)" }
        """.utf8)
        try pointerData.write(to: pointer, options: .atomic)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(legacyStoreURL: nil)
            let preservedPointer = try Data(contentsOf: pointer)
            #expect(result.failure != nil)
            #expect(preservedPointer == pointerData)
        }
        #expect(FileManager.default.fileExists(
            atPath: generationURL(olderGenerationID, in: roots.app).path
        ))
        #expect(FileManager.default.fileExists(atPath: pointedGeneration.path))
    }

    @Test func recoveryRejectsZeroByteAndArbitraryCatalogFiles() throws {
        for invalidData in [Data(), Data("not a sqlite catalog".utf8)] {
            let roots = makeRoots()
            defer { remove(roots) }

            let generationID = UUID()
            let generation = generationURL(generationID, in: roots.app)
            try FileManager.default.createDirectory(
                at: catalogURL(in: generation).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let pointer = roots.app.appendingPathComponent("CurrentLibrary.json")
            try invalidData.write(to: catalogURL(in: generation))

            try withConfiguredRoots(roots) {
                let result = CatalogStore.makeContainer()
                let preservedCatalog = try Data(contentsOf: catalogURL(in: generation))
                #expect(result.failure != nil)
                #expect(!FileManager.default.fileExists(atPath: pointer.path))
                #expect(preservedCatalog == invalidData)
                #expect(FileManager.default.fileExists(atPath: generation.path))
            }
        }
    }

    @Test func failedRecoveryOpenDoesNotPublishPointer() throws {
        let roots = makeRoots()
        defer { remove(roots) }

        let generationID = UUID()
        let generation = generationURL(generationID, in: roots.app)
        let pointer = roots.app.appendingPathComponent("CurrentLibrary.json")
        let truncatedSQLite = Data("SQLite format 3\0".utf8)
        try FileManager.default.createDirectory(
            at: catalogURL(in: generation).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try truncatedSQLite.write(to: catalogURL(in: generation))
        try Data("""
        { "schemaVersion": 1, "generationID": "\(generationID.uuidString)" }
        """.utf8).write(to: completionMarkerURL(in: generation))

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            let preservedCatalog = try Data(contentsOf: catalogURL(in: generation))
            #expect(result.failure != nil)
            #expect(!FileManager.default.fileExists(atPath: pointer.path))
            #expect(preservedCatalog == truncatedSQLite)
            #expect(FileManager.default.fileExists(atPath: generation.path))
        }
    }

    @Test func freshCatalogStoreInitializationPublishesCompletionAndPointer() throws {
        let roots = makeRoots()
        defer { remove(roots) }

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)

            let generation = LibraryLocations.currentGeneration
            let catalog = LibraryLocations.catalogStoreURL
            let header = Data("SQLite format 3\0".utf8)
            #expect(try Data(contentsOf: catalog).starts(with: header))
            #expect(FileManager.default.fileExists(
                atPath: LibraryLocations.catalogCompletionMarkerURL.path
            ))
            let pointerData = try Data(
                contentsOf: roots.app.appendingPathComponent("CurrentLibrary.json")
            )
            #expect(String(decoding: pointerData, as: UTF8.self).contains(
                generation.lastPathComponent
            ))
        }
    }

    @Test func completedGenerationRecoversBeforePointerIsPublished() throws {
        let roots = makeRoots()
        defer { remove(roots) }

        let generationID = try initializeFreshLibrary(roots)
        let pointer = roots.app.appendingPathComponent("CurrentLibrary.json")
        try FileManager.default.removeItem(at: pointer)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            let pointerData = try Data(contentsOf: pointer)
            #expect(String(decoding: pointerData, as: UTF8.self).contains(
                generationID.uuidString
            ))
        }
    }

    @Test func schemaV1PointerWithoutCompletionMarkerRemainsCompatible() throws {
        let roots = makeRoots()
        defer { remove(roots) }

        let generationID = try initializeFreshLibrary(roots)
        let generation = generationURL(generationID, in: roots.app)
        let marker = completionMarkerURL(in: generation)
        try FileManager.default.removeItem(at: marker)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test func uniquePreMarkerV4GenerationRecoversWithoutPointer() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let generationID = UUID()
        let generation = generationURL(generationID, in: roots.app)
        let catalog = catalogURL(in: generation)
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: catalog)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
            let publishedGeneration = LibraryLocations.currentGeneration
            #expect(publishedGeneration.lastPathComponent != generationID.uuidString)
            #expect(try CatalogV4Migration.storeFormat(at: catalog) == .v4)
            #expect(FileManager.default.fileExists(
                atPath: completionMarkerURL(in: publishedGeneration).path
            ))
            #expect(FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
        }
    }

    @Test func multiplePreMarkerV4GenerationsFailClosed() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        for generationID in [UUID(), UUID()] {
            let catalog = catalogURL(in: generationURL(generationID, in: roots.app))
            try FileManager.default.createDirectory(
                at: catalog.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try writeV4Catalog(at: catalog)
        }

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure?.message.contains("Multiple library generations") == true)
            #expect(!FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
            let entries = try FileManager.default.contentsOfDirectory(
                at: roots.app.appendingPathComponent("Libraries"),
                includingPropertiesForKeys: nil
            )
            #expect(entries.count == 2)
        }
    }

    @Test func promotedCurrentCatalogRecoversWhenPublicationWasInterrupted() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let sourceGenerationID = UUID()
        let sourceGeneration = generationURL(sourceGenerationID, in: roots.app)
        let sourceCatalog = catalogURL(in: sourceGeneration)
        try FileManager.default.createDirectory(
            at: sourceCatalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: sourceCatalog)

        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        let targetGenerationID: UUID
        do {
            let preparation = try LibraryLocations.prepareCatalog()
            #expect(preparation.generationID == sourceGenerationID)
            let migration = try CatalogV4Migration.migrateStoreIfNeeded(preparation)
            targetGenerationID = migration.preparation.generationID
            #expect(targetGenerationID != sourceGenerationID)
            #expect(try CatalogV4Migration.storeFormat(at: sourceCatalog) == .v4)
            #expect(try CatalogV4Migration.storeFormat(
                at: migration.preparation.catalogURL
            ) == .current)
            #expect(!FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
            LibraryLocations.abandonCatalogOpen(migration.preparation)
        }
        LibraryLocations.resetConfiguredRoots()

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                == targetGenerationID.uuidString)
            #expect(try CatalogV4Migration.storeFormat(at: sourceCatalog) == .v4)
            #expect(FileManager.default.fileExists(
                atPath: completionMarkerURL(
                    in: generationURL(targetGenerationID, in: roots.app)
                ).path
            ))
            #expect(FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
        }
    }

    @Test func interruptedTargetIsRebuiltWhenItsSourceAdvances() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let sourceGenerationID = UUID()
        let sourceGeneration = generationURL(sourceGenerationID, in: roots.app)
        let sourceCatalog = catalogURL(in: sourceGeneration)
        try FileManager.default.createDirectory(
            at: sourceCatalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: sourceCatalog)

        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        let staleTargetGenerationID: UUID
        do {
            let source = try LibraryLocations.prepareCatalog()
            #expect(source.generationID == sourceGenerationID)
            let migration = try CatalogV4Migration.migrateStoreIfNeeded(source)
            staleTargetGenerationID = migration.preparation.generationID
            #expect(staleTargetGenerationID != sourceGenerationID)
            try Data("""
            { "schemaVersion": 1, "generationID": "\(staleTargetGenerationID.uuidString)" }
            """.utf8).write(
                to: completionMarkerURL(in: migration.preparation.generationURL)
            )
            LibraryLocations.abandonCatalogOpen(migration.preparation)
        }
        LibraryLocations.resetConfiguredRoots()

        try appendV4Asset(to: sourceCatalog)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(legacyStoreURL: nil)
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                != staleTargetGenerationID.uuidString)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 3)
        }

        let staleTarget = generationURL(staleTargetGenerationID, in: roots.app)
        #expect(FileManager.default.fileExists(atPath: staleTarget.path))
        #expect(FileManager.default.fileExists(
            atPath: staleTarget.appendingPathComponent(
                "CatalogMigration.abandoned.json"
            ).path
        ))
    }

    @Test func interruptedTargetDoesNotRepublishDeletedGenerationContent() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let sourceGenerationID = UUID()
        let sourceGeneration = generationURL(sourceGenerationID, in: roots.app)
        let sourceCatalog = catalogURL(in: sourceGeneration)
        let sourceState = sourceGeneration.appendingPathComponent("ExportState/state.json")
        try FileManager.default.createDirectory(
            at: sourceCatalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourceState.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: sourceCatalog)
        try Data("obsolete state".utf8).write(to: sourceState)

        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        let staleTargetGenerationID: UUID
        do {
            let source = try LibraryLocations.prepareCatalog()
            let migration = try CatalogV4Migration.migrateStoreIfNeeded(source)
            staleTargetGenerationID = migration.preparation.generationID
            LibraryLocations.abandonCatalogOpen(migration.preparation)
        }
        LibraryLocations.resetConfiguredRoots()
        try FileManager.default.removeItem(at: sourceState)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(legacyStoreURL: nil)
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                != staleTargetGenerationID.uuidString)
            #expect(!FileManager.default.fileExists(
                atPath: LibraryLocations.currentGeneration
                    .appendingPathComponent("ExportState/state.json").path
            ))
        }
    }

    @Test func interruptedLegacyTargetIsRebuiltWhenItsSourceAdvances() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Legacy-Interrupted-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { remove(roots) }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)
        let sourceGenerationID = try initializeFreshLibrary(roots)

        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        let staleTargetGenerationID: UUID
        do {
            let source = try LibraryLocations.prepareCatalog()
            #expect(source.generationID == sourceGenerationID)
            let migration = try CatalogV4Migration.migrateLegacyStore(
                at: legacy,
                legacyLibraryRoot: legacyDirectory,
                replacing: source
            )
            staleTargetGenerationID = migration.preparation.generationID
            LibraryLocations.abandonCatalogOpen(migration.preparation)
        }
        LibraryLocations.resetConfiguredRoots()

        try appendV4Asset(to: legacy)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                != staleTargetGenerationID.uuidString)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 3)
        }

        let staleTarget = generationURL(staleTargetGenerationID, in: roots.app)
        #expect(FileManager.default.fileExists(atPath: staleTarget.path))
        #expect(FileManager.default.fileExists(
            atPath: staleTarget.appendingPathComponent(
                "CatalogMigration.abandoned.json"
            ).path
        ))
    }

    @Test func interruptedFirstRunLegacyTargetRevalidatesBeforePublication() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Legacy-FirstRun-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { remove(roots) }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)

        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        let staleTargetGenerationID: UUID
        do {
            let target = try LibraryLocations.prepareCatalog()
            let migration = try CatalogV4Migration.migrateLegacyStore(
                at: legacy,
                legacyLibraryRoot: legacyDirectory,
                into: target
            )
            staleTargetGenerationID = migration.preparation.generationID
            try Data("""
            { "schemaVersion": 1, "generationID": "\(staleTargetGenerationID.uuidString)" }
            """.utf8).write(
                to: completionMarkerURL(in: migration.preparation.generationURL)
            )
            LibraryLocations.abandonCatalogOpen(migration.preparation)
        }
        LibraryLocations.resetConfiguredRoots()

        try appendV4Asset(to: legacy)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                != staleTargetGenerationID.uuidString)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 3)
        }
    }

    @Test func validatedCurrentCatalogRecoversBeforeItsMigrationMarkerIsWritten() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let migration = try completedV4Migration(in: roots)
        let pointer = roots.app.appendingPathComponent("CurrentLibrary.json")
        let currentMarker = migration.generation
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("CatalogMigration.json")
        try FileManager.default.removeItem(at: pointer)
        try FileManager.default.removeItem(at: completionMarkerURL(in: migration.generation))
        try FileManager.default.removeItem(at: currentMarker)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.path == migration.generation.path)
            #expect(FileManager.default.fileExists(atPath: currentMarker.path))
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
        }
    }

    @Test func modifiedRetainedBackupIsNotPromoted() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let migration = try completedV4Migration(in: roots)
        let backupStore = migration.backup.appendingPathComponent("catalog.store")
        try modifySQLiteUserVersion(at: backupStore)
        #expect(!FileManager.default.fileExists(atPath: backupStore.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: backupStore.path + "-shm"))
        try detachCatalog(in: migration.generation)
        try FileManager.default.removeItem(
            at: roots.app.appendingPathComponent("CurrentLibrary.json")
        )

        withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure?.message.contains("recorded identity") == true)
            #expect(!FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
        }
    }

    @Test func retainedBackupWithSQLiteSidecarIsNotPromoted() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let migration = try completedV4Migration(in: roots)
        let backupStore = migration.backup.appendingPathComponent("catalog.store")
        try Data().write(to: URL(fileURLWithPath: backupStore.path + "-wal"))
        try detachCatalog(in: migration.generation)
        try FileManager.default.removeItem(
            at: roots.app.appendingPathComponent("CurrentLibrary.json")
        )

        withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure?.message.contains("SQLite sidecar state") == true)
            #expect(!FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
        }
    }

    @Test func snapshotOnlyMigrationTargetIsRetainedWithoutTouchingSource() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let sourceGenerationID = UUID()
        let sourceGeneration = generationURL(sourceGenerationID, in: roots.app)
        let sourceCatalog = catalogURL(in: sourceGeneration)
        try FileManager.default.createDirectory(
            at: sourceCatalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: sourceCatalog)
        let snapshotFixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-V4Snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: snapshotFixtureDirectory,
            withIntermediateDirectories: true
        )
        let snapshotFixture = snapshotFixtureDirectory.appendingPathComponent("catalog.store")
        try writeSQLiteSnapshot(from: sourceCatalog, to: snapshotFixture)
        let sourceManifest = try byteManifest(of: sourceGeneration)

        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        let partialTarget: URL
        let partialBackup: URL
        do {
            let source = try LibraryLocations.prepareCatalog()
            let target = try LibraryLocations.prepareMigrationTarget(from: source)
            partialTarget = target.generationURL
            let migrationID = UUID()
            partialBackup = target.generationURL.appendingPathComponent(
                CatalogV4Migration.backupDirectoryPrefix + migrationID.uuidString,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: partialBackup,
                withIntermediateDirectories: false
            )
            let snapshotStore = partialBackup.appendingPathComponent("catalog.store")
            let snapshotData = try Data(contentsOf: snapshotFixture)
            do {
                let configuration = ModelConfiguration(
                    schema: CatalogSchemaV4.schema,
                    url: snapshotFixture,
                    allowsSave: true,
                    cloudKitDatabase: .none
                )
                let container = try ModelContainer(
                    for: CatalogSchemaV4.schema,
                    configurations: [configuration]
                )
                let context = ModelContext(container)
                #expect(try context.fetchCount(
                    FetchDescriptor<CatalogSchemaV4.ImageAsset>()
                ) == 2)
            }
            try snapshotData.write(to: snapshotStore)
            let snapshotHash = SHA256.hash(data: snapshotData)
                .map { String(format: "%02x", $0) }
                .joined()
            try Data("""
            {
              "schemaVersion": 1,
              "migrationID": "\(migrationID.uuidString)",
              "generationID": "\(target.generationID.uuidString)",
              "sourceIdentity": {
                "schemaVersion": 4,
                "sha256": "\(snapshotHash)",
                "byteCount": \(snapshotData.count)
              },
              "role": "v4Backup",
              "sourceKind": "generation"
            }
            """.utf8).write(to: partialBackup.appendingPathComponent("CatalogMigration.json"))
            LibraryLocations.abandonCatalogOpen(target)
        }
        LibraryLocations.resetConfiguredRoots()

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            let publishedGeneration = LibraryLocations.currentGeneration
            #expect(publishedGeneration.path != sourceGeneration.path)
            #expect(publishedGeneration.path != partialTarget.path)
            let migratedSourceManifest = try byteManifest(of: sourceGeneration)
            #expect(migratedSourceManifest == sourceManifest)
            #expect(FileManager.default.fileExists(atPath: partialBackup.path))
            #expect(FileManager.default.fileExists(atPath: partialTarget.path))
            #expect(FileManager.default.fileExists(
                atPath: partialTarget.appendingPathComponent(
                    "CatalogMigration.abandoned.json"
                ).path
            ))
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
        }
    }

    @Test func interruptedFreshGenerationResumesOnlyWithCreationMarker() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        let generationID: UUID
        do {
            let preparation = try LibraryLocations.prepareCatalog()
            generationID = preparation.generationID
            #expect(preparation.allowsCatalogCreation)
            #expect(FileManager.default.fileExists(
                atPath: preparation.generationURL
                    .appendingPathComponent("CatalogCreation.pending.json").path
            ))
        }
        LibraryLocations.resetConfiguredRoots()

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent == generationID.uuidString)
            #expect(!FileManager.default.fileExists(
                atPath: generationURL(generationID, in: roots.app)
                    .appendingPathComponent("CatalogCreation.pending.json").path
            ))
        }
    }

    @Test func markerlessCurrentStoreWithoutCreationIntentIsNotSelected() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let generationID = UUID()
        let catalog = catalogURL(in: generationURL(generationID, in: roots.app))
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeCurrentCatalog(at: catalog)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure != nil)
            #expect(!FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
            let libraries = try FileManager.default.contentsOfDirectory(
                at: roots.app.appendingPathComponent("Libraries"),
                includingPropertiesForKeys: nil
            )
            #expect(libraries.map(\.lastPathComponent) == [generationID.uuidString])
        }
    }

    @Test func schemaV4CatalogMigratesSideBySideAndRefetchesCurrentModels() throws {
        let roots = makeRoots()
        defer { remove(roots) }

        let generationID = UUID()
        let generation = generationURL(generationID, in: roots.app)
        let catalog = catalogURL(in: generation)
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fixture = try writeV4Catalog(at: catalog)
        let recipe = generation
            .appendingPathComponent("Recipes", isDirectory: true)
            .appendingPathComponent("preserved.rawlight.json")
        let customOwnedFile = generation
            .appendingPathComponent("ExportState", isDirectory: true)
            .appendingPathComponent("state.json")
        try FileManager.default.createDirectory(
            at: recipe.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: customOwnedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let recipeData = Data("preserved recipe".utf8)
        let customOwnedData = Data("preserved owned state".utf8)
        try recipeData.write(to: recipe)
        try customOwnedData.write(to: customOwnedFile)
        let pointer = roots.app.appendingPathComponent("CurrentLibrary.json")
        try Data("""
        { "schemaVersion": 1, "generationID": "\(generationID.uuidString)" }
        """.utf8).write(to: pointer)
        #expect(try CatalogV4Migration.probeStore(at: catalog).format == .v4)
        let sourceManifest = try byteManifest(of: generation)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            let publishedGeneration = LibraryLocations.currentGeneration
            #expect(publishedGeneration.standardizedFileURL.path != generation.path)
            let migratedSourceManifest = try byteManifest(of: generation)
            #expect(migratedSourceManifest == sourceManifest)
            #expect(try CatalogV4Migration.storeFormat(at: catalog) == .v4)
            #expect(try Data(contentsOf: recipe) == recipeData)
            #expect(try Data(contentsOf: customOwnedFile) == customOwnedData)
            #expect(try Data(contentsOf: publishedGeneration
                .appendingPathComponent("Recipes/preserved.rawlight.json")) == recipeData)
            #expect(try Data(contentsOf: publishedGeneration
                .appendingPathComponent("ExportState/state.json")) == customOwnedData)

            let context = ModelContext(result.container)
            let assets = try context.fetch(FetchDescriptor<ImageAsset>())
            let folders = try context.fetch(FetchDescriptor<LibraryFolder>())
            let collections = try context.fetch(FetchDescriptor<AssetCollection>())
            #expect(assets.count == 2)
            #expect(folders.count == 2)
            #expect(collections.count == 2)

            let first = try #require(assets.first { $0.id == fixture.firstAssetID })
            let second = try #require(assets.first { $0.id == fixture.secondAssetID })
            #expect(first.originalFilename == "DSCF0001.RAF")
            #expect(first.storageMode == .managed)
            #expect(first.managedRelativePath == "Originals/\(first.id.uuidString)/primary.raf")
            #expect(first.contentDigest == fixture.managedContentDigest)
            #expect(first.cameraMake == "Fujifilm")
            #expect(first.cameraModel == "X-T5")
            #expect(first.lensModel == "XF33mmF1.4 R LM WR")
            #expect(first.isoValue == 640)
            #expect(first.pixelWidth == 7728)
            #expect(first.pixelHeight == 5152)
            #expect(first.rating == 5)
            #expect(first.flagRaw == PickFlag.picked.rawValue)
            #expect(first.colorLabel == 3)
            #expect(first.folder?.id == fixture.externalFolderID)
            #expect(Set(first.collections.map(\.id)) == [
                fixture.picksCollectionID,
                fixture.portfolioCollectionID,
            ])

            #expect(second.storageMode == .referenced)
            #expect(second.bookmarkData == fixture.assetBookmark)
            #expect(second.isMissing)
            #expect(second.folder == nil)
            #expect(Set(second.collections.map(\.id)) == [fixture.picksCollectionID])

            #expect(first.develop.schemaVersion == DevelopSettings.currentSchemaVersion)
            #expect(first.develop.temperature == 0.21)
            #expect(first.develop.exposure == 0.73)
            #expect(first.develop.highlights == -0.31)
            #expect(first.develop.toneCurve[1] == CurvePoint(0.4, 0.57))
            #expect(first.develop.colorMix.hue[2] == 0.18)
            #expect(first.develop.grade.midSat == 0.42)
            #expect(first.develop.sharpness == 0.64)
            #expect(first.develop.cropW == 0.81)
            #expect(first.develop.rotationQuarterTurns == 3)

            let neutral = DevelopSettings()
            #expect(first.develop.profileAmount == neutral.profileAmount)
            #expect(first.develop.curveSplitMid == neutral.curveSplitMid)
            #expect(first.develop.sharpenDetail == neutral.sharpenDetail)
            #expect(first.develop.opticsProfileDistortion == neutral.opticsProfileDistortion)
            #expect(first.develop.geometryScale == neutral.geometryScale)
            #expect(first.develop.pointColors.isEmpty)
            #expect(first.develop.masks.isEmpty)

            let externalFolder = try #require(
                folders.first { $0.id == fixture.externalFolderID }
            )
            #expect(externalFolder.bookmarkData == fixture.folderBookmark)
            #expect(Set(externalFolder.assets.map(\.id)) == [fixture.firstAssetID])
            let picks = try #require(
                collections.first { $0.id == fixture.picksCollectionID }
            )
            #expect(Set(picks.assets.map(\.id)) == [
                fixture.firstAssetID,
                fixture.secondAssetID,
            ])

            #expect(FileManager.default.fileExists(
                atPath: completionMarkerURL(in: publishedGeneration).path
            ))
            let generationEntries = try FileManager.default.contentsOfDirectory(
                at: publishedGeneration,
                includingPropertiesForKeys: nil
            )
            let backup = try #require(generationEntries.first {
                $0.lastPathComponent.hasPrefix(CatalogV4Migration.backupDirectoryPrefix)
            })
            let backupStore = backup.appendingPathComponent("catalog.store")
            #expect(try CatalogV4Migration.storeFormat(at: backupStore) == .v4)
            #expect(!FileManager.default.fileExists(atPath: backupStore.path + "-wal"))
            #expect(!FileManager.default.fileExists(atPath: backupStore.path + "-shm"))
            #expect(!generationEntries.contains {
                $0.lastPathComponent.hasPrefix("Catalog.migrating-")
            })
        }
    }

    @Test func interruptedMigrationBackupIsAutomaticallyRecovered() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let sourceGenerationID = UUID()
        let sourceGeneration = generationURL(sourceGenerationID, in: roots.app)
        let sourceCatalog = catalogURL(in: sourceGeneration)
        try FileManager.default.createDirectory(
            at: sourceCatalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: sourceCatalog)
        let publishedGenerationID: UUID = try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            return try #require(UUID(
                uuidString: LibraryLocations.currentGeneration.lastPathComponent
            ))
        }

        let publishedGeneration = generationURL(publishedGenerationID, in: roots.app)
        let backup = try migrationBackup(in: publishedGeneration)
        try FileManager.default.removeItem(
            at: roots.app.appendingPathComponent("CurrentLibrary.json")
        )

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                == publishedGenerationID.uuidString)
            #expect(try CatalogV4Migration.storeFormat(at: sourceCatalog) == .v4)
            #expect(FileManager.default.fileExists(atPath: backup.path))
            #expect(try CatalogV4Migration.storeFormat(
                at: backup.appendingPathComponent("catalog.store")
            ) == .v4)
        }
    }

    @Test func migrationFailurePreservesOldPointerAndGeneration() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let generationID = UUID()
        let generation = generationURL(generationID, in: roots.app)
        let catalog = catalogURL(in: generation)
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: catalog)
        let pointer = roots.app.appendingPathComponent("CurrentLibrary.json")
        let pointerData = Data("""
        { "schemaVersion": 1, "generationID": "\(generationID.uuidString)" }
        """.utf8)
        try pointerData.write(to: pointer)

        var database: OpaquePointer?
        try #require(sqlite3_open_v2(
            catalog.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK)
        try #require(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer {
            if let database {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                sqlite3_close(database)
            }
        }
        let sourceManifest = try byteManifest(of: generation)

        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        defer { LibraryLocations.resetConfiguredRoots() }
        do {
            let result = CatalogStore.makeContainer()
            #expect(result.failure?.message.contains("exclusively coordinated") == true)
            #expect((try? Data(contentsOf: pointer)) == pointerData)
            #expect((try? CatalogV4Migration.storeFormat(at: catalog)) == .v4)
            #expect((try? byteManifest(of: generation)) == sourceManifest)
        }
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        sqlite3_close(database)
        database = nil

        do {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                != generationID.uuidString)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
        }
    }

    @Test func generationLeaseAndSQLiteWriterContentionFailClosed() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        var heldPreparation: LibraryLocations.CatalogPreparation? = try LibraryLocations.prepareCatalog()
        #expect(heldPreparation?.generationID != nil)
        let lockFailure = CatalogStore.makeContainer(legacyStoreURL: nil)
        #expect(lockFailure.failure?.message.contains("Another RawLight process") == true)
        heldPreparation = nil
        LibraryLocations.resetConfiguredRoots()

        let sourceDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-LockedV4-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: source, legacyLibraryRoot: sourceDirectory)
        var database: OpaquePointer?
        try #require(sqlite3_open_v2(
            source.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK)
        try #require(sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer {
            if let database {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                sqlite3_close(database)
            }
        }

        let migrationRoots = makeRoots()
        defer { remove(migrationRoots) }
        withConfiguredRoots(migrationRoots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: source,
                legacyLibraryRoot: sourceDirectory
            )
            #expect(result.failure?.message.contains("exclusively coordinated") == true)
            #expect(!FileManager.default.fileExists(
                atPath: migrationRoots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
            #expect(!FileManager.default.fileExists(
                atPath: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL.path
            ))
        }
        sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
        sqlite3_close(database)
        database = nil
        try withConfiguredRoots(migrationRoots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: source,
                legacyLibraryRoot: sourceDirectory
            )
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
            #expect(FileManager.default.fileExists(
                atPath: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL.path
            ))
        }
    }

    @Test func successfulCatalogSessionRetainsGenerationLease() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        defer { LibraryLocations.resetConfiguredRoots() }

        var first: CatalogStore.LoadResult? = CatalogStore.makeContainer(legacyStoreURL: nil)
        try #require(first?.failure == nil)
        let competing = CatalogStore.makeContainer(legacyStoreURL: nil)
        #expect(competing.failure?.message.contains("Another RawLight process") == true)

        first = nil
        let reopened = CatalogStore.makeContainer(legacyStoreURL: nil)
        #expect(reopened.failure == nil)
    }

    @Test func migrationRetainsOnlySourceHandleForCatalogSession() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let generationID = UUID()
        let generation = generationURL(generationID, in: roots.app)
        let catalog = catalogURL(in: generation)
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: catalog)
        try Data("""
        { "schemaVersion": 1, "generationID": "\(generationID.uuidString)" }
        """.utf8).write(to: roots.app.appendingPathComponent("CurrentLibrary.json"))

        CatalogV4Migration.resetPromotionObservationForTesting()
        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            #expect(CatalogV4Migration.promotionObservationCountForTesting == 1)
            #expect(CatalogV4Migration.openSQLiteHandleCountForTesting == 1)

            var writer: OpaquePointer?
            try #require(sqlite3_open_v2(
                catalog.path,
                &writer,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK)
            defer { if let writer { sqlite3_close(writer) } }
            let writeResult = sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil)
            #expect(writeResult == SQLITE_BUSY || writeResult == SQLITE_LOCKED)
        }
        #expect(CatalogV4Migration.openSQLiteHandleCountForTesting == 0)
    }

    @Test func legacyMigrationPreservesManagedOriginalSidecarAndReferencedAsset() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-LegacyFiles-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            remove(roots)
        }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyStore = legacyDirectory.appendingPathComponent("default.store")
        let fixture = try writeV4Catalog(
            at: legacyStore,
            legacyLibraryRoot: legacyDirectory
        )
        let sourceOriginal = legacyDirectory.appendingPathComponent(fixture.managedRelativePath)
        let sourceSidecar = SidecarService.sidecarURL(for: sourceOriginal)
        let expectedSidecar = try #require(fixture.managedSidecarData)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacyStore,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            let assets = try context.fetch(FetchDescriptor<ImageAsset>())
            let managed = try #require(assets.first { $0.id == fixture.firstAssetID })
            let referenced = try #require(assets.first { $0.id == fixture.secondAssetID })
            let expectedPath = "Originals/\(fixture.firstAssetID.uuidString)/primary.raf"
            #expect(managed.managedRelativePath == expectedPath)
            #expect(referenced.storageMode == .referenced)
            #expect(referenced.bookmarkData == fixture.assetBookmark)
            #expect(referenced.managedRelativePath == nil)

            let accessedData = try AssetFileAccess.withAccess(managed) {
                try Data(contentsOf: $0)
            }
            #expect(accessedData == fixture.managedOriginalData)
            let targetOriginal = LibraryLocations.currentGeneration
                .appendingPathComponent(expectedPath)
            #expect(try Data(contentsOf: targetOriginal) == fixture.managedOriginalData)
            #expect(
                try Data(contentsOf: SidecarService.sidecarURL(for: targetOriginal))
                    == expectedSidecar
            )
            #expect(try Data(contentsOf: sourceOriginal) == fixture.managedOriginalData)
            #expect(try Data(contentsOf: sourceSidecar) == expectedSidecar)
            var editedDevelop = managed.develop
            editedDevelop.profileAmount = 0.37
            managed.develop = editedDevelop
            try context.save()
        }
        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacyStore,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            let managed = try #require(try context.fetch(FetchDescriptor<ImageAsset>()).first {
                $0.id == fixture.firstAssetID
            })
            #expect(managed.develop.profileAmount == 0.37)
        }
    }

    @Test func legacyMigrationRecoversFromBackupOnlyWithManagedPathMetadata() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-LegacyBackup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { remove(roots) }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyStore = legacyDirectory.appendingPathComponent("default.store")
        let fixture = try writeV4Catalog(
            at: legacyStore,
            legacyLibraryRoot: legacyDirectory
        )
        let firstGenerationID: UUID = try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacyStore,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            return try #require(UUID(
                uuidString: LibraryLocations.currentGeneration.lastPathComponent
            ))
        }
        let firstGeneration = generationURL(firstGenerationID, in: roots.app)
        let backup = try migrationBackup(in: firstGeneration)
        let backupStore = backup.appendingPathComponent("catalog.store")
        #expect(!FileManager.default.fileExists(atPath: backupStore.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: backupStore.path + "-shm"))
        try detachCatalog(in: firstGeneration)
        try FileManager.default.removeItem(
            at: roots.app.appendingPathComponent("CurrentLibrary.json")
        )

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacyStore,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            let managed = try #require(try context.fetch(FetchDescriptor<ImageAsset>()).first {
                $0.id == fixture.firstAssetID
            })
            let expectedPath = "Originals/\(fixture.firstAssetID.uuidString)/primary.raf"
            #expect(managed.managedRelativePath == expectedPath)
            #expect(try Data(contentsOf: LibraryLocations.currentGeneration
                .appendingPathComponent(expectedPath)) == fixture.managedOriginalData)
            #expect(FileManager.default.fileExists(atPath: backup.path))
            #expect(FileManager.default.fileExists(
                atPath: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL.path
            ))
        }
    }

    @Test func legacyMigrationRejectsMissingAndSymlinkedManagedOriginals() throws {
        for useSymlink in [false, true] {
            let roots = makeRoots()
            let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "RawLight-UnsafeLegacy-\(UUID().uuidString)",
                isDirectory: true
            )
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
                "RawLight-OutsideManaged-\(UUID().uuidString).RAF"
            )
            defer {
                remove(roots)
                try? FileManager.default.removeItem(at: outside)
            }
            try FileManager.default.createDirectory(
                at: legacyDirectory,
                withIntermediateDirectories: true
            )
            let legacyStore = legacyDirectory.appendingPathComponent("default.store")
            let fixture = try writeV4Catalog(
                at: legacyStore,
                legacyLibraryRoot: legacyDirectory
            )
            let original = legacyDirectory.appendingPathComponent(fixture.managedRelativePath)
            try FileManager.default.removeItem(at: original)
            if useSymlink {
                try fixture.managedOriginalData.write(to: outside)
                try FileManager.default.createSymbolicLink(
                    at: original,
                    withDestinationURL: outside
                )
            }

            withConfiguredRoots(roots) {
                let result = CatalogStore.makeContainer(
                    legacyStoreURL: legacyStore,
                    legacyLibraryRoot: legacyDirectory
                )
                #expect(result.failure != nil)
                #expect(!FileManager.default.fileExists(
                    atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
                ))
                #expect(CatalogV4Migration.openSQLiteHandleCountForTesting == 0)
            }
            #expect(try CatalogV4Migration.probeStore(at: legacyStore).format == .v4)
            #expect(try CatalogV4Migration.probeStore(at: legacyStore).assetCount == 2)
        }
    }

    @Test func authoritativeCurrentLeavesRetainedV4SnapshotUntouched() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let migration = try completedV4Migration(in: roots)
        let backup = migration.backup
        let backupStore = backup.appendingPathComponent("catalog.store")
        let before = try ContentDigest.sha256(of: backupStore)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
            #expect(FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
        }
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try ContentDigest.sha256(of: backupStore) == before)
        #expect(try CatalogV4Migration.storeFormat(at: backupStore) == .v4)
    }

    @Test func authoritativeCurrentQuarantinesBackupWithMalformedMarker() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let migration = try completedV4Migration(in: roots)
        let marker = migration.backup.appendingPathComponent("CatalogMigration.json")
        try Data("{ malformed marker".utf8).write(to: marker, options: .atomic)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
        }
        #expect(FileManager.default.fileExists(atPath: migration.backup.path))
        #expect(hasArtifactQuarantine(in: migration.generation))
    }

    @Test func authoritativeCurrentQuarantinesBackupWithMismatchedMarker() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let migration = try completedV4Migration(in: roots)
        let marker = migration.backup.appendingPathComponent("CatalogMigration.json")
        let markerData = try Data(contentsOf: marker)
        var payload = try #require(
            try JSONSerialization.jsonObject(with: markerData) as? [String: Any]
        )
        payload["generationID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: marker, options: .atomic)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
        }
        #expect(FileManager.default.fileExists(atPath: migration.backup.path))
        #expect(hasArtifactQuarantine(in: migration.generation))
    }

    @Test func authoritativeCurrentStillRejectsMalformedStaging() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let migration = try completedV4Migration(in: roots)
        let staging = migration.generation.appendingPathComponent(
            CatalogV4Migration.stagingDirectoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        try Data("{ malformed marker".utf8).write(
            to: staging.appendingPathComponent("CatalogMigration.json")
        )

        withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure != nil)
        }
        #expect(FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: migration.backup.path))
        #expect(!hasArtifactQuarantine(in: migration.generation))
    }

    @Test func neededBackupWithMalformedMarkerFailsClosed() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let sourceGenerationID = UUID()
        let sourceGeneration = generationURL(sourceGenerationID, in: roots.app)
        let catalog = catalogURL(in: sourceGeneration)
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: catalog)
        let targetGeneration: URL = try withConfiguredRoots(roots) {
            let preparation = try LibraryLocations.prepareCatalog()
            let migration = try CatalogV4Migration.migrateStoreIfNeeded(preparation)
            LibraryLocations.abandonCatalogOpen(migration.preparation)
            return migration.preparation.generationURL
        }
        let backup = try migrationBackup(in: targetGeneration)
        let marker = backup.appendingPathComponent("CatalogMigration.json")
        let malformedMarker = Data("{ malformed marker".utf8)
        try malformedMarker.write(to: marker, options: .atomic)

        withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure != nil)
            #expect(!FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
        }
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: marker) == malformedMarker)
        #expect(!hasArtifactQuarantine(in: targetGeneration))
        #expect(try CatalogV4Migration.storeFormat(at: catalog) == .v4)
    }

    @Test func interruptedPublicationWithMalformedTargetMetadataFailsClosed() throws {
        let roots = makeRoots()
        defer { remove(roots) }
        let sourceGenerationID = UUID()
        let sourceGeneration = generationURL(sourceGenerationID, in: roots.app)
        let catalog = catalogURL(in: sourceGeneration)
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: catalog)

        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        let targetGeneration: URL
        do {
            let preparation = try LibraryLocations.prepareCatalog()
            let migration = try CatalogV4Migration.migrateStoreIfNeeded(preparation)
            targetGeneration = migration.preparation.generationURL
            LibraryLocations.abandonCatalogOpen(migration.preparation)
        }
        LibraryLocations.resetConfiguredRoots()
        let backup = try migrationBackup(in: targetGeneration)
        let targetMarker = targetGeneration
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("CatalogMigration.json")
        let malformedMarker = Data("{ malformed target marker".utf8)
        try malformedMarker.write(
            to: targetMarker,
            options: .atomic
        )

        withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure != nil)
            #expect(!FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
        }
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: targetMarker) == malformedMarker)
        #expect(try CatalogV4Migration.storeFormat(at: catalog) == .v4)
    }

    @Test func catalogMetadataReadsRejectOversizeFIFOAndSymlink() throws {
        let oversizedRoots = makeRoots()
        defer { remove(oversizedRoots) }
        try FileManager.default.createDirectory(
            at: oversizedRoots.app,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x20, count: 16 * 1024 + 1).write(
            to: oversizedRoots.app.appendingPathComponent("CurrentLibrary.json")
        )
        withConfiguredRoots(oversizedRoots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure?.message.contains("exceeds the supported size") == true)
        }

        let fifoRoots = makeRoots()
        defer { remove(fifoRoots) }
        let generationID = UUID()
        let generation = generationURL(generationID, in: fifoRoots.app)
        let catalog = catalogURL(in: generation)
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeCurrentCatalog(at: catalog)
        try FileManager.default.createDirectory(at: fifoRoots.app, withIntermediateDirectories: true)
        try Data("""
        { "schemaVersion": 1, "generationID": "\(generationID.uuidString)" }
        """.utf8).write(to: fifoRoots.app.appendingPathComponent("CurrentLibrary.json"))
        let completionFIFO = completionMarkerURL(in: generation)
        let fifoResult = completionFIFO.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return mkfifo(path, 0o600)
        }
        try #require(fifoResult == 0)
        withConfiguredRoots(fifoRoots) {
            let result = CatalogStore.makeContainer()
            #expect(result.failure?.message.contains("bounded regular file") == true)
        }

        let markerRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Marker-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: markerRoot) }
        try FileManager.default.createDirectory(at: markerRoot, withIntermediateDirectories: true)
        let target = markerRoot.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let marker = markerRoot.appendingPathComponent("LegacyCatalogMigration.json")
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
        let identity = CatalogV4Migration.SourceIdentity(
            schemaVersion: 4,
            sha256: String(repeating: "0", count: 64),
            byteCount: 0
        )
        #expect(throws: (any Error).self) {
            try LibraryLocations.legacyMigrationCompletionMatches(
                at: marker,
                sourceIdentity: identity,
                targetGenerationID: UUID()
            )
        }
    }

    @Test func v4CompositeDecoderDefaultsMissingKeysAndNormalizesValues() throws {
        let data = Data("""
        {
          "schemaVersion": 2,
          "exposure": 9,
          "colorMix": { "hue": [2, -2] },
          "grade": { "midSat": 0.5 },
          "cropW": 0,
          "rotationQuarterTurns": -1
        }
        """.utf8)
        let settings = try JSONDecoder().decode(
            CatalogSchemaV4.DevelopSettings.self,
            from: data
        )
        #expect(settings.schemaVersion == 4)
        #expect(settings.exposure == 1)
        #expect(settings.temperature == 0)
        #expect(settings.colorMix.hue == [1, -1, 0, 0, 0, 0, 0, 0])
        #expect(settings.colorMix.saturation == Array(repeating: 0, count: 8))
        #expect(settings.grade.midSat == 0.5)
        #expect(settings.cropW == 0.01)
        #expect(settings.rotationQuarterTurns == 3)
    }

    @Test func preGenerationDefaultCatalogMigratesFromReleasedSchema() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-PreGeneration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { remove(roots) }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacyStore = legacyDirectory.appendingPathComponent("default.store")
        let assetID = try writeV1Catalog(at: legacyStore)
        #expect(try CatalogV4Migration.storeFormat(at: legacyStore) == .v1)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacyStore,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            let asset = try #require(try context.fetch(FetchDescriptor<ImageAsset>()).first {
                $0.id == assetID
            })
            #expect(asset.originalFilename == "PREGEN_0001.RAW")
            #expect(asset.storageMode == .referenced)
            #expect(asset.rating == 4)
            #expect(asset.develop.exposure == 0.42)
            #expect(asset.develop.temperature == -0.18)
            #expect(asset.develop.profileAmount == DevelopSettings().profileAmount)
            #expect(FileManager.default.fileExists(
                atPath: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL.path
            ))
        }
        #expect(try CatalogV4Migration.storeFormat(at: legacyStore) == .v1)
    }

    @Test func populatedLegacyStoreTakesPrecedenceOverEmptyActiveGeneration() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Legacy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { remove(roots) }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)
        let activeGeneration = try initializeFreshLibrary(roots)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent != activeGeneration.uuidString)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
            #expect(FileManager.default.fileExists(
                atPath: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL.path
            ))
        }
        #expect(try CatalogV4Migration.probeStore(at: legacy).assetCount == 2)
    }

    @Test func completedLegacyMigrationIsNotRepeatedAfterCatalogIsEmptied() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Legacy-OneTime-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { remove(roots) }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)

        let migratedGenerationID: UUID = try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            for asset in try context.fetch(FetchDescriptor<ImageAsset>()) {
                context.delete(asset)
            }
            for folder in try context.fetch(FetchDescriptor<LibraryFolder>()) {
                context.delete(folder)
            }
            for collection in try context.fetch(FetchDescriptor<AssetCollection>()) {
                context.delete(collection)
            }
            try context.save()
            #expect(try CatalogV4Migration.probeStore(at: LibraryLocations.catalogStoreURL).isEmpty)
            return try #require(UUID(
                uuidString: LibraryLocations.currentGeneration.lastPathComponent
            ))
        }

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                == migratedGenerationID.uuidString)
            #expect(try CatalogV4Migration.probeStore(
                at: LibraryLocations.catalogStoreURL
            ).isEmpty)
        }
        #expect(try CatalogV4Migration.probeStore(at: legacy).assetCount == 2)
    }

    @Test func completedLegacyMigrationIsNotRepeatedAfterActiveGenerationChanges() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Legacy-Durable-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { remove(roots) }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            #expect(FileManager.default.fileExists(
                atPath: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL.path
            ))
        }

        let replacementGenerationID = UUID()
        let replacementGeneration = generationURL(replacementGenerationID, in: roots.app)
        let replacementCatalog = catalogURL(in: replacementGeneration)
        try FileManager.default.createDirectory(
            at: replacementCatalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeCurrentCatalog(at: replacementCatalog)
        try Data("""
        { "schemaVersion": 1, "generationID": "\(replacementGenerationID.uuidString)" }
        """.utf8).write(to: completionMarkerURL(in: replacementGeneration))
        try Data("""
        { "schemaVersion": 1, "generationID": "\(replacementGenerationID.uuidString)" }
        """.utf8).write(
            to: roots.app.appendingPathComponent("CurrentLibrary.json"),
            options: .atomic
        )

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                == replacementGenerationID.uuidString)
            #expect(try CatalogV4Migration.probeStore(
                at: LibraryLocations.catalogStoreURL
            ).isEmpty)
        }
        #expect(try CatalogV4Migration.probeStore(at: legacy).assetCount == 2)
    }

    @Test func legacyStoreRecoversWhenItsRecordedTargetIsMissing() throws {
        let firstRoots = makeRoots()
        let restoredRoots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Legacy-Restore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            remove(firstRoots)
            remove(restoredRoots)
        }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)

        let markerData: Data = try withConfiguredRoots(firstRoots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            return try Data(
                contentsOf: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL
            )
        }
        try FileManager.default.createDirectory(
            at: restoredRoots.app,
            withIntermediateDirectories: true
        )
        try markerData.write(
            to: restoredRoots.app.appendingPathComponent("LegacyCatalogMigration.json")
        )

        try withConfiguredRoots(restoredRoots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
        }
    }

    @Test func nonemptyActiveGenerationTakesPrecedenceOverStaleLegacyStore() throws {
        let roots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-StaleLegacy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { remove(roots) }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)

        let activeGeneration: UUID = try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(legacyStoreURL: nil)
            try #require(result.failure == nil)
            let context = ModelContext(result.container)
            context.insert(ImageAsset(
                originalFilename: "ACTIVE.RAW",
                storageMode: .referenced,
                fingerprint: ImageFingerprint(
                    filename: "ACTIVE.RAW",
                    fileSizeBytes: 123
                ),
                fileSizeBytes: 123
            ))
            try context.save()
            return try #require(UUID(
                uuidString: LibraryLocations.currentGeneration.lastPathComponent
            ))
        }

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            #expect(LibraryLocations.currentGeneration.lastPathComponent
                == activeGeneration.uuidString)
            let context = ModelContext(result.container)
            let assets = try context.fetch(FetchDescriptor<ImageAsset>())
            #expect(assets.map(\.originalFilename) == ["ACTIVE.RAW"])
            #expect(!FileManager.default.fileExists(
                atPath: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL.path
            ))
        }
    }

    @Test func legacyMigrationMarkerBindsSourceIdentityAndTargetGeneration() throws {
        let firstRoots = makeRoots()
        let secondRoots = makeRoots()
        let legacyDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RawLight-Legacy-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            remove(firstRoots)
            remove(secondRoots)
        }
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let legacy = legacyDirectory.appendingPathComponent("default.store")
        _ = try writeV4Catalog(at: legacy, legacyLibraryRoot: legacyDirectory)

        let firstMarker: LegacyMigrationMarker = try withConfiguredRoots(firstRoots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            let markerURL = LibraryLocations.legacyCatalogMigrationCompletionMarkerURL
            let boundedMarker = try BoundedFileReader.readRegularFile(
                at: markerURL,
                maximumByteCount: 16 * 1024
            )
            let marker = try JSONDecoder().decode(
                LegacyMigrationMarker.self,
                from: try #require(boundedMarker)
            )
            #expect(marker.schemaVersion == 1)
            #expect(marker.targetGenerationID.uuidString == LibraryLocations.currentGeneration.lastPathComponent)
            #expect(try LibraryLocations.legacyMigrationCompletionMatches(
                at: markerURL,
                sourceIdentity: marker.sourceIdentity,
                targetGenerationID: marker.targetGenerationID
            ))
            return marker
        }

        #expect(try CatalogV4Migration.probeStore(at: legacy).assetCount == 2)
        try appendV4Asset(to: legacy)
        let secondMarker: LegacyMigrationMarker = try withConfiguredRoots(secondRoots) {
            let result = CatalogStore.makeContainer(
                legacyStoreURL: legacy,
                legacyLibraryRoot: legacyDirectory
            )
            try #require(result.failure == nil)
            let boundedMarker = try BoundedFileReader.readRegularFile(
                at: LibraryLocations.legacyCatalogMigrationCompletionMarkerURL,
                maximumByteCount: 16 * 1024
            )
            return try JSONDecoder().decode(
                LegacyMigrationMarker.self,
                from: try #require(boundedMarker)
            )
        }

        #expect(firstMarker.sourceIdentity != secondMarker.sourceIdentity)
        #expect(firstMarker.targetGenerationID != secondMarker.targetGenerationID)
        #expect(try !LibraryLocations.legacyMigrationCompletionMatches(
            at: firstRoots.app.appendingPathComponent("LegacyCatalogMigration.json"),
            sourceIdentity: secondMarker.sourceIdentity,
            targetGenerationID: firstMarker.targetGenerationID
        ))
    }

    @Test func librariesSymlinkEscapeIsRejected() throws {
        let roots = makeRoots()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-Outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            remove(roots)
            try? FileManager.default.removeItem(at: outside)
        }

        try FileManager.default.createDirectory(at: roots.app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: roots.app.appendingPathComponent("Libraries", isDirectory: true),
            withDestinationURL: outside
        )

        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            let outsideEntries = try FileManager.default.contentsOfDirectory(atPath: outside.path)
            #expect(result.failure != nil)
            #expect(!FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
            #expect(outsideEntries.isEmpty)
        }
    }

    @Test func configuredAppRootSymlinkSupportsStandardLayout() throws {
        let roots = makeRoots()
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLight-RootLink-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: link)
            remove(roots)
        }

        try FileManager.default.createDirectory(at: roots.app, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: roots.app)
        let linkedRoots = TestRoots(app: link, cache: roots.cache)

        try withConfiguredRoots(linkedRoots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            #expect(FileManager.default.fileExists(
                atPath: roots.app.appendingPathComponent("CurrentLibrary.json").path
            ))
            #expect(FileManager.default.fileExists(atPath: LibraryLocations.catalogStoreURL.path))
        }
        try withConfiguredRoots(linkedRoots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
        }
    }

    private func initializeFreshLibrary(_ roots: TestRoots) throws -> UUID {
        try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            return try #require(UUID(
                uuidString: LibraryLocations.currentGeneration.lastPathComponent
            ))
        }
    }

    private func writeV1Catalog(at url: URL) throws -> UUID {
        let configuration = ModelConfiguration(
            schema: CatalogSchemaV1.schema,
            url: url,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: CatalogSchemaV1.schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let folder = CatalogSchemaV1.LibraryFolder(
            name: "Original Release",
            kind: .external,
            sortIndex: 3
        )
        folder.bookmarkData = Data([0x10, 0x20])
        let collection = CatalogSchemaV1.AssetCollection(
            name: "Original Picks",
            symbol: "star",
            sortIndex: 2
        )
        let asset = CatalogSchemaV1.ImageAsset(
            originalFilename: "PREGEN_0001.RAW",
            storageMode: .referenced,
            fingerprintFilename: "PREGEN_0001.RAW",
            fingerprintSize: 42_001,
            fingerprintHeaderHash: "pre-generation",
            fileSizeBytes: 42_001
        )
        asset.bookmarkData = Data([0x30, 0x40])
        asset.rating = 4
        var develop = CatalogSchemaV1.DevelopSettings()
        develop.exposure = 0.42
        develop.temperature = -0.18
        develop.noiseReduction = 0.31
        asset.develop = develop
        asset.folder = folder
        asset.collections = [collection]
        context.insert(folder)
        context.insert(collection)
        context.insert(asset)
        try context.save()
        return asset.id
    }

    private func writeV4Catalog(
        at url: URL,
        legacyLibraryRoot: URL? = nil
    ) throws -> V4Fixture {
        let managedOriginalData = Data("released managed original".utf8)
        let managedHash = SHA256.hash(data: managedOriginalData)
            .map { String(format: "%02x", $0) }
            .joined()
        let managedContentDigest = "sha256:\(managedHash)"
        let configuration = ModelConfiguration(
            schema: ReleasedCatalogSchemaV4Fixture.schema,
            url: url,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: ReleasedCatalogSchemaV4Fixture.schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false

        let folderBookmark = Data([0x01, 0x23, 0x45, 0x67])
        let assetBookmark = Data([0x89, 0xab, 0xcd, 0xef])
        let createdAt = Date(timeIntervalSinceReferenceDate: 712_345_678)
        let captureDate = Date(timeIntervalSinceReferenceDate: 700_000_123)

        let externalFolder = ReleasedCatalogSchemaV4Fixture.LibraryFolder(
            name: "Travel RAWs",
            kind: .external,
            sortIndex: 7,
            createdAt: createdAt
        )
        externalFolder.bookmarkData = folderBookmark
        let managedFolder = ReleasedCatalogSchemaV4Fixture.LibraryFolder(
            name: "Managed",
            kind: .managed,
            sortIndex: 8,
            createdAt: createdAt.addingTimeInterval(1)
        )
        let picks = ReleasedCatalogSchemaV4Fixture.AssetCollection(
            name: "Picks",
            symbol: "star.fill",
            sortIndex: 2,
            createdAt: createdAt.addingTimeInterval(2)
        )
        let portfolio = ReleasedCatalogSchemaV4Fixture.AssetCollection(
            name: "Portfolio",
            symbol: "rectangle.stack.fill",
            sortIndex: 3,
            createdAt: createdAt.addingTimeInterval(3)
        )

        let first = ReleasedCatalogSchemaV4Fixture.ImageAsset(
            originalFilename: "DSCF0001.RAF",
            storageMode: .managed,
            fingerprintFilename: "DSCF0001.RAF",
            fingerprintSize: Int64(managedOriginalData.count),
            fingerprintCaptureDate: captureDate,
            fingerprintHeaderHash: "header-a",
            importedAt: createdAt.addingTimeInterval(4),
            fileSizeBytes: Int64(managedOriginalData.count)
        )
        first.managedRelativePath = legacyLibraryRoot == nil
            ? "Originals/\(first.id.uuidString)/primary.raf"
            : "Managed/Travel RAWs/DSCF0001.RAF"
        first.contentDigest = managedContentDigest
        first.captureDate = captureDate
        first.cameraMake = "Fujifilm"
        first.cameraModel = "X-T5"
        first.lensModel = "XF33mmF1.4 R LM WR"
        first.isoValue = 640
        first.focalLength = 33
        first.aperture = 1.4
        first.shutterSpeed = "1/250"
        first.pixelWidth = 7728
        first.pixelHeight = 5152
        first.exifOrientation = 6
        first.rating = 5
        first.flagRaw = PickFlag.picked.rawValue
        first.colorLabel = 3
        first.thumbnailFileName = "first.heic"

        var develop = ReleasedCatalogSchemaV4Fixture.DevelopSettings()
        develop.temperature = 0.21
        develop.tint = -0.12
        develop.exposure = 0.73
        develop.contrast = 0.19
        develop.highlights = -0.31
        develop.shadows = 0.27
        develop.whites = 0.08
        develop.blacks = -0.16
        develop.texture = 0.11
        develop.clarity = 0.22
        develop.dehaze = 0.09
        develop.vibrance = 0.33
        develop.saturation = -0.07
        develop.toneCurve = [
            .init(0, 0),
            .init(0.4, 0.57),
            .init(1, 1),
        ]
        develop.toneCurveRed = [.init(0, 0.03), .init(1, 0.96)]
        develop.colorMix.hue[2] = 0.18
        develop.colorMix.saturation[5] = -0.24
        develop.colorMix.luminance[7] = 0.29
        develop.grade.shadowHue = 0.61
        develop.grade.shadowSat = 0.17
        develop.grade.midHue = 0.13
        develop.grade.midSat = 0.42
        develop.grade.highHue = 0.83
        develop.grade.highSat = 0.26
        develop.blackWhite = true
        develop.bwRed = 0.15
        develop.bwGreen = -0.18
        develop.bwBlue = 0.09
        develop.sharpness = 0.64
        develop.sharpenRadius = 0.37
        develop.noiseReduction = 0.28
        develop.colorNoiseReduction = 0.36
        develop.grain = 0.14
        develop.vignette = -0.23
        develop.cropX = 0.07
        develop.cropY = 0.09
        develop.cropW = 0.81
        develop.cropH = 0.76
        develop.straighten = 1.75
        develop.flipH = true
        develop.rotationQuarterTurns = 3
        first.develop = develop

        let second = ReleasedCatalogSchemaV4Fixture.ImageAsset(
            originalFilename: "IMG_0002.CR3",
            storageMode: .referenced,
            fingerprintFilename: "IMG_0002.CR3",
            fingerprintSize: 51_000_002,
            fingerprintCaptureDate: captureDate.addingTimeInterval(60),
            fingerprintHeaderHash: "header-b",
            importedAt: createdAt.addingTimeInterval(5),
            fileSizeBytes: 51_000_002
        )
        second.bookmarkData = assetBookmark
        second.isMissing = true
        second.cameraMake = "Canon"
        second.cameraModel = "EOS R5"
        second.rating = 2
        second.flagRaw = PickFlag.rejected.rawValue
        var secondDevelop = ReleasedCatalogSchemaV4Fixture.DevelopSettings()
        secondDevelop.exposure = -0.2
        second.develop = secondDevelop

        first.folder = externalFolder
        first.collections = [picks, portfolio]
        second.collections = [picks]

        context.insert(externalFolder)
        context.insert(managedFolder)
        context.insert(picks)
        context.insert(portfolio)
        context.insert(first)
        context.insert(second)
        try context.save()

        var managedSidecarData: Data?
        if let legacyLibraryRoot, let managedRelativePath = first.managedRelativePath {
            let originalURL = legacyLibraryRoot.appendingPathComponent(managedRelativePath)
            try FileManager.default.createDirectory(
                at: originalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try managedOriginalData.write(to: originalURL)
            let sidecar = Sidecar(
                fingerprint: ImageFingerprint(
                    filename: first.fingerprintFilename,
                    fileSizeBytes: first.fingerprintSize,
                    captureDate: first.fingerprintCaptureDate,
                    headerHash: first.fingerprintHeaderHash
                ),
                sourceContentDigest: managedContentDigest,
                develop: DevelopSettings(),
                rating: first.rating,
                flag: first.flagRaw,
                colorLabel: first.colorLabel
            )
            try SidecarService.write(sidecar, for: originalURL)
            managedSidecarData = try Data(contentsOf: SidecarService.sidecarURL(for: originalURL))
        }

        return V4Fixture(
            firstAssetID: first.id,
            secondAssetID: second.id,
            externalFolderID: externalFolder.id,
            picksCollectionID: picks.id,
            portfolioCollectionID: portfolio.id,
            folderBookmark: folderBookmark,
            assetBookmark: assetBookmark,
            managedRelativePath: first.managedRelativePath ?? "",
            managedOriginalData: managedOriginalData,
            managedSidecarData: managedSidecarData,
            managedContentDigest: managedContentDigest
        )
    }

    private func appendV4Asset(to url: URL) throws {
        let configuration = ModelConfiguration(
            schema: ReleasedCatalogSchemaV4Fixture.schema,
            url: url,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: ReleasedCatalogSchemaV4Fixture.schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(ReleasedCatalogSchemaV4Fixture.ImageAsset(
            originalFilename: "NEW_0003.NEF",
            storageMode: .referenced,
            fingerprintFilename: "NEW_0003.NEF",
            fingerprintSize: 33_000_003,
            fileSizeBytes: 33_000_003
        ))
        try context.save()
    }

    private func modifySQLiteUserVersion(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 60)
        try handle.write(contentsOf: Data([0x52, 0x4C, 0x4D, 0x01]))
        try handle.synchronize()
    }

    private func detachCatalog(in generation: URL) throws {
        let catalog = generation.appendingPathComponent("Catalog", isDirectory: true)
        let detached = generation.appendingPathComponent(
            ".Catalog.test-detached-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: catalog, to: detached)
    }

    private func completedV4Migration(
        in roots: TestRoots
    ) throws -> (generation: URL, backup: URL) {
        let generationID = UUID()
        let generation = generationURL(generationID, in: roots.app)
        let catalog = catalogURL(in: generation)
        try FileManager.default.createDirectory(
            at: catalog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try writeV4Catalog(at: catalog)
        try Data("""
        { "schemaVersion": 1, "generationID": "\(generationID.uuidString)" }
        """.utf8).write(to: roots.app.appendingPathComponent("CurrentLibrary.json"))
        let publishedGeneration = try withConfiguredRoots(roots) {
            let result = CatalogStore.makeContainer()
            try #require(result.failure == nil)
            return LibraryLocations.currentGeneration
        }
        return (publishedGeneration, try migrationBackup(in: publishedGeneration))
    }

    private func migrationBackup(in generation: URL) throws -> URL {
        try #require(FileManager.default.contentsOfDirectory(
            at: generation,
            includingPropertiesForKeys: nil
        ).first {
            $0.lastPathComponent.hasPrefix(CatalogV4Migration.backupDirectoryPrefix)
        })
    }

    private func hasArtifactQuarantine(in generation: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: generation.appendingPathComponent("CatalogArtifactQuarantine.json").path
        )
    }

    private func byteManifest(of root: URL) throws -> [String: String] {
        let rootPath = root.standardizedFileURL.path
        var manifest: [String: String] = [:]

        func visit(_ directory: URL) throws {
            for entry in try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: []
            ) {
                let relativePath = String(entry.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                let values = try entry.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                if values.isSymbolicLink == true {
                    manifest[relativePath] = "symlink"
                } else if values.isDirectory == true {
                    manifest[relativePath] = "directory"
                    try visit(entry)
                } else if values.isRegularFile == true {
                    manifest[relativePath] = try ContentDigest.sha256(of: entry)
                } else {
                    manifest[relativePath] = "other"
                }
            }
        }

        try visit(root)
        return manifest
    }

    private func writeCurrentCatalog(at url: URL) throws {
        let configuration = ModelConfiguration(
            schema: CatalogStore.schema,
            url: url,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(
            for: CatalogStore.schema,
            configurations: [configuration]
        )
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try context.save()
    }

    private func writeSQLiteSnapshot(from sourceURL: URL, to destinationURL: URL) throws {
        var source: OpaquePointer?
        let sourceResult = sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceResult == SQLITE_OK, let source else {
            if let source { sqlite3_close(source) }
            throw NSError(domain: "CatalogGenerationSafetyTests", code: Int(sourceResult))
        }
        defer { sqlite3_close(source) }

        var destination: OpaquePointer?
        let destinationResult = sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationResult == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw NSError(domain: "CatalogGenerationSafetyTests", code: Int(destinationResult))
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw NSError(
                domain: "CatalogGenerationSafetyTests",
                code: Int(sqlite3_errcode(destination))
            )
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw NSError(
                domain: "CatalogGenerationSafetyTests",
                code: Int(stepResult == SQLITE_DONE ? finishResult : stepResult)
            )
        }
    }

    private func withConfiguredRoots<T>(
        _ roots: TestRoots,
        operation: () throws -> T
    ) rethrows -> T {
        LibraryLocations.configureRoots(appRoot: roots.app, cacheRoot: roots.cache)
        defer { LibraryLocations.resetConfiguredRoots() }
        return try operation()
    }

    private func makeRoots() -> TestRoots {
        let temporary = FileManager.default.temporaryDirectory
        return TestRoots(
            app: temporary.appendingPathComponent(
                "RawLight-CatalogSafety-\(UUID().uuidString)",
                isDirectory: true
            ),
            cache: temporary.appendingPathComponent(
                "RawLight-CatalogCache-\(UUID().uuidString)",
                isDirectory: true
            )
        )
    }

    private func generationURL(_ id: UUID, in root: URL) -> URL {
        root.appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func catalogURL(in generation: URL) -> URL {
        generation.appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.store")
    }

    private func completionMarkerURL(in generation: URL) -> URL {
        generation.appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("Catalog.complete.json")
    }

    private func remove(_ roots: TestRoots) {
        // SwiftData may retain SQLite descriptors after ModelContainer leaves
        // scope. UUID app roots remain in the system temp directory so teardown
        // never unlinks a store that Core Data still has open.
        try? FileManager.default.removeItem(at: roots.cache)
    }
}

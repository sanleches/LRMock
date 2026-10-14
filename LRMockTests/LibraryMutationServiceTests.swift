//
//  LibraryMutationServiceTests.swift
//  LRMockTests
//

import Foundation
import SwiftData
import Testing
@testable import LRMock

@Suite(.serialized)
@MainActor
struct LibraryMutationServiceTests {

    @Test func namesAndOrderingAreValidatedPerNamespace() throws {
        let container = CatalogStore.makeInMemoryContainer()
        let context = container.mainContext
        let existingFolder = LibraryFolder(name: "Existing", sortIndex: 9)
        let existingCollection = AssetCollection(name: "Portfolio", sortIndex: 4)
        context.insert(existingFolder)
        context.insert(existingCollection)
        try context.save()
        let service = LibraryMutationService(modelContext: context)

        let folder = try service.createFolder(name: "  Travel \n")
        let collection = try service.createCollection(name: "  Favorites  ")

        #expect(folder.name == "Travel")
        #expect(folder.kind == .managed)
        #expect(folder.sortIndex == 10)
        #expect(collection.name == "Favorites")
        #expect(collection.sortIndex == 5)
        #expect(throws: LibraryMutationService.MutationError.emptyName) {
            try service.createFolder(name: " \n\t ")
        }
        #expect(throws: LibraryMutationService.MutationError.duplicateFolderName("TRAVEL")) {
            try service.createFolder(name: "TRAVEL")
        }
        #expect(throws: LibraryMutationService.MutationError.duplicateCollectionName("favorites")) {
            try service.createCollection(name: "favorites")
        }

        try service.rename(folder: folder, to: "  Journeys ")
        try service.rename(collection: collection, to: " Picks ")
        #expect(folder.name == "Journeys")
        #expect(collection.name == "Picks")
        #expect(throws: LibraryMutationService.MutationError.duplicateFolderName("existing")) {
            try service.rename(folder: folder, to: "existing")
        }
        #expect(throws: LibraryMutationService.MutationError.duplicateCollectionName("PORTFOLIO")) {
            try service.rename(collection: collection, to: "PORTFOLIO")
        }
    }

    @Test func renameAndDeletePreservePhotosAndUnrelatedRelationships() throws {
        let container = CatalogStore.makeInMemoryContainer()
        let context = container.mainContext
        let folder = LibraryFolder(name: "Source")
        let removedCollection = AssetCollection(name: "Remove")
        let keptCollection = AssetCollection(name: "Keep")
        let first = makeAsset(filename: "first.raw")
        let second = makeAsset(filename: "second.raw")
        first.folder = folder
        second.folder = folder
        first.collections = [removedCollection, keptCollection]
        second.collections = [removedCollection]
        context.insert(folder)
        context.insert(removedCollection)
        context.insert(keptCollection)
        context.insert(first)
        context.insert(second)
        try context.save()
        let service = LibraryMutationService(modelContext: context)
        let keptCollectionID = keptCollection.id

        try service.rename(folder: folder, to: "Renamed Source")
        try service.rename(collection: removedCollection, to: "Renamed Collection")
        #expect(folder.name == "Renamed Source")
        #expect(removedCollection.name == "Renamed Collection")

        try service.delete(folder: folder)
        #expect(first.folder == nil)
        #expect(second.folder == nil)
        #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<LibraryFolder>()) == 0)

        try service.delete(collection: removedCollection)
        #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<AssetCollection>()) == 1)
        #expect(first.collections.map(\.id) == [keptCollectionID])
        #expect(second.collections.isEmpty)
        #expect(keptCollection.assets.map(\.id) == [first.id])
    }

    @Test func folderMoveOnlyChangesCatalogAssignment() throws {
        let container = CatalogStore.makeInMemoryContainer()
        let context = container.mainContext
        let source = LibraryFolder(name: "Source")
        let destination = LibraryFolder(name: "Destination")
        let managed = makeAsset(filename: "managed.raw", storageMode: .managed)
        let referenced = makeAsset(filename: "referenced.raw", storageMode: .referenced)
        let managedPath = "Originals/\(managed.id.uuidString)/primary.raw"
        let bookmark = Data([1, 2, 3, 4])
        managed.managedRelativePath = managedPath
        referenced.bookmarkData = bookmark
        managed.folder = source
        referenced.folder = source
        context.insert(source)
        context.insert(destination)
        context.insert(managed)
        context.insert(referenced)
        try context.save()
        let service = LibraryMutationService(modelContext: context)

        try service.move([managed, referenced, managed], to: destination)
        #expect(managed.folder?.id == destination.id)
        #expect(referenced.folder?.id == destination.id)
        #expect(managed.storageMode == .managed)
        #expect(managed.managedRelativePath == managedPath)
        #expect(referenced.storageMode == .referenced)
        #expect(referenced.bookmarkData == bookmark)

        try service.move([managed, referenced], to: nil)
        #expect(managed.folder == nil)
        #expect(referenced.folder == nil)
        #expect(managed.managedRelativePath == managedPath)
        #expect(referenced.bookmarkData == bookmark)
        try service.move([], to: destination)
    }

    @Test func collectionMembershipIsStableAndIdempotent() throws {
        let container = CatalogStore.makeInMemoryContainer()
        let context = container.mainContext
        let asset = makeAsset(filename: "member.raw")
        let target = AssetCollection(name: "Target")
        let other = AssetCollection(name: "Other")
        asset.collections = [other]
        context.insert(asset)
        context.insert(target)
        context.insert(other)
        try context.save()
        let service = LibraryMutationService(modelContext: context)

        try service.add([asset, asset], to: target)
        try service.add([asset], to: target)
        #expect(target.assets.filter { $0.id == asset.id }.count == 1)
        #expect(Set(asset.collections.map(\.id)) == Set([target.id, other.id]))

        try service.remove([asset, asset], from: target)
        try service.remove([asset], from: target)
        #expect(target.assets.isEmpty)
        #expect(asset.collections.map(\.id) == [other.id])
        try service.add([], to: target)
        try service.remove([], from: target)
    }

    @Test func ratingAndFlagsApplyToUniqueAssets() throws {
        let container = CatalogStore.makeInMemoryContainer()
        let context = container.mainContext
        let first = makeAsset(filename: "first.raw")
        let second = makeAsset(filename: "second.raw")
        context.insert(first)
        context.insert(second)
        try context.save()
        let service = LibraryMutationService(modelContext: context)

        try service.setRating(5, for: [first, first, second])
        try service.setFlag(.picked, for: [first, second, first])
        #expect(first.rating == 5)
        #expect(second.rating == 5)
        #expect(first.flag == .picked)
        #expect(second.flag == .picked)
        #expect(throws: LibraryMutationService.MutationError.invalidRating(6)) {
            try service.setRating(6, for: [first])
        }
        #expect(first.rating == 5)
        try service.setRating(99, for: [])
        try service.setFlag(.rejected, for: [])
    }

    @Test func mixedDeletionTrashesManagedFilesAndLeavesReferencedFilesAlone() throws {
        try withIsolatedLibrary {
            let container = CatalogStore.makeInMemoryContainer()
            let context = container.mainContext
            let managed = makeAsset(filename: "managed.raf", storageMode: .managed)
            let referenced = makeAsset(filename: "external.raf", storageMode: .referenced)
            let managedID = managed.id
            let referencedID = referenced.id

            let original = LibraryLocations.managedOriginalURL(
                assetID: managedID,
                fileExtension: "raf"
            )
            try FileManager.default.createDirectory(
                at: original.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("managed-original".utf8).write(to: original)
            let recipe = LibraryLocations.recipeURL(assetID: managedID)
            try Data("managed-recipe".utf8).write(to: recipe)
            managed.managedRelativePath = try LibraryLocations.relativePath(of: original)

            let external = FileManager.default.temporaryDirectory
                .appendingPathComponent("RawLight-Referenced-\(UUID().uuidString).raf")
            let sidecar = SidecarService.sidecarURL(for: external)
            defer {
                try? FileManager.default.removeItem(at: external)
                try? FileManager.default.removeItem(at: sidecar)
            }
            try Data("external-original".utf8).write(to: external)
            try Data("external-sidecar".utf8).write(to: sidecar)
            referenced.bookmarkData = Data([9, 8, 7])

            context.insert(managed)
            context.insert(referenced)
            try context.save()
            let service = LibraryMutationService(modelContext: context)

            let removed = try service.removeFromLibrary([managed, referenced, managed])

            #expect(removed == [managedID, referencedID])
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 0)
            #expect(!FileManager.default.fileExists(atPath: original.path))
            #expect(!FileManager.default.fileExists(atPath: recipe.path))
            #expect(FileManager.default.fileExists(atPath: external.path))
            #expect(FileManager.default.fileExists(atPath: sidecar.path))

            let packages = try FileManager.default.contentsOfDirectory(
                at: LibraryLocations.trash,
                includingPropertiesForKeys: nil
            )
            let package = try #require(packages.count == 1 ? packages.first : nil)
            #expect(FileManager.default.fileExists(
                atPath: package.appendingPathComponent("Original/primary.raf").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: package.appendingPathComponent("Recipe.rawlight.json").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: package.appendingPathComponent("Manifest.json").path
            ))
        }
    }

    @Test func managedDeletionWithoutAPathFailsClosed() throws {
        try withIsolatedLibrary {
            let container = CatalogStore.makeInMemoryContainer()
            let context = container.mainContext
            let managed = makeAsset(filename: "missing.raw", storageMode: .managed)
            let managedID = managed.id
            context.insert(managed)
            try context.save()
            let service = LibraryMutationService(modelContext: context)

            #expect(throws: LibraryMutationService.MutationError.missingManagedRelativePath(managedID)) {
                try service.removeFromLibrary([managed])
            }
            #expect(try context.fetchCount(FetchDescriptor<ImageAsset>()) == 1)
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: LibraryLocations.trash.path
            ).isEmpty)
        }
    }

    private func makeAsset(
        filename: String,
        storageMode: StorageMode = .referenced
    ) -> ImageAsset {
        ImageAsset(
            originalFilename: filename,
            storageMode: storageMode,
            fingerprint: ImageFingerprint(filename: filename, fileSizeBytes: 10),
            fileSizeBytes: 10
        )
    }

    private func withIsolatedLibrary<T>(_ operation: () throws -> T) throws -> T {
        let temporary = FileManager.default.temporaryDirectory
        let appRoot = temporary.appendingPathComponent(
            "RawLight-MutationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let cacheRoot = temporary.appendingPathComponent(
            "RawLight-MutationCache-\(UUID().uuidString)",
            isDirectory: true
        )
        LibraryLocations.configureRoots(appRoot: appRoot, cacheRoot: cacheRoot)
        defer {
            LibraryLocations.resetConfiguredRoots()
            try? FileManager.default.removeItem(at: appRoot)
            try? FileManager.default.removeItem(at: cacheRoot)
        }
        _ = try LibraryLocations.bootstrap()
        return try operation()
    }
}

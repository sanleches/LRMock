//
//  LibraryMutationService.swift
//  RawLight
//
//  Centralized, synchronous catalog mutations. Portable recipe and sidecar
//  persistence remains the responsibility of the UI autosaver.
//

import Foundation
import SwiftData

@MainActor
final class LibraryMutationService {

    enum MutationError: Error, Equatable, LocalizedError {
        case emptyName
        case duplicateFolderName(String)
        case duplicateCollectionName(String)
        case invalidRating(Int)
        case sortIndexOverflow
        case missingManagedRelativePath(UUID)

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Names must contain at least one non-whitespace character."
            case .duplicateFolderName(let name):
                return "A folder named \"\(name)\" already exists."
            case .duplicateCollectionName(let name):
                return "A collection named \"\(name)\" already exists."
            case .invalidRating(let rating):
                return "The rating \(rating) is outside the supported range of 0 through 5."
            case .sortIndexOverflow:
                return "The library ordering has reached its supported limit."
            case .missingManagedRelativePath(let id):
                return "Managed photo \(id.uuidString) has no library path and was not removed."
            }
        }
    }

    struct RestorationFailure: LocalizedError {
        let operationError: Error
        let restorationErrors: [Error]

        var errorDescription: String? {
            let details = restorationErrors
                .map(\.localizedDescription)
                .joined(separator: "; ")
            return "\(operationError.localizedDescription) Restoring managed files also failed: \(details)"
        }
    }

    private struct ManagedAsset {
        let id: UUID
        let originalFilename: String
        let relativePath: String
    }

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    @discardableResult
    func createFolder(name: String) throws -> LibraryFolder {
        let name = try validatedName(name)
        let folders = try modelContext.fetch(FetchDescriptor<LibraryFolder>())
        guard !folders.contains(where: { namesMatch($0.name, name) }) else {
            throw MutationError.duplicateFolderName(name)
        }

        let folder = LibraryFolder(
            name: name,
            kind: .managed,
            sortIndex: try nextSortIndex(folders.map(\.sortIndex))
        )
        modelContext.insert(folder)
        try saveChanges()
        return folder
    }

    @discardableResult
    func createCollection(name: String) throws -> AssetCollection {
        let name = try validatedName(name)
        let collections = try modelContext.fetch(FetchDescriptor<AssetCollection>())
        guard !collections.contains(where: { namesMatch($0.name, name) }) else {
            throw MutationError.duplicateCollectionName(name)
        }

        let collection = AssetCollection(
            name: name,
            sortIndex: try nextSortIndex(collections.map(\.sortIndex))
        )
        modelContext.insert(collection)
        try saveChanges()
        return collection
    }

    func rename(folder: LibraryFolder, to proposedName: String) throws {
        let name = try validatedName(proposedName)
        let folders = try modelContext.fetch(FetchDescriptor<LibraryFolder>())
        guard !folders.contains(where: {
            $0.id != folder.id && namesMatch($0.name, name)
        }) else {
            throw MutationError.duplicateFolderName(name)
        }
        guard folder.name != name else { return }

        folder.name = name
        try saveChanges()
    }

    func rename(collection: AssetCollection, to proposedName: String) throws {
        let name = try validatedName(proposedName)
        let collections = try modelContext.fetch(FetchDescriptor<AssetCollection>())
        guard !collections.contains(where: {
            $0.id != collection.id && namesMatch($0.name, name)
        }) else {
            throw MutationError.duplicateCollectionName(name)
        }
        guard collection.name != name else { return }

        collection.name = name
        try saveChanges()
    }

    func delete(folder: LibraryFolder) throws {
        for asset in uniqueAssets(folder.assets) {
            asset.folder = nil
        }
        modelContext.delete(folder)
        try saveChanges()
    }

    func delete(collection: AssetCollection) throws {
        let collectionID = collection.id
        for asset in uniqueAssets(collection.assets) {
            asset.collections.removeAll { $0.id == collectionID }
        }
        modelContext.delete(collection)
        try saveChanges()
    }

    func move(_ assets: [ImageAsset], to folder: LibraryFolder?) throws {
        let assets = uniqueAssets(assets)
        guard !assets.isEmpty else { return }

        let destinationID = folder?.id
        let changed = assets.filter { $0.folder?.id != destinationID }
        guard !changed.isEmpty else { return }
        for asset in changed {
            asset.folder = folder
        }
        try saveChanges()
    }

    func add(_ assets: [ImageAsset], to collection: AssetCollection) throws {
        let assets = uniqueAssets(assets)
        guard !assets.isEmpty else { return }

        var memberIDs = Set(collection.assets.map(\.id))
        let additions = assets.filter { memberIDs.insert($0.id).inserted }
        guard !additions.isEmpty else { return }
        collection.assets.append(contentsOf: additions)
        try saveChanges()
    }

    func remove(_ assets: [ImageAsset], from collection: AssetCollection) throws {
        let assetIDs = Set(uniqueAssets(assets).map(\.id))
        guard !assetIDs.isEmpty else { return }

        let previousCount = collection.assets.count
        collection.assets.removeAll { assetIDs.contains($0.id) }
        guard collection.assets.count != previousCount else { return }
        try saveChanges()
    }

    func setRating(_ rating: Int, for assets: [ImageAsset]) throws {
        let assets = uniqueAssets(assets)
        guard !assets.isEmpty else { return }
        guard (0...5).contains(rating) else {
            throw MutationError.invalidRating(rating)
        }

        let changed = assets.filter { $0.rating != rating }
        guard !changed.isEmpty else { return }
        for asset in changed {
            asset.rating = rating
        }
        try saveChanges()
    }

    func setFlag(_ flag: PickFlag, for assets: [ImageAsset]) throws {
        let assets = uniqueAssets(assets)
        guard !assets.isEmpty else { return }

        let changed = assets.filter { $0.flag != flag }
        guard !changed.isEmpty else { return }
        for asset in changed {
            asset.flag = flag
        }
        try saveChanges()
    }

    @discardableResult
    func removeFromLibrary(_ assets: [ImageAsset]) throws -> [UUID] {
        let assets = uniqueAssets(assets)
        guard !assets.isEmpty else { return [] }

        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        let managedAssets: [ManagedAsset]
        do {
            managedAssets = try assets.compactMap { asset in
                guard asset.storageMode == .managed else { return nil }
                guard let relativePath = asset.managedRelativePath,
                      !relativePath.isEmpty
                else {
                    throw MutationError.missingManagedRelativePath(asset.id)
                }
                _ = try LibraryLocations.url(
                    forManagedRelativePath: relativePath,
                    expectedAssetID: asset.id
                )
                return ManagedAsset(
                    id: asset.id,
                    originalFilename: asset.originalFilename,
                    relativePath: relativePath
                )
            }
        } catch {
            modelContext.rollback()
            throw error
        }

        var receipts: [LibraryTrash.Receipt] = []
        do {
            for asset in managedAssets {
                receipts.append(try LibraryTrash.moveManagedAsset(
                    id: asset.id,
                    originalFilename: asset.originalFilename,
                    managedRelativePath: asset.relativePath
                ))
            }
        } catch {
            modelContext.rollback()
            throw errorRestoring(receipts, after: error)
        }

        let removedIDs = assets.map(\.id)
        for asset in assets {
            modelContext.delete(asset)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw errorRestoring(receipts, after: error)
        }
        return removedIDs
    }

    private func saveChanges() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    private func validatedName(_ proposedName: String) throws -> String {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MutationError.emptyName }
        return name
    }

    private func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        canonicalName(lhs) == canonicalName(rhs)
    }

    private func canonicalName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private func nextSortIndex(_ indices: [Int]) throws -> Int {
        guard let maximum = indices.max() else { return 0 }
        let result = maximum.addingReportingOverflow(1)
        guard !result.overflow else { throw MutationError.sortIndexOverflow }
        return result.partialValue
    }

    private func uniqueAssets(_ assets: [ImageAsset]) -> [ImageAsset] {
        var seen = Set<UUID>()
        return assets.filter { seen.insert($0.id).inserted }
    }

    private func errorRestoring(
        _ receipts: [LibraryTrash.Receipt],
        after operationError: Error
    ) -> Error {
        var restorationErrors: [Error] = []
        for receipt in receipts.reversed() {
            do {
                try receipt.restore()
            } catch {
                restorationErrors.append(error)
            }
        }
        guard !restorationErrors.isEmpty else { return operationError }
        return RestorationFailure(
            operationError: operationError,
            restorationErrors: restorationErrors
        )
    }
}
